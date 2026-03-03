"""Agent CLI config resolver for yamibaito scripts.

This module intentionally avoids external YAML dependencies.
"""

from __future__ import annotations

import os
import shlex
import sys
from typing import Any, Dict

CLI_PRESETS = {
    "claude": {
        "interactive_command": "claude --dangerously-skip-permissions",
        "batch_command": "claude --dangerously-skip-permissions",
        "mode": "interactive",
        "model_flag": "--model",
    },
    "gemini": {
        "interactive_command": "gemini --yolo",
        "batch_command": "gemini",
        "mode": "interactive",
        "model_flag": "--model",
    },
    "codex": {
        "interactive_command": "codex --dangerously-bypass-approvals-and-sandbox",
        "batch_command": "codex exec --sandbox {sandbox} -",
        "mode": "batch_stdin",
        "model_flag": "--model",
    },
    "copilot": {
        "interactive_command": "copilot --autopilot",
        "batch_command": "copilot",
        "mode": "interactive",
        "model_flag": "--model",
    },
}

LEGACY_DEFAULTS = {
    "oyabun": "claude",
    "waka": "claude",
    "plan": "claude",
    "worker": "codex",
    "plan_review": "codex",
    "review": "codex",
}

DEFAULT_INITIAL_MESSAGE = 'Please read file: "{prompt_path}" and follow it. You are the {role}.'

_INTERACTIVE_ROLES = {"oyabun", "waka", "plan"}
_BATCH_STDIN_ROLES = {"worker", "plan_review", "review"}
_WORKER_DEFAULTS = {
    "sandbox": "workspace-write",
    "approval": "on-request",
    "model": "default",
    "web_search": False,
}


def _should_inject_model(model: Any) -> bool:
    if _is_missing(model):
        return False
    model_str = str(model).strip().lower()
    return model_str not in ("", "default")


def _warn(message: str) -> None:
    print(f"warning: agent_config: {message}", file=sys.stderr)


def _strip_inline_comment(value: str) -> str:
    in_single = False
    in_double = False
    escaped = False
    for idx, ch in enumerate(value):
        if ch == "\\" and in_double and not escaped:
            escaped = True
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single and not escaped:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            return value[:idx].rstrip()
        escaped = False
    return value.strip()


def _coerce_scalar(value: str) -> Any:
    stripped = _strip_inline_comment(value).strip()
    if not stripped:
        return ""

    if len(stripped) >= 2 and stripped[0] == stripped[-1] and stripped[0] in {'"', "'"}:
        stripped = stripped[1:-1]

    lowered = stripped.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    return stripped


def _detect_unsupported_yaml(key: str, raw_value: str) -> str | None:
    stripped_key = key.strip()
    stripped_value = _strip_inline_comment(raw_value).strip()

    if stripped_key == "<<":
        return "merge key (<<)"
    if stripped_value.startswith("|") or stripped_value.startswith(">"):
        return "multiline scalar (| or >)"
    if stripped_value.startswith("{") or stripped_value.startswith("["):
        return "flow style ({}, [])"

    for token in stripped_value.split():
        if token.startswith("&"):
            return "anchor (&)"
        if token.startswith("*"):
            return "alias (*)"

    return None


def _parse_lightweight_yaml(config_path: str) -> Dict[str, Any]:
    data: Dict[str, Any] = {}
    if not os.path.exists(config_path):
        return data

    stack: list[tuple[int, Dict[str, Any]]] = [(0, data)]
    try:
        with open(config_path, "r", encoding="utf-8") as f:
            for line_no, raw_line in enumerate(f, start=1):
                line = raw_line.rstrip("\n")
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue

                leading = line[: len(line) - len(line.lstrip(" \t"))]
                if "\t" in leading:
                    _warn(f"{config_path}:{line_no}: tab indentation is unsupported; skipped")
                    continue
                indent = len(line) - len(line.lstrip(" "))

                while len(stack) > 1 and indent < stack[-1][0]:
                    stack.pop()

                if indent != stack[-1][0]:
                    _warn(f"{config_path}:{line_no}: invalid indentation; skipped")
                    continue

                content = line[indent:]
                if ":" not in content:
                    _warn(f"{config_path}:{line_no}: missing ':'; skipped")
                    continue

                raw_key, raw_value = content.split(":", 1)
                key = raw_key.strip()
                if not key:
                    _warn(f"{config_path}:{line_no}: empty key; skipped")
                    continue

                unsupported = _detect_unsupported_yaml(key, raw_value)
                if unsupported:
                    _warn(f"{config_path}:{line_no}: unsupported YAML syntax ({unsupported}); skipped")
                    continue

                parent = stack[-1][1]
                value = _strip_inline_comment(raw_value).strip()
                if value == "":
                    child: Dict[str, Any] = {}
                    parent[key] = child
                    stack.append((indent + 2, child))
                    continue

                parent[key] = _coerce_scalar(raw_value)
    except OSError as exc:
        _warn(f"failed to read config '{config_path}': {exc}")
        return {}

    return data


