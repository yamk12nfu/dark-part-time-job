#!/usr/bin/env python3
"""Yamibaito v2 orchestrator control plane."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import glob
import os
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
from typing import Any, Dict, List, Optional, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

from lib.event_logger import EventLogger
from lib.panes import load_panes
from lib.signal_parser import (
    compute_sig_hash,
    extract_last_json_object,
    normalize_timestamp,
    validate_signal,
)
from lib.state_manager import StateManager

MODE_LEGACY = "legacy"
MODE_HYBRID = "hybrid"
MODE_V2 = "v2"
VALID_MODES = (MODE_LEGACY, MODE_HYBRID, MODE_V2)

ROLE_PLANNER = "planner"
ROLE_ARCHITECT = "architect"
ROLE_IMPLEMENTER = "implementer"
ROLE_REVIEWER = "reviewer"
ROLE_QUALITY_GATE = "quality-gate"

STATUS_TASKS_READY = "tasks_ready"
STATUS_DESIGN_READY = "design_ready"
STATUS_DONE = "done"
STATUS_PLANNING_BLOCKER = "planning_blocker"
STATUS_DESIGN_QUESTIONS = "design_questions"
STATUS_NEEDS_ARCHITECT = "needs_architect"
STATUS_REVIEW_INPUT_ERROR = "review_input_error"
STATUS_GATE_BLOCKED = "gate_blocked"

RESULT_APPROVE = "approve"
RESULT_REWORK = "rework"

DISPATCH_CALL_DEFAULT = "default"
DISPATCH_CALL_PLANNER = "planner"
DISPATCH_CALL_ARCHITECT_DONE = "architect_done"
DISPATCH_CALL_ROLE = "role"

BLOCKED_PHASE_DISPATCH = "blocked_dispatch"
BLOCKED_PHASE_COLLECT = "blocked_collect"

PROCESS_LOCK_DISPATCH_COLLECT = "dispatch_collect"
PROCESS_LOCK_STATE_SAVE = "state_save"

CAPTURE_PANE_RETRY_MAX = 2
COMMAND_RETRY_MAX = 2
COMMAND_RETRY_SLEEP_SEC = 1.0
PROCESS_LOCK_TIMEOUT_SEC = 10.0

_SESSION_SANITIZER = re.compile(r"[^A-Za-z0-9_-]")
_STOP_REQUESTED = False


def _log(level: str, message: str) -> None:
    stamp = dt.datetime.now().isoformat(timespec="seconds")
    print(f"[yb_orchestrator][{level}][{stamp}] {message}", file=sys.stderr, flush=True)


def _to_text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _to_int(value: Any, default: int) -> int:
    if isinstance(value, bool):
        return default
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def _to_bool(value: Any, default: bool) -> bool:
    if isinstance(value, bool):
        return value
    text = _to_text(value).lower()
    if text in {"true", "yes", "1", "on"}:
        return True
    if text in {"false", "no", "0", "off"}:
        return False
    return default


def _strip_inline_comment(value: str) -> str:
    in_single = False
    in_double = False
    escaped = False
    out: List[str] = []
    for ch in value:
        if ch == "\\" and in_double and not escaped:
            escaped = True
            out.append(ch)
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single and not escaped:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            break
        escaped = False
        out.append(ch)
    return "".join(out).rstrip()


def _parse_yaml_scalar(raw_value: str) -> Any:
    stripped = _strip_inline_comment(raw_value).strip()
    if stripped == "":
        return ""
    if len(stripped) >= 2 and stripped[0] == stripped[-1] and stripped[0] in {"'", '"'}:
        stripped = stripped[1:-1]

    lowered = stripped.lower()
    if lowered in {"null", "~"}:
        return None
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if re.fullmatch(r"-?\d+", stripped):
        return int(stripped)
    return stripped


def _parse_yaml_mapping(path: str) -> Dict[str, Any]:
    data: Dict[str, Any] = {}
    if not os.path.isfile(path):
        return data

    stack: List[Tuple[int, Dict[str, Any]]] = [(0, data)]
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line_no, raw_line in enumerate(fh, start=1):
                line = raw_line.rstrip("\n")
                stripped = line.strip()
                if not stripped or stripped.startswith("#"):
                    continue

                leading = line[: len(line) - len(line.lstrip(" \t"))]
                if "\t" in leading:
                    _log("warn", f"{path}:{line_no}: tab indentation is not supported; skipped")
                    continue

                indent = len(line) - len(line.lstrip(" "))
                while len(stack) > 1 and indent < stack[-1][0]:
                    stack.pop()
                if indent != stack[-1][0]:
                    _log("warn", f"{path}:{line_no}: invalid indentation; skipped")
                    continue

                content = line[indent:]
                if ":" not in content:
                    _log("warn", f"{path}:{line_no}: missing ':'; skipped")
                    continue
                raw_key, raw_value = content.split(":", 1)
                key = raw_key.strip()
                if not key:
                    _log("warn", f"{path}:{line_no}: empty key; skipped")
                    continue

                parent = stack[-1][1]
                value = _strip_inline_comment(raw_value).strip()
                if value == "":
                    child: Dict[str, Any] = {}
                    parent[key] = child
                    stack.append((indent + 2, child))
                    continue
                if value.startswith("|") or value.startswith(">"):
                    parent[key] = ""
                    continue
                parent[key] = _parse_yaml_scalar(raw_value)
    except OSError as exc:
        _log("warn", f"failed to read config file '{path}': {exc}")
        return {}

    return data


def _load_runtime_config(repo_root: str) -> Dict[str, Any]:
    config_path = os.path.join(repo_root, ".yamibaito", "config.yaml")
    config = _parse_yaml_mapping(config_path)
    orchestrator = config.get("orchestrator")
    quality_gate = config.get("quality_gate")
    if not isinstance(orchestrator, dict):
        orchestrator = {}
    if not isinstance(quality_gate, dict):
        quality_gate = {}

    poll_interval_sec = _to_int(orchestrator.get("poll_interval_sec"), 5)
    if poll_interval_sec <= 0:
        poll_interval_sec = 5

    max_signal_history = _to_int(orchestrator.get("max_signal_history"), 2000)
    if max_signal_history <= 0:
        max_signal_history = 2000

    max_rework_loops = _to_int(quality_gate.get("max_rework_loops"), 3)
    if max_rework_loops < 0:
        max_rework_loops = 3

    return {
        "mode": _to_text(orchestrator.get("mode")),
        "poll_interval_sec": poll_interval_sec,
        "max_signal_history": max_signal_history,
        "quality_gate_enabled": _to_bool(quality_gate.get("enabled"), True),
        "max_rework_loops": max_rework_loops,
    }


def _sanitize_session_id(session_id: str) -> str:
    if not session_id:
        return ""
    return _SESSION_SANITIZER.sub("_", session_id)


def _resolve_panes_path(repo_root: str, session_id: str) -> str:
    session_clean = _sanitize_session_id(session_id)
    suffix = f"_{session_clean}" if session_clean else ""
    return os.path.join(repo_root, ".yamibaito", f"panes{suffix}.json")


def _resolve_queue_dir(repo_root: str, work_dir: str, session_id: str, panes: Dict[str, Any]) -> str:
    queue_dir = _to_text(panes.get("queue_dir"))
    if queue_dir:
        return queue_dir

    session_clean = _sanitize_session_id(session_id)
    suffix = f"_{session_clean}" if session_clean else ""
    candidates = [
        os.path.join(work_dir, ".yamibaito", f"queue{suffix}"),
        os.path.join(repo_root, ".yamibaito", f"queue{suffix}"),
    ]
    for candidate in candidates:
        if os.path.isdir(candidate):
            return candidate
    return candidates[0]


def _acquire_process_lock(
    lock_dir: str,
    lock_name: str,
    *,
    timeout_sec: float = PROCESS_LOCK_TIMEOUT_SEC,
) -> Tuple[Optional[int], str]:
    os.makedirs(lock_dir, exist_ok=True)
    lock_path = os.path.join(lock_dir, f"{lock_name}.lock")
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    deadline = time.monotonic() + max(timeout_sec, 0.0)

    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            payload = f"pid={os.getpid()} acquired_at={dt.datetime.now().isoformat()}\n"
            os.ftruncate(fd, 0)
            os.write(fd, payload.encode("utf-8"))
            os.fsync(fd)
            return fd, lock_path
        except BlockingIOError:
            if timeout_sec <= 0 or time.monotonic() >= deadline:
                os.close(fd)
                return None, lock_path
            time.sleep(0.1)
        except OSError:
            os.close(fd)
            raise


def _release_process_lock(fd: Optional[int]) -> None:
    if fd is None:
        return
    try:
        fcntl.flock(fd, fcntl.LOCK_UN)
    except OSError:
        pass
    try:
        os.close(fd)
    except OSError:
        pass


def _save_state_with_lock(sm: StateManager, lock_dir: str) -> None:
    lock_fd: Optional[int] = None
    try:
        lock_fd, lock_path = _acquire_process_lock(lock_dir, PROCESS_LOCK_STATE_SAVE)
        if lock_fd is None:
            raise RuntimeError(f"state save lock timeout: {lock_path}")
        sm.save()
    finally:
        _release_process_lock(lock_fd)


def _atomic_write_text(path: str, content: str) -> bool:
    tmp_path = ""
    target_dir = os.path.dirname(path) or "."
    try:
        os.makedirs(target_dir, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            "w",
            encoding="utf-8",
            dir=target_dir,
            prefix=".tmp-",
            suffix=".yaml",
            delete=False,
        ) as fh:
            tmp_path = fh.name
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_path, path)
        return True
    except OSError as exc:
        _log("warn", f"failed to atomically write '{path}': {exc}")
        if tmp_path:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        return False


def _set_worker_task_needs_architect_true(task_path: str) -> bool:
    try:
        with open(task_path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError as exc:
        _log("warn", f"failed to read worker task YAML '{task_path}': {exc}")
        return False

    if not lines:
        return False

    newline = "\n"
    for line in lines:
        if line.endswith("\r\n"):
            newline = "\r\n"
            break

    task_start = -1
    task_end = len(lines)
    for idx, line in enumerate(lines):
        stripped = line.strip()
        indent = len(line) - len(line.lstrip(" "))
        if task_start < 0:
            if indent == 0 and stripped == "task:":
                task_start = idx
            continue
        if indent == 0 and stripped.endswith(":"):
            task_end = idx
            break

    if task_start < 0:
        _log("warn", f"worker task YAML has no 'task:' section: {task_path}")
        return False

    for idx in range(task_start + 1, task_end):
        line = lines[idx]
        stripped = line.strip()
        indent = len(line) - len(line.lstrip(" "))
        if indent == 2 and stripped.startswith("needs_architect:"):
            lines[idx] = f"  needs_architect: true{newline}"
            return _atomic_write_text(task_path, "".join(lines))

    insert_idx = task_end
    for idx in range(task_start + 1, task_end):
        line = lines[idx]
        stripped = line.strip()
        indent = len(line) - len(line.lstrip(" "))
        if indent == 2 and stripped.startswith("description:"):
            insert_idx = idx
            break
    lines.insert(insert_idx, f"  needs_architect: true{newline}")
    return _atomic_write_text(task_path, "".join(lines))


def _set_plan_task_needs_architect_true(plan_tasks_path: str, task_id: str, cmd_id: str) -> bool:
    try:
        with open(plan_tasks_path, "r", encoding="utf-8") as fh:
            lines = fh.readlines()
    except OSError as exc:
        _log("warn", f"failed to read planner tasks YAML '{plan_tasks_path}': {exc}")
        return False

    if not lines:
        return False

    newline = "\n"
    for line in lines:
        if line.endswith("\r\n"):
            newline = "\r\n"
            break

    local_task_id = task_id
    prefix = f"{cmd_id}_"
    if cmd_id and task_id.startswith(prefix):
        local_task_id = task_id[len(prefix) :]

    in_tasks = False
    entry_start = -1
    entries: List[Tuple[int, int]] = []
    for idx, line in enumerate(lines):
        stripped = line.strip()
        indent = len(line) - len(line.lstrip(" "))
        if not in_tasks:
            if indent == 0 and stripped.startswith("tasks:"):
                in_tasks = True
            continue

        if indent == 0 and stripped and not stripped.startswith("#"):
            if entry_start >= 0:
                entries.append((entry_start, idx))
            break

        if indent == 2 and stripped.startswith("- "):
            if entry_start >= 0:
                entries.append((entry_start, idx))
            entry_start = idx

    if in_tasks and entry_start >= 0:
        entries.append((entry_start, len(lines)))

    if not entries:
        _log("warn", f"planner tasks YAML has no entries under tasks: {plan_tasks_path}")
        return False

    for start, end in entries:
        matched_id = ""
        needs_idx = -1
        needs_is_inline = False
        for idx in range(start, end):
            line = lines[idx]
            stripped = line.strip()
            indent = len(line) - len(line.lstrip(" "))
            if idx == start and indent == 2 and stripped.startswith("- "):
                inline = stripped[2:].strip()
                if ":" not in inline:
                    continue
                key, raw_value = inline.split(":", 1)
                key = key.strip()
                if key == "id":
                    matched_id = _to_text(_parse_yaml_scalar(raw_value))
                elif key == "needs_architect":
                    needs_idx = idx
                    needs_is_inline = True
                continue

            if indent != 4 or ":" not in stripped:
                continue
            key, raw_value = stripped.split(":", 1)
            key = key.strip()
            if key == "id":
                matched_id = _to_text(_parse_yaml_scalar(raw_value))
            elif key == "needs_architect":
                needs_idx = idx

        if matched_id not in {task_id, local_task_id}:
            continue

        if needs_idx >= 0:
            if needs_is_inline:
                lines[needs_idx] = f"  - needs_architect: true{newline}"
            else:
                lines[needs_idx] = f"    needs_architect: true{newline}"
        else:
            lines.insert(end, f"    needs_architect: true{newline}")
        return _atomic_write_text(plan_tasks_path, "".join(lines))

    _log(
        "warn",
        (
            f"planner tasks entry not found for task_id={task_id} "
            f"(local_id={local_task_id}) in '{plan_tasks_path}'"
        ),
    )
    return False


def _find_worker_task_path(queue_dir: str, task_id: str, assigned_worker: str) -> str:
    tasks_dir = os.path.join(queue_dir, "tasks")
    if not os.path.isdir(tasks_dir):
        return ""

    candidate_paths: List[str] = []
    if assigned_worker:
        candidate_paths.append(os.path.join(tasks_dir, f"{assigned_worker}.yaml"))
    for task_path in sorted(glob.glob(os.path.join(tasks_dir, "*.yaml"))):
        if task_path not in candidate_paths:
            candidate_paths.append(task_path)

    for task_path in candidate_paths:
        if not os.path.isfile(task_path):
            continue
        info = _read_task_header(task_path)
        if _to_text(info.get("task_id")) == task_id:
            return task_path
    return ""


def _persist_needs_architect_metadata(queue_dir: str, task_id: str, assigned_worker: str, cmd_id: str) -> None:
    worker_task_path = _find_worker_task_path(queue_dir, task_id, assigned_worker)
    if worker_task_path:
        if not _set_worker_task_needs_architect_true(worker_task_path):
            _log("warn", f"failed to persist needs_architect=true for worker task: {worker_task_path}")
    else:
        _log(
            "warn",
            f"worker task YAML not found for needs_architect escalation task_id={task_id} worker={assigned_worker}",
        )

    resolved_cmd_id = _to_text(cmd_id) or _derive_cmd_id(task_id)
    if not resolved_cmd_id:
        _log("warn", f"cannot resolve cmd_id for needs_architect escalation task_id={task_id}")
        return

    plan_tasks_path = os.path.join(queue_dir, "plan", resolved_cmd_id, "tasks.yaml")
    if os.path.isfile(plan_tasks_path):
        if not _set_plan_task_needs_architect_true(plan_tasks_path, task_id, resolved_cmd_id):
            _log("warn", f"failed to persist needs_architect=true in planner tasks: {plan_tasks_path}")
    else:
        _log("warn", f"planner tasks YAML not found for needs_architect escalation: {plan_tasks_path}")


def _read_task_header(task_path: str) -> Dict[str, Any]:
    parsed: Dict[str, Any] = {
        "task_id": "",
        "parent_cmd_id": "",
        "assigned_to": "",
        "needs_architect": False,
        "status": "",
    }
    try:
        with open(task_path, "r", encoding="utf-8") as fh:
            for raw_line in fh:
                if not raw_line.startswith("  ") or raw_line.startswith("    "):
                    continue
                stripped = raw_line.strip()
                if ":" not in stripped:
                    continue
                key, raw_value = stripped.split(":", 1)
                key = key.strip()
                if key not in parsed:
                    continue
                parsed[key] = _parse_yaml_scalar(raw_value)
    except OSError as exc:
        _log("warn", f"failed to read task YAML '{task_path}': {exc}")
    parsed["task_id"] = _to_text(parsed.get("task_id"))
    parsed["parent_cmd_id"] = _to_text(parsed.get("parent_cmd_id"))
    parsed["assigned_to"] = _to_text(parsed.get("assigned_to"))
    parsed["status"] = _to_text(parsed.get("status")).lower()
    parsed["needs_architect"] = _to_bool(parsed.get("needs_architect"), False)
    return parsed


def _collect_tasks_for_cmd(queue_dir: str, cmd_id: str) -> List[Dict[str, Any]]:
    tasks_dir = os.path.join(queue_dir, "tasks")
    if not os.path.isdir(tasks_dir):
        return []

    results: List[Dict[str, Any]] = []
    for task_path in sorted(glob.glob(os.path.join(tasks_dir, "*.yaml"))):
        info = _read_task_header(task_path)
        task_id = _to_text(info.get("task_id"))
        if not task_id:
            continue

        if cmd_id:
            parent_cmd_id = _to_text(info.get("parent_cmd_id"))
            if parent_cmd_id != cmd_id and not task_id.startswith(f"{cmd_id}_"):
                continue

        status = _to_text(info.get("status")).lower()
        if status in {"idle", "done", "completed"}:
            continue

        results.append(info)

    results.sort(key=lambda item: _to_text(item.get("task_id")))
    return results


def _derive_cmd_id(task_id: str) -> str:
    marker = "_task_"
    idx = task_id.find(marker)
    if idx <= 0:
        return ""
    return task_id[:idx]


def _safe_log_signal(logger: EventLogger, task_id: str, role: str, sig_hash: str, accepted: bool) -> None:
    try:
        logger.log_signal_received(task_id=task_id, role=role, sig_hash=sig_hash, accepted=accepted)
    except Exception as exc:
        _log("warn", f"event_logger.log_signal_received failed: {exc}")


def _safe_log_transition(
    logger: EventLogger,
    task_id: str,
    from_phase: str,
    to_phase: str,
    role: str,
    signal_dict: Dict[str, Any],
) -> None:
    try:
        logger.log_transition(
            task_id=task_id,
            from_phase=from_phase,
            to_phase=to_phase,
            role=role,
            trigger_signal=signal_dict,
        )
    except Exception as exc:
        _log("warn", f"event_logger.log_transition failed: {exc}")


def _safe_log_error(logger: EventLogger, task_id: str, error_type: str, message: str, role: str) -> None:
    try:
        logger.log_error(task_id=task_id, error_type=error_type, message=message, role=role)
    except Exception as exc:
        _log("warn", f"event_logger.log_error failed: {exc}")


def _safe_log_dispatch(logger: EventLogger, task_id: str, role: str, pane_id: str, command: str) -> None:
    try:
        logger.log_dispatch(task_id=task_id, role=role, pane_id=pane_id, command=command)
    except Exception as exc:
        _log("warn", f"event_logger.log_dispatch failed: {exc}")


def _safe_log_escalation(logger: EventLogger, task_id: str, reason: str, target: str) -> None:
    try:
        logger.log_escalation(task_id=task_id, reason=reason, target=target)
    except Exception as exc:
        _log("warn", f"event_logger.log_escalation failed: {exc}")


def _worker_from_pane(panes: Dict[str, Any], pane_id: str) -> str:
    workers = panes.get("workers")
    if not isinstance(workers, dict):
        return ""
    for worker_id, worker_pane in workers.items():
        if _to_text(worker_pane) == pane_id:
            return _to_text(worker_id)
    return ""


def _resolve_target_pane(panes: Dict[str, Any], role: str, assigned_worker: str) -> str:
    workers = panes.get("workers")
    if role == ROLE_IMPLEMENTER and isinstance(workers, dict) and assigned_worker:
        return _to_text(workers.get(assigned_worker))

    candidates = [role, role.replace("-", "_"), role.replace("_", "-")]
    for key in candidates:
        value = _to_text(panes.get(key))
        if value:
            return value
    return ""


def _phase_is_consistent(task_state: Optional[Dict[str, Any]], signal_dict: Dict[str, Any]) -> bool:
    if task_state is None:
        return True

    phase = _to_text(task_state.get("phase")).lower()
    if not phase:
        return True

    role = _to_text(signal_dict.get("role")).lower()
    mission = _to_text(signal_dict.get("mission")).lower()
    status = _to_text(signal_dict.get("status")).lower()

    if role == ROLE_PLANNER:
        return True
    if role == ROLE_ARCHITECT:
        return phase == "design"
    if role == ROLE_IMPLEMENTER:
        if mission == "error" and status == STATUS_NEEDS_ARCHITECT:
            return phase in {"implement", "design"}
        return phase == "implement"
    if role == ROLE_REVIEWER:
        return phase == "review"
    if role == ROLE_QUALITY_GATE:
        return phase == "quality-gate"

    return True


def _capture_pane_tail(tmux_session: str, pane_id: str) -> Optional[str]:
    cmd = ["tmux", "capture-pane", "-t", f"{tmux_session}:{pane_id}", "-p", "-S", "-20"]
    for attempt in range(1, CAPTURE_PANE_RETRY_MAX + 1):
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
        except OSError as exc:
            if attempt < CAPTURE_PANE_RETRY_MAX:
                _log(
                    "warn",
                    f"tmux capture-pane execution failed for pane '{pane_id}' attempt={attempt}/{CAPTURE_PANE_RETRY_MAX}: {exc}; retrying",
                )
                time.sleep(COMMAND_RETRY_SLEEP_SEC)
                continue
            _log("warn", f"tmux capture-pane execution failed for pane '{pane_id}': {exc}")
            return None

        if proc.returncode == 0:
            return proc.stdout

        detail = _to_text(proc.stderr) or _to_text(proc.stdout) or f"rc={proc.returncode}"
        if attempt < CAPTURE_PANE_RETRY_MAX:
            _log(
                "warn",
                f"tmux capture-pane failed for pane '{pane_id}' attempt={attempt}/{CAPTURE_PANE_RETRY_MAX}: {detail}; retrying",
            )
            time.sleep(COMMAND_RETRY_SLEEP_SEC)
            continue
        _log("warn", f"tmux capture-pane failed for pane '{pane_id}': {detail}")
        return None
    return None


def notify_oyabun(session: str, oyabun_pane: str, message: str) -> bool:
    send_rc = subprocess.run(
        ["tmux", "send-keys", "-t", f"{session}:{oyabun_pane}", message],
        check=False,
    ).returncode
    enter_rc = subprocess.run(
        ["tmux", "send-keys", "-t", f"{session}:{oyabun_pane}", "Enter"],
        check=False,
    ).returncode
    return send_rc == 0 and enter_rc == 0


def _build_dispatch_command(
    repo_root: str,
    session_id: str,
    target_role: str,
    task_id: str,
    cmd_id: str,
    dispatch_mode: str,
) -> Tuple[List[str], str]:
    command = [
        "bash",
        "scripts/yb_dispatch.sh",
        "--repo",
        repo_root,
        "--session",
        session_id,
    ]

    mode = dispatch_mode or DISPATCH_CALL_DEFAULT
    if mode == DISPATCH_CALL_PLANNER:
        if not cmd_id:
            return command, "planner dispatch requires cmd_id"
        command.extend(["--planner", "--cmd-id", cmd_id])
        return command, ""

    if mode == DISPATCH_CALL_ARCHITECT_DONE:
        if not cmd_id:
            return command, "architect_done dispatch requires cmd_id"
        command.extend(["--architect-done", "--cmd-id", cmd_id])
        return command, ""

    if mode == DISPATCH_CALL_ROLE:
        if target_role not in {ROLE_REVIEWER, ROLE_QUALITY_GATE}:
            return command, f"role dispatch does not support target_role='{target_role}'"
        if not task_id:
            return command, "role dispatch requires task_id"
        command.extend(["--role", target_role, "--task-id", task_id])
        return command, ""

    if mode != DISPATCH_CALL_DEFAULT:
        return command, f"unsupported dispatch_mode='{mode}'"
    return command, ""


def _run_dispatch(
    repo_root: str,
    session_id: str,
    target_role: str,
    task_id: str,
    cmd_id: str,
    dispatch_mode: str,
) -> Tuple[int, List[str], str]:
    command, validation_error = _build_dispatch_command(
        repo_root=repo_root,
        session_id=session_id,
        target_role=target_role,
        task_id=task_id,
        cmd_id=cmd_id,
        dispatch_mode=dispatch_mode,
    )
    if validation_error:
        return 2, command, validation_error

    try:
        proc = subprocess.run(command, cwd=repo_root, capture_output=True, text=True, check=False)
    except OSError as exc:
        return 127, command, str(exc)

    detail = _to_text(proc.stderr) or _to_text(proc.stdout)
    return proc.returncode, command, detail


def _run_collect(repo_root: str, session_id: str) -> Tuple[int, List[str], str]:
    command = [
        "bash",
        "scripts/yb_collect.sh",
        "--repo",
        repo_root,
        "--session",
        session_id,
    ]
    try:
        proc = subprocess.run(command, cwd=repo_root, capture_output=True, text=True, check=False)
    except OSError as exc:
        return 127, command, str(exc)

    detail = _to_text(proc.stderr) or _to_text(proc.stdout)
    return proc.returncode, command, detail


def _append_dispatch_action(
    actions: List[Dict[str, Any]],
    *,
    role: str,
    task_id: str,
    cmd_id: str,
    pane_id: str,
    dispatch_mode: str,
    affected_task_ids: Optional[List[str]] = None,
) -> None:
    normalized_task_ids: List[str] = []
    if affected_task_ids:
        for candidate in affected_task_ids:
            task_text = _to_text(candidate)
            if task_text:
                normalized_task_ids.append(task_text)
    if not normalized_task_ids and task_id:
        normalized_task_ids.append(task_id)

    actions.append(
        {
            "type": "dispatch",
            "role": role,
            "task_id": task_id,
            "cmd_id": cmd_id,
            "pane_id": pane_id,
            "dispatch_mode": dispatch_mode,
            "affected_task_ids": normalized_task_ids,
        }
    )


def _append_collect_action(actions: List[Dict[str, Any]], *, reason: str, task_id: str = "", cmd_id: str = "") -> None:
    actions.append({"type": "collect", "reason": reason, "task_id": task_id, "cmd_id": cmd_id})


def _append_notify_action(actions: List[Dict[str, Any]], *, message: str) -> None:
    actions.append({"type": "notify", "message": message})


def _transition_task(
    sm: StateManager,
    logger: EventLogger,
    *,
    task_id: str,
    from_phase: str,
    to_phase: str,
    loop_count: int,
    assigned_worker: str,
    role: str,
    signal_dict: Dict[str, Any],
    cmd_id: str,
    extra: Optional[Dict[str, Any]] = None,
) -> None:
    payload: Dict[str, Any] = {}
    if extra:
        payload.update(extra)
    payload["cmd_id"] = cmd_id
    sm.update_task_state(
        task_id,
        phase=to_phase,
        loop_count=loop_count,
        assigned_worker=assigned_worker,
        **payload,
    )
    _safe_log_transition(logger, task_id, from_phase or "(none)", to_phase, role, signal_dict)


def _apply_transition(
    sm: StateManager,
    logger: EventLogger,
    *,
    signal_dict: Dict[str, Any],
    panes: Dict[str, Any],
    mode: str,
    queue_dir: str,
    quality_gate_enabled: bool,
    max_rework_loops: int,
) -> List[Dict[str, Any]]:
    actions: List[Dict[str, Any]] = []

    role = _to_text(signal_dict.get("role")).lower()
    mission = _to_text(signal_dict.get("mission")).lower()
    status = _to_text(signal_dict.get("status")).lower()
    result = _to_text(signal_dict.get("result")).lower()
    pane_id = _to_text(signal_dict.get("pane_id"))
    task_id = _to_text(signal_dict.get("task_id"))
    if not task_id:
        return actions

    current_state = sm.get_task_state(task_id) or {}
    from_phase = _to_text(current_state.get("phase"))
    loop_count = _to_int(current_state.get("loop_count"), 0)
    assigned_worker = _to_text(current_state.get("assigned_worker"))
    if not assigned_worker:
        assigned_worker = _to_text(signal_dict.get("worker_id")) or _worker_from_pane(panes, pane_id)

    cmd_id = _to_text(signal_dict.get("cmd_id")) or _to_text(current_state.get("cmd_id")) or _derive_cmd_id(task_id)
    if not cmd_id:
        cmd_id = "unknown_cmd"

    if role == ROLE_PLANNER and mission == "completed" and status == STATUS_TASKS_READY:
        task_entries = _collect_tasks_for_cmd(queue_dir, cmd_id)
        if not task_entries and task_id:
            task_entries = [
                {
                    "task_id": task_id,
                    "parent_cmd_id": cmd_id,
                    "assigned_to": assigned_worker,
                    "needs_architect": _to_bool(signal_dict.get("needs_architect"), False),
                    "status": "assigned",
                }
            ]

        dispatched_task_ids: List[str] = []
        for entry in task_entries:
            target_task_id = _to_text(entry.get("task_id"))
            if not target_task_id:
                continue
            entry_state = sm.get_task_state(target_task_id) or {}
            if mode == MODE_HYBRID and not entry_state:
                continue

            target_worker = _to_text(entry.get("assigned_to")) or _to_text(entry_state.get("assigned_worker"))
            entry_loop = _to_int(entry_state.get("loop_count"), 0)
            entry_from_phase = _to_text(entry_state.get("phase"))
            entry_cmd_id = _to_text(entry.get("parent_cmd_id")) or _to_text(entry_state.get("cmd_id")) or cmd_id
            if not entry_cmd_id:
                entry_cmd_id = "unknown_cmd"

            needs_architect = _to_bool(entry.get("needs_architect"), False)
            next_phase = "design" if needs_architect else "implement"
            _transition_task(
                sm,
                logger,
                task_id=target_task_id,
                from_phase=entry_from_phase,
                to_phase=next_phase,
                loop_count=entry_loop,
                assigned_worker=target_worker,
                role=ROLE_PLANNER,
                signal_dict=signal_dict,
                cmd_id=entry_cmd_id,
                extra={"review_input_error_count": 0},
            )
            dispatched_task_ids.append(target_task_id)
        if dispatched_task_ids:
            _append_dispatch_action(
                actions,
                role=ROLE_PLANNER,
                task_id=task_id,
                cmd_id=cmd_id,
                pane_id="",
                dispatch_mode=DISPATCH_CALL_PLANNER,
                affected_task_ids=dispatched_task_ids,
            )
        return actions

    if role == ROLE_PLANNER and mission == "error" and status == STATUS_PLANNING_BLOCKER:
        _transition_task(
            sm,
            logger,
            task_id=task_id,
            from_phase=from_phase,
            to_phase="blocked_planning",
            loop_count=loop_count,
            assigned_worker=assigned_worker,
            role=ROLE_PLANNER,
            signal_dict=signal_dict,
            cmd_id=cmd_id,
        )
        reason = _to_text(signal_dict.get("reason")) or "planning_blocker"
        _safe_log_escalation(logger, task_id, reason, "oyabun")
        _append_notify_action(
            actions,
            message=f"[orchestrator] planner blocker for {task_id}: {reason}",
        )
        return actions

    if role == ROLE_ARCHITECT and mission == "completed" and status == STATUS_DESIGN_READY:
        _transition_task(
            sm,
            logger,
            task_id=task_id,
            from_phase=from_phase,
            to_phase="implement",
            loop_count=loop_count,
            assigned_worker=assigned_worker,
            role=ROLE_ARCHITECT,
            signal_dict=signal_dict,
            cmd_id=cmd_id,
            extra={"review_input_error_count": 0},
        )
        target_pane = _resolve_target_pane(panes, ROLE_IMPLEMENTER, assigned_worker)
        _append_dispatch_action(
            actions,
            role=ROLE_IMPLEMENTER,
            task_id=task_id,
            cmd_id=cmd_id,
            pane_id=target_pane,
            dispatch_mode=DISPATCH_CALL_ARCHITECT_DONE,
            affected_task_ids=[task_id],
        )
        return actions

    if role == ROLE_ARCHITECT and mission == "error" and status == STATUS_DESIGN_QUESTIONS:
        _transition_task(
            sm,
            logger,
            task_id=task_id,
            from_phase=from_phase,
            to_phase="blocked_design",
            loop_count=loop_count,
            assigned_worker=assigned_worker,
            role=ROLE_ARCHITECT,
            signal_dict=signal_dict,
            cmd_id=cmd_id,
        )
        reason = _to_text(signal_dict.get("reason")) or "design_questions"
        _safe_log_escalation(logger, task_id, reason, "oyabun")
        _append_notify_action(
            actions,
            message=f"[orchestrator] architect question for {task_id}: {reason}",
        )
        return actions

    if role == ROLE_IMPLEMENTER and mission == "completed" and status == STATUS_DONE:
        _transition_task(
            sm,
            logger,
            task_id=task_id,
            from_phase=from_phase,
            to_phase="review",
            loop_count=loop_count,
            assigned_worker=assigned_worker,
            role=ROLE_IMPLEMENTER,
            signal_dict=signal_dict,
            cmd_id=cmd_id,
            extra={"review_input_error_count": 0},
        )
        target_pane = _resolve_target_pane(panes, ROLE_REVIEWER, assigned_worker)
        _append_dispatch_action(
            actions,
            role=ROLE_REVIEWER,
            task_id=task_id,
            cmd_id=cmd_id,
            pane_id=target_pane,
            dispatch_mode=DISPATCH_CALL_ROLE,
            affected_task_ids=[task_id],
        )
        return actions

    if role == ROLE_IMPLEMENTER and mission == "error" and status == STATUS_NEEDS_ARCHITECT:
        _transition_task(
            sm,
            logger,
            task_id=task_id,
            from_phase=from_phase,
            to_phase="design",
            loop_count=loop_count,
            assigned_worker=assigned_worker,
            role=ROLE_IMPLEMENTER,
            signal_dict=signal_dict,
            cmd_id=cmd_id,
        )
        _persist_needs_architect_metadata(
            queue_dir=queue_dir,
            task_id=task_id,
            assigned_worker=assigned_worker,
            cmd_id=cmd_id,
        )
        target_pane = _resolve_target_pane(panes, ROLE_ARCHITECT, assigned_worker)
        _append_dispatch_action(
            actions,
            role=ROLE_ARCHITECT,
            task_id=task_id,
            cmd_id=cmd_id,
            pane_id=target_pane,
            dispatch_mode=DISPATCH_CALL_PLANNER,
            affected_task_ids=[task_id],
        )
        return actions

    if role == ROLE_REVIEWER and mission == "completed" and status == STATUS_DONE:
        if quality_gate_enabled:
            _transition_task(
                sm,
                logger,
                task_id=task_id,
                from_phase=from_phase,
                to_phase="quality-gate",
                loop_count=loop_count,
                assigned_worker=assigned_worker,
                role=ROLE_REVIEWER,
                signal_dict=signal_dict,
                cmd_id=cmd_id,
                extra={"review_input_error_count": 0},
            )
            target_pane = _resolve_target_pane(panes, ROLE_QUALITY_GATE, assigned_worker)
            _append_dispatch_action(
                actions,
                role=ROLE_QUALITY_GATE,
                task_id=task_id,
                cmd_id=cmd_id,
                pane_id=target_pane,
                dispatch_mode=DISPATCH_CALL_ROLE,
                affected_task_ids=[task_id],
            )
            return actions

        _transition_task(
            sm,
            logger,
            task_id=task_id,
            from_phase=from_phase,
            to_phase="done",
            loop_count=loop_count,
            assigned_worker=assigned_worker,
            role=ROLE_REVIEWER,
            signal_dict=signal_dict,
            cmd_id=cmd_id,
            extra={"review_input_error_count": 0},
        )
        _append_notify_action(
            actions,
            message=f"[orchestrator] review completed for {task_id} (quality gate disabled).",
        )
        return actions

    if role == ROLE_REVIEWER and mission == "error" and status == STATUS_REVIEW_INPUT_ERROR:
        retry_count = _to_int(current_state.get("review_input_error_count"), 0)
        if retry_count <= 0:
            _transition_task(
                sm,
                logger,
                task_id=task_id,
                from_phase=from_phase,
                to_phase="review",
                loop_count=loop_count,
                assigned_worker=assigned_worker,
                role=ROLE_REVIEWER,
                signal_dict=signal_dict,
                cmd_id=cmd_id,
                extra={"review_input_error_count": 1},
            )
            _append_collect_action(actions, reason="review_input_error", task_id=task_id, cmd_id=cmd_id)
            target_pane = _resolve_target_pane(panes, ROLE_REVIEWER, assigned_worker)
            _append_dispatch_action(
                actions,
                role=ROLE_REVIEWER,
                task_id=task_id,
                cmd_id=cmd_id,
                pane_id=target_pane,
                dispatch_mode=DISPATCH_CALL_ROLE,
                affected_task_ids=[task_id],
            )
            return actions

        _transition_task(
            sm,
            logger,
            task_id=task_id,
            from_phase=from_phase,
            to_phase="blocked_review",
            loop_count=loop_count,
            assigned_worker=assigned_worker,
            role=ROLE_REVIEWER,
            signal_dict=signal_dict,
            cmd_id=cmd_id,
            extra={"review_input_error_count": retry_count + 1},
        )
        reason = _to_text(signal_dict.get("reason")) or "review_input_error_repeated"
        _safe_log_escalation(logger, task_id, reason, "oyabun")
        _append_notify_action(
            actions,
            message=f"[orchestrator] reviewer input error repeated for {task_id}: {reason}",
        )
        return actions

    if role == ROLE_QUALITY_GATE and mission == "completed":
        if result == RESULT_APPROVE:
            _transition_task(
                sm,
                logger,
                task_id=task_id,
                from_phase=from_phase,
                to_phase="done",
                loop_count=loop_count,
                assigned_worker=assigned_worker,
                role=ROLE_QUALITY_GATE,
                signal_dict=signal_dict,
                cmd_id=cmd_id,
                extra={"review_input_error_count": 0},
            )
            _append_notify_action(
                actions,
                message=f"[orchestrator] quality-gate approved {task_id}.",
            )
            return actions

        if result == RESULT_REWORK:
            next_loop = loop_count + 1
            if next_loop > max_rework_loops:
                _transition_task(
                    sm,
                    logger,
                    task_id=task_id,
                    from_phase=from_phase,
                    to_phase="blocked_rework",
                    loop_count=next_loop,
                    assigned_worker=assigned_worker,
                    role=ROLE_QUALITY_GATE,
                    signal_dict=signal_dict,
                    cmd_id=cmd_id,
                )
                reason = f"max_rework_loops_exceeded ({next_loop}>{max_rework_loops})"
                _safe_log_escalation(logger, task_id, reason, "oyabun")
                _append_notify_action(
                    actions,
                    message=f"[orchestrator] rework loop exceeded for {task_id}: {reason}",
                )
                return actions

            _transition_task(
                sm,
                logger,
                task_id=task_id,
                from_phase=from_phase,
                to_phase="implement",
                loop_count=next_loop,
                assigned_worker=assigned_worker,
                role=ROLE_QUALITY_GATE,
                signal_dict=signal_dict,
                cmd_id=cmd_id,
                extra={"review_input_error_count": 0},
            )
            target_pane = _resolve_target_pane(panes, ROLE_IMPLEMENTER, assigned_worker)
            _append_dispatch_action(
                actions,
                role=ROLE_IMPLEMENTER,
                task_id=task_id,
                cmd_id=cmd_id,
                pane_id=target_pane,
                dispatch_mode=DISPATCH_CALL_DEFAULT,
                affected_task_ids=[task_id],
            )
            return actions

    if role == ROLE_QUALITY_GATE and mission == "error" and status == STATUS_GATE_BLOCKED:
        _transition_task(
            sm,
            logger,
            task_id=task_id,
            from_phase=from_phase,
            to_phase="blocked_gate",
            loop_count=loop_count,
            assigned_worker=assigned_worker,
            role=ROLE_QUALITY_GATE,
            signal_dict=signal_dict,
            cmd_id=cmd_id,
        )
        reason = _to_text(signal_dict.get("reason")) or "gate_blocked"
        _safe_log_escalation(logger, task_id, reason, "oyabun")
        _append_notify_action(
            actions,
            message=f"[orchestrator] quality-gate blocked for {task_id}: {reason}",
        )
        return actions

    return actions


def _normalize_task_id_list(raw_value: Any, fallback_task_id: str = "") -> List[str]:
    values: List[str] = []
    if isinstance(raw_value, list):
        for item in raw_value:
            task_id = _to_text(item)
            if task_id:
                values.append(task_id)
    fallback = _to_text(fallback_task_id)
    if not values and fallback:
        values.append(fallback)
    return values


def _notify_oyabun_with_error_log(
    logger: EventLogger,
    *,
    tmux_session: str,
    oyabun_pane: str,
    message: str,
) -> None:
    if not tmux_session or not oyabun_pane:
        _log("warn", f"oyabun pane is missing; skipped notification: {message}")
        return
    ok = notify_oyabun(tmux_session, oyabun_pane, message)
    if not ok:
        _log("warn", f"failed to notify oyabun for message: {message}")
        _safe_log_error(
            logger,
            task_id="",
            error_type="notify_failed",
            message=message,
            role="orchestrator",
        )


def _mark_task_blocked(
    sm: StateManager,
    logger: EventLogger,
    *,
    task_id: str,
    cmd_id: str,
    blocked_phase: str,
    reason: str,
    error_type: str,
) -> None:
    target_task_id = _to_text(task_id)
    if not target_task_id:
        return

    current_state = sm.get_task_state(target_task_id) or {}
    assigned_worker = _to_text(current_state.get("assigned_worker"))
    loop_count = _to_int(current_state.get("loop_count"), 0)
    resolved_cmd_id = _to_text(cmd_id) or _to_text(current_state.get("cmd_id")) or _derive_cmd_id(target_task_id)
    if not resolved_cmd_id:
        resolved_cmd_id = "unknown_cmd"

    sm.update_task_state(
        target_task_id,
        phase=blocked_phase,
        loop_count=loop_count,
        assigned_worker=assigned_worker,
        cmd_id=resolved_cmd_id,
        blocked_reason=reason,
    )
    _safe_log_error(
        logger,
        task_id=target_task_id,
        error_type=error_type,
        message=reason,
        role="orchestrator",
    )


def _run_dispatch_with_retry(
    repo_root: str,
    session_id: str,
    target_role: str,
    task_id: str,
    cmd_id: str,
    dispatch_mode: str,
) -> Tuple[int, List[str], str]:
    last_rc = 1
    last_command: List[str] = []
    last_detail = ""
    for attempt in range(1, COMMAND_RETRY_MAX + 1):
        rc, command, detail = _run_dispatch(
            repo_root,
            session_id,
            target_role,
            task_id,
            cmd_id,
            dispatch_mode,
        )
        last_rc = rc
        last_command = command
        last_detail = detail
        if rc == 0:
            return rc, command, detail
        if attempt < COMMAND_RETRY_MAX:
            _log(
                "warn",
                f"dispatch retry scheduled role={target_role} task_id={task_id} mode={dispatch_mode} attempt={attempt}/{COMMAND_RETRY_MAX} rc={rc}",
            )
            time.sleep(COMMAND_RETRY_SLEEP_SEC)
    return last_rc, last_command, last_detail


def _run_collect_with_retry(repo_root: str, session_id: str) -> Tuple[int, List[str], str]:
    last_rc = 1
    last_command: List[str] = []
    last_detail = ""
    for attempt in range(1, COMMAND_RETRY_MAX + 1):
        rc, command, detail = _run_collect(repo_root, session_id)
        last_rc = rc
        last_command = command
        last_detail = detail
        if rc == 0:
            return rc, command, detail
        if attempt < COMMAND_RETRY_MAX:
            _log("warn", f"collect retry scheduled attempt={attempt}/{COMMAND_RETRY_MAX} rc={rc}")
            time.sleep(COMMAND_RETRY_SLEEP_SEC)
    return last_rc, last_command, last_detail


def _execute_actions(
    sm: StateManager,
    logger: EventLogger,
    *,
    actions: List[Dict[str, Any]],
    repo_root: str,
    session_id: str,
    tmux_session: str,
    oyabun_pane: str,
    lock_dir: str,
) -> None:
    collect_failed_tasks: set[str] = set()

    for action in actions:
        action_type = _to_text(action.get("type"))

        if action_type == "dispatch":
            target_role = _to_text(action.get("role"))
            task_id = _to_text(action.get("task_id"))
            cmd_id = _to_text(action.get("cmd_id")) or _derive_cmd_id(task_id) or "unknown_cmd"
            pane_id = _to_text(action.get("pane_id"))
            dispatch_mode = _to_text(action.get("dispatch_mode"))
            if not dispatch_mode:
                if target_role in {ROLE_REVIEWER, ROLE_QUALITY_GATE}:
                    dispatch_mode = DISPATCH_CALL_ROLE
                else:
                    dispatch_mode = DISPATCH_CALL_DEFAULT
            affected_task_ids = _normalize_task_id_list(action.get("affected_task_ids"), task_id)

            if any(task in collect_failed_tasks for task in affected_task_ids):
                _log(
                    "warn",
                    f"dispatch skipped due prior collect failure task_id={task_id} role={target_role} mode={dispatch_mode}",
                )
                continue

            if not sm.acquire_lock("dispatch"):
                reason = f"dispatch lock is already held; skipped dispatch action role={target_role}"
                _log("warn", reason)
                for affected_task_id in affected_task_ids:
                    _mark_task_blocked(
                        sm,
                        logger,
                        task_id=affected_task_id,
                        cmd_id=cmd_id,
                        blocked_phase=BLOCKED_PHASE_DISPATCH,
                        reason=reason,
                        error_type="dispatch_lock_busy",
                    )
                _notify_oyabun_with_error_log(
                    logger,
                    tmux_session=tmux_session,
                    oyabun_pane=oyabun_pane,
                    message=f"[orchestrator] dispatch lock busy; blocked tasks={','.join(affected_task_ids) or task_id}",
                )
                continue

            process_lock_fd: Optional[int] = None
            try:
                process_lock_fd, lock_path = _acquire_process_lock(lock_dir, PROCESS_LOCK_DISPATCH_COLLECT)
                if process_lock_fd is None:
                    command, _ = _build_dispatch_command(
                        repo_root=repo_root,
                        session_id=session_id,
                        target_role=target_role,
                        task_id=task_id,
                        cmd_id=cmd_id,
                        dispatch_mode=dispatch_mode,
                    )
                    rc = 1
                    detail = f"process lock timeout: {lock_path}"
                else:
                    rc, command, detail = _run_dispatch_with_retry(
                        repo_root,
                        session_id,
                        target_role,
                        task_id,
                        cmd_id,
                        dispatch_mode,
                    )

                command_str = " ".join(shlex.quote(token) for token in command)
                _safe_log_dispatch(logger, task_id, target_role, pane_id, command_str)
                if rc != 0:
                    failure_reason = detail or f"rc={rc}"
                    _log(
                        "warn",
                        f"dispatch failed role={target_role} task_id={task_id} mode={dispatch_mode} rc={rc} detail={failure_reason}",
                    )
                    for affected_task_id in affected_task_ids:
                        _mark_task_blocked(
                            sm,
                            logger,
                            task_id=affected_task_id,
                            cmd_id=cmd_id,
                            blocked_phase=BLOCKED_PHASE_DISPATCH,
                            reason=f"dispatch_failed role={target_role} mode={dispatch_mode} detail={failure_reason}",
                            error_type="dispatch_failed",
                        )
                    _notify_oyabun_with_error_log(
                        logger,
                        tmux_session=tmux_session,
                        oyabun_pane=oyabun_pane,
                        message=(
                            f"[orchestrator] dispatch failed role={target_role} mode={dispatch_mode} "
                            f"tasks={','.join(affected_task_ids) or task_id} rc={rc} detail={failure_reason}"
                        ),
                    )
            finally:
                _release_process_lock(process_lock_fd)
                sm.release_lock("dispatch")
            continue

        if action_type == "collect":
            reason = _to_text(action.get("reason"))
            task_id = _to_text(action.get("task_id"))
            cmd_id = _to_text(action.get("cmd_id")) or _derive_cmd_id(task_id) or "unknown_cmd"

            if not sm.acquire_lock("collect"):
                failure_reason = "collect lock is already held; skipped collect action"
                _log("warn", failure_reason)
                if task_id:
                    collect_failed_tasks.add(task_id)
                    _mark_task_blocked(
                        sm,
                        logger,
                        task_id=task_id,
                        cmd_id=cmd_id,
                        blocked_phase=BLOCKED_PHASE_COLLECT,
                        reason=failure_reason,
                        error_type="collect_lock_busy",
                    )
                _notify_oyabun_with_error_log(
                    logger,
                    tmux_session=tmux_session,
                    oyabun_pane=oyabun_pane,
                    message=f"[orchestrator] collect lock busy reason={reason or '(none)'} task_id={task_id or '(none)'}",
                )
                continue

            process_lock_fd: Optional[int] = None
            try:
                process_lock_fd, lock_path = _acquire_process_lock(lock_dir, PROCESS_LOCK_DISPATCH_COLLECT)
                if process_lock_fd is None:
                    rc = 1
                    detail = f"process lock timeout: {lock_path}"
                else:
                    rc, _, detail = _run_collect_with_retry(repo_root, session_id)

                if rc != 0:
                    failure_reason = detail or f"rc={rc}"
                    _log("warn", f"collect failed reason={reason or '(none)'} rc={rc} detail={failure_reason}")
                    if task_id:
                        collect_failed_tasks.add(task_id)
                        _mark_task_blocked(
                            sm,
                            logger,
                            task_id=task_id,
                            cmd_id=cmd_id,
                            blocked_phase=BLOCKED_PHASE_COLLECT,
                            reason=f"collect_failed detail={failure_reason}",
                            error_type="collect_failed",
                        )
                    else:
                        _safe_log_error(
                            logger,
                            task_id="",
                            error_type="collect_failed",
                            message=failure_reason,
                            role="orchestrator",
                        )
                    _notify_oyabun_with_error_log(
                        logger,
                        tmux_session=tmux_session,
                        oyabun_pane=oyabun_pane,
                        message=(
                            f"[orchestrator] collect failed reason={reason or '(none)'} "
                            f"task_id={task_id or '(none)'} rc={rc} detail={failure_reason}"
                        ),
                    )
            finally:
                _release_process_lock(process_lock_fd)
                sm.release_lock("collect")
            continue

        if action_type == "notify":
            message = _to_text(action.get("message"))
            _notify_oyabun_with_error_log(
                logger,
                tmux_session=tmux_session,
                oyabun_pane=oyabun_pane,
                message=message,
            )


def _sync_state_metadata(sm: StateManager, mode: str, poll_interval_sec: int) -> None:
    state = sm.state
    state["schema_version"] = 1
    state["mode"] = mode
    state["poll_interval_sec"] = poll_interval_sec
    if "version" not in state:
        state["version"] = "v2-alpha"


def _escape_md(value: str) -> str:
    return value.replace("|", r"\|")


def update_dashboard(work_dir: str, sm: StateManager, mode: str, poll_interval_sec: int) -> None:
    if not work_dir:
        return
    os.makedirs(work_dir, exist_ok=True)
    dashboard_path = os.path.join(work_dir, "dashboard.md")
    state = sm.state
    task_state = state.get("taskState")
    if not isinstance(task_state, dict):
        task_state = {}

    now = dt.datetime.now().isoformat(timespec="seconds")
    lines: List[str] = [
        "# Orchestrator Dashboard",
        f"- Last Updated: {now}",
        f"- Mode: {mode}",
        f"- Poll Interval (sec): {poll_interval_sec}",
        "",
        "| Task ID | Phase | Loop | Assigned Worker | Updated At |",
        "|---|---|---:|---|---|",
    ]

    if task_state:
        for task_id in sorted(task_state.keys()):
            entry = task_state.get(task_id)
            if not isinstance(entry, dict):
                continue
            phase = _escape_md(_to_text(entry.get("phase")) or "-")
            loop = _to_int(entry.get("loop_count"), 0)
            worker = _escape_md(_to_text(entry.get("assigned_worker")) or "-")
            updated_at = _escape_md(_to_text(entry.get("updated_at")) or "-")
            lines.append(f"| {_escape_md(task_id)} | {phase} | {loop} | {worker} | {updated_at} |")
    else:
        lines.append("| - | - | - | - | - |")

    with open(dashboard_path, "w", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def _handle_stop_signal(signum: int, _frame: Any) -> None:
    global _STOP_REQUESTED
    _STOP_REQUESTED = True
    _log("info", f"received signal {signum}; graceful shutdown requested")


def _parse_args(argv: Optional[List[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Yamibaito orchestrator control plane")
    parser.add_argument("--repo", required=True, help="Repository root path")
    parser.add_argument("--session", default="", help="Session id for panes_<session>.json")
    parser.add_argument("--mode", required=True, choices=VALID_MODES, help="Orchestrator mode")
    parser.add_argument(
        "--poll-interval",
        type=int,
        default=None,
        help="Polling interval in seconds (default: config orchestrator.poll_interval_sec)",
    )
    parser.add_argument(
        "--state-dir",
        default=None,
        help="State directory (default: <repo_root>/.yamibaito/runtime)",
    )
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = _parse_args(argv)

    repo_root = os.path.abspath(args.repo)
    config = _load_runtime_config(repo_root)

    configured_mode = _to_text(config.get("mode"))
    mode = _to_text(args.mode)
    if configured_mode and configured_mode != mode:
        _log(
            "warn",
            f"CLI mode '{mode}' differs from config orchestrator.mode '{configured_mode}'; using CLI mode",
        )

    if mode == MODE_LEGACY:
        _log("info", "mode=legacy: orchestrator loop is disabled; exiting")
        return 0

    poll_interval_sec = _to_int(config.get("poll_interval_sec"), 5)
    if args.poll_interval is not None:
        if args.poll_interval > 0:
            poll_interval_sec = args.poll_interval
        else:
            _log("warn", f"invalid --poll-interval '{args.poll_interval}'; using {poll_interval_sec}")

    max_signal_history = _to_int(config.get("max_signal_history"), 2000)
    if max_signal_history <= 0:
        max_signal_history = 2000

    quality_gate_enabled = _to_bool(config.get("quality_gate_enabled"), True)
    max_rework_loops = _to_int(config.get("max_rework_loops"), 3)

    session_id = _sanitize_session_id(_to_text(args.session))
    state_dir = _to_text(args.state_dir) or os.path.join(repo_root, ".yamibaito", "runtime")
    os.makedirs(state_dir, exist_ok=True)
    lock_dir = os.path.join(state_dir, "orchestrator-locks")
    os.makedirs(lock_dir, exist_ok=True)

    sm = StateManager(state_dir=state_dir, max_signals=max_signal_history)

    logger = EventLogger(events_path=os.path.join(state_dir, "orchestrator-events.jsonl"))

    signal.signal(signal.SIGTERM, _handle_stop_signal)
    signal.signal(signal.SIGINT, _handle_stop_signal)

    _log(
        "info",
        f"orchestrator started mode={mode} poll_interval={poll_interval_sec}s state_dir={state_dir} session='{session_id}'",
    )

    last_work_dir = repo_root
    while not _STOP_REQUESTED:
        state_lock_fd, state_lock_path = _acquire_process_lock(lock_dir, PROCESS_LOCK_STATE_SAVE)
        if state_lock_fd is None:
            _log("warn", f"state cycle lock timeout: {state_lock_path}")
            time.sleep(poll_interval_sec)
            continue
        try:
            try:
                sm.load()
            except Exception as exc:
                _log("error", f"failed to load orchestrator state: {exc}")
                _release_process_lock(state_lock_fd)
                state_lock_fd = None
                time.sleep(poll_interval_sec)
                continue
            _sync_state_metadata(sm, mode, poll_interval_sec)
            try:
                panes_path = _resolve_panes_path(repo_root, session_id)
                panes = load_panes(panes_path)
                if not isinstance(panes, dict):
                    _log("warn", f"panes file is not a mapping: {panes_path}")
                    continue

                tmux_session = _to_text(panes.get("session"))
                oyabun_pane = _to_text(panes.get("oyabun"))
                work_dir = _to_text(panes.get("work_dir")) or repo_root
                queue_dir = _resolve_queue_dir(repo_root, work_dir, session_id, panes)
                last_work_dir = work_dir

                workers = panes.get("workers")
                if not isinstance(workers, dict):
                    _log("warn", f"workers pane map missing in panes file: {panes_path}")
                elif not tmux_session:
                    _log("warn", f"tmux session is missing in panes file: {panes_path}")
                else:
                    for worker_id in sorted(workers.keys()):
                        pane_id = _to_text(workers.get(worker_id))
                        if not pane_id:
                            continue

                        pane_text = _capture_pane_tail(tmux_session, pane_id)
                        if pane_text is None:
                            continue

                        signal_dict = extract_last_json_object(pane_text)
                        if not isinstance(signal_dict, dict):
                            if "{" in pane_text and "}" in pane_text:
                                _log("warn", f"failed to parse JSON signal from pane={pane_id}")
                            continue

                        signal_for_validation = dict(signal_dict)
                        if not _to_text(signal_for_validation.get("pane_id")):
                            signal_for_validation["pane_id"] = pane_id

                        role = _to_text(signal_for_validation.get("role")).lower()
                        is_valid, errors = validate_signal(signal_for_validation, role)
                        if not is_valid:
                            task_id_for_error = _to_text(signal_for_validation.get("task_id"))
                            _safe_log_error(
                                logger,
                                task_id=task_id_for_error,
                                error_type="signal_validation_failed",
                                message="; ".join(errors) if errors else "unknown validation error",
                                role=role or "unknown",
                            )
                            _log(
                                "warn",
                                f"invalid signal from pane={pane_id} role={role or '(missing)'} errors={errors}",
                            )
                            continue

                        normalized_signal = normalize_timestamp(signal_for_validation)
                        normalized_signal["pane_id"] = _to_text(normalized_signal.get("pane_id")) or pane_id
                        normalized_signal["role"] = role

                        task_id = _to_text(normalized_signal.get("task_id"))
                        if not task_id:
                            _safe_log_error(
                                logger,
                                task_id="",
                                error_type="signal_missing_task_id",
                                message=f"missing task_id from pane {pane_id}",
                                role=role,
                            )
                            continue

                        ts_ms = _to_int(normalized_signal.get("ts_ms"), 0)
                        if ts_ms < 0:
                            ts_ms = 0
                        normalized_signal["ts_ms"] = ts_ms

                        task_pane_key = f"{task_id}:{normalized_signal['pane_id']}"
                        if not sm.check_timestamp_guard(task_pane_key, ts_ms):
                            _log(
                                "info",
                                f"dropped signal by timestamp guard task={task_id} pane={pane_id} ts_ms={ts_ms}",
                            )
                            continue

                        sig_hash = compute_sig_hash(normalized_signal)
                        if sm.is_duplicate_signal(sig_hash):
                            _safe_log_signal(logger, task_id, role, sig_hash, False)
                            _log("info", f"dropped duplicate signal task={task_id} pane={pane_id} sig_hash={sig_hash}")
                            continue

                        task_state = sm.get_task_state(task_id)
                        if not _phase_is_consistent(task_state, normalized_signal):
                            sm.update_timestamp(task_pane_key, ts_ms)
                            sm.add_processed_signal(sig_hash)
                            _safe_log_signal(logger, task_id, role, sig_hash, False)
                            _log(
                                "info",
                                f"dropped signal by phase guard task={task_id} role={role} phase={_to_text((task_state or {}).get('phase'))}",
                            )
                            continue

                        if mode == MODE_HYBRID and task_state is None:
                            sm.update_timestamp(task_pane_key, ts_ms)
                            sm.add_processed_signal(sig_hash)
                            _safe_log_signal(logger, task_id, role, sig_hash, False)
                            _log("info", f"hybrid mode ignored unregistered task signal: {task_id}")
                            continue

                        sm.update_timestamp(task_pane_key, ts_ms)
                        sm.add_processed_signal(sig_hash)
                        _safe_log_signal(logger, task_id, role, sig_hash, True)

                        actions = _apply_transition(
                            sm,
                            logger,
                            signal_dict=normalized_signal,
                            panes=panes,
                            mode=mode,
                            queue_dir=queue_dir,
                            quality_gate_enabled=quality_gate_enabled,
                            max_rework_loops=max_rework_loops,
                        )
                        if not actions:
                            _log(
                                "info",
                                f"no transition action for task={task_id} role={role} mission={_to_text(normalized_signal.get('mission'))}",
                            )
                            continue

                        _execute_actions(
                            sm,
                            logger,
                            actions=actions,
                            repo_root=repo_root,
                            session_id=session_id,
                            tmux_session=tmux_session,
                            oyabun_pane=oyabun_pane,
                            lock_dir=lock_dir,
                        )
            except Exception as exc:
                _log("error", f"unexpected exception in main loop: {exc}")
                _safe_log_error(
                    logger,
                    task_id="",
                    error_type="main_loop_exception",
                    message=str(exc),
                    role="orchestrator",
                )
            finally:
                _sync_state_metadata(sm, mode, poll_interval_sec)
                try:
                    sm.save()
                except Exception as exc:
                    _log("error", f"failed to save orchestrator state: {exc}")
                try:
                    update_dashboard(last_work_dir, sm, mode, poll_interval_sec)
                except Exception as exc:
                    _log("error", f"failed to update dashboard: {exc}")
        finally:
            _release_process_lock(state_lock_fd)

        if _STOP_REQUESTED:
            break
        time.sleep(poll_interval_sec)

    _log("info", "orchestrator shutting down")
    state_lock_fd, state_lock_path = _acquire_process_lock(lock_dir, PROCESS_LOCK_STATE_SAVE)
    if state_lock_fd is None:
        _log("error", f"failed to acquire state cycle lock during shutdown: {state_lock_path}")
    else:
        try:
            sm.load()
            _sync_state_metadata(sm, mode, poll_interval_sec)
            sm.save()
        except Exception as exc:
            _log("error", f"failed to save state during shutdown: {exc}")
        finally:
            _release_process_lock(state_lock_fd)
    try:
        update_dashboard(last_work_dir, sm, mode, poll_interval_sec)
    except Exception as exc:
        _log("error", f"failed to update dashboard during shutdown: {exc}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