def _default_mode_for_role(role: str) -> str:
    if role in _BATCH_STDIN_ROLES:
        return "batch_stdin"
    return "interactive"


def _default_cli_for_role(role: str) -> str:
    if role in LEGACY_DEFAULTS:
        return LEGACY_DEFAULTS[role]
    if role in _BATCH_STDIN_ROLES:
        return "codex"
    return "claude"


def _clean_text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _is_missing(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, str):
        return not value.strip()
    if isinstance(value, (dict, list, tuple, set)):
        return len(value) == 0
    return False


def _coerce_bool(value: Any) -> Any:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered == "true":
            return True
        if lowered == "false":
            return False
    return value


def _resolve_command_from_preset(cli: str, mode: str) -> str:
    preset = CLI_PRESETS.get(cli, {})
    if mode == "interactive":
        return _clean_text(preset.get("interactive_command")) or _clean_text(preset.get("batch_command"))
    return _clean_text(preset.get("batch_command")) or _clean_text(preset.get("interactive_command"))


def _parse_non_negative_int(value: Any, default: int) -> int:
    if isinstance(value, bool):
        return default
    try:
        parsed = int(str(value).strip())
    except (TypeError, ValueError):
        return default
    if parsed < 0:
        return default
    return parsed


def load_agent_config(config_path: str, role: str) -> dict:
    """Resolve agent settings with presets and legacy-compatible fallbacks."""
    config = _parse_lightweight_yaml(config_path)
    agents = config.get("agents")
    if not isinstance(agents, dict):
        agents = {}

    role_cfg = agents.get(role)
    if not isinstance(role_cfg, dict):
        role_cfg = {}

    # review 未設定時は worker にフォールバック（後方互換）
    if role == "review" and not role_cfg:
        return load_agent_config(config_path, "worker")

    default_cli = _default_cli_for_role(role)
    cli = _clean_text(role_cfg.get("cli")).lower() or default_cli

    mode = _default_mode_for_role(role)
    initial_message = _clean_text(role_cfg.get("initial_message")) or DEFAULT_INITIAL_MESSAGE

    if cli == "custom":
        command = _clean_text(role_cfg.get("command"))
        custom_mode = _clean_text(role_cfg.get("mode"))
        if custom_mode:
            mode = custom_mode
        if not command:
            _warn(f"{config_path}: agents.{role}.cli=custom requires command; falling back to {default_cli}")
            cli = default_cli
            mode = _default_mode_for_role(role)
            command = _resolve_command_from_preset(cli, mode)
    else:
        if cli not in CLI_PRESETS:
            _warn(f"{config_path}: agents.{role}.cli='{cli}' is unknown; falling back to {default_cli}")
            cli = default_cli
        command = _resolve_command_from_preset(cli, mode)

    top_level_codex = config.get("codex")
    if not isinstance(top_level_codex, dict):
        top_level_codex = {}

    sandbox = role_cfg.get("sandbox")
    approval = role_cfg.get("approval")
    model = role_cfg.get("model")
    web_search = role_cfg.get("web_search")

    if role in {"worker", "plan_review", "review"}:
        if _is_missing(sandbox):
            sandbox = top_level_codex.get("sandbox")
        if _is_missing(approval):
            approval = top_level_codex.get("approval")
        if _is_missing(model):
            model = top_level_codex.get("model")
        if _is_missing(web_search):
            web_search = top_level_codex.get("web_search")

        if _is_missing(sandbox):
            sandbox = _WORKER_DEFAULTS["sandbox"]
        if _is_missing(approval):
            approval = _WORKER_DEFAULTS["approval"]
        if _is_missing(model):
            model = _WORKER_DEFAULTS["model"]
        if _is_missing(web_search):
            web_search = _WORKER_DEFAULTS["web_search"]

    # 全ロール共通の sandbox フォールバック
    # コマンドテンプレートに {sandbox} が含まれるケースに対応
    if _is_missing(sandbox):
        sandbox = top_level_codex.get("sandbox") or _WORKER_DEFAULTS["sandbox"]

    web_search = _coerce_bool(web_search)

    if cli == "custom":
        model_flag = _clean_text(role_cfg.get("model_flag")) or "--model"
    else:
        preset = CLI_PRESETS.get(cli, {})
        model_flag = preset.get("model_flag", "--model")

    return {
        "cli": cli,
        "command": command,
        "mode": mode,
        "initial_message": initial_message,
        "sandbox": sandbox,
        "approval": approval,
        "model": model,
        "model_flag": model_flag,
        "web_search": web_search,
    }


def get_worker_count(config_path: str) -> int:
    """Return worker count using workers.count -> workers.codex_count -> 3."""
    config = _parse_lightweight_yaml(config_path)
    workers = config.get("workers")
    if not isinstance(workers, dict):
        return 3
    if "count" in workers:
        return _parse_non_negative_int(workers.get("count"), 3)
    if "codex_count" in workers:
        return _parse_non_negative_int(workers.get("codex_count"), 3)
    return 3


def build_launch_command(agent_cfg: dict, **kwargs: Any) -> list[str]:
    """Build command list for subprocess.Popen(..., shell=False)."""
    command_template = _clean_text(agent_cfg.get("command"))
    if not command_template:
        return []

    template_values = {key: value for key, value in kwargs.items() if value is not None}
    if "sandbox" not in template_values and not _is_missing(agent_cfg.get("sandbox")):
        template_values["sandbox"] = agent_cfg.get("sandbox")
    if "role" not in template_values and not _is_missing(agent_cfg.get("role")):
        template_values["role"] = agent_cfg.get("role")
    if "prompt_path" not in template_values and not _is_missing(agent_cfg.get("prompt_path")):
        template_values["prompt_path"] = agent_cfg.get("prompt_path")
    if "output_path" not in template_values and not _is_missing(agent_cfg.get("output_path")):
        template_values["output_path"] = agent_cfg.get("output_path")

    try:
        command_text = command_template.format(**template_values)
    except KeyError as exc:
        missing_key = exc.args[0]
        raise ValueError(f"missing template variable for command: {missing_key}") from exc

    cmd = shlex.split(command_text)

    # Post-injection: --model <value>
    model = kwargs.get("model") if "model" in kwargs else agent_cfg.get("model")
    if _should_inject_model(model):
        model_flag = agent_cfg.get("model_flag", "--model")
        model_value = str(model).strip()
        # codex batch: stdin marker (-) の前に挿入
        if cmd and cmd[-1] == "-":
            cmd.insert(-1, model_flag)
            cmd.insert(-1, model_value)
        else:
            cmd.append(model_flag)
            cmd.append(model_value)

    return cmd


def build_initial_message(agent_cfg: dict, **kwargs: Any) -> str:
    """Build initial interactive message from template."""
    message_template = _clean_text(agent_cfg.get("initial_message")) or DEFAULT_INITIAL_MESSAGE
    try:
        return message_template.format(**kwargs)
    except KeyError as exc:
        missing_key = exc.args[0]
        raise ValueError(f"missing template variable for initial_message: {missing_key}") from exc


def get_cli_binary(agent_cfg: dict) -> str:
    """Return binary token from command for command -v preflight checks."""
    command_text = _clean_text(agent_cfg.get("command"))
    if not command_text:
        return ""
    try:
        tokens = shlex.split(command_text)
    except ValueError:
        tokens = command_text.split()
    if not tokens:
        return ""
    return tokens[0]


__all__ = [
    "CLI_PRESETS",
    "LEGACY_DEFAULTS",
    "DEFAULT_INITIAL_MESSAGE",
    "_should_inject_model",
    "load_agent_config",
    "get_worker_count",
    "build_launch_command",
    "build_initial_message",
    "get_cli_binary",
]
