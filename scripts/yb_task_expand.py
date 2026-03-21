#!/usr/bin/env python3
"""Expand planner tasks.yaml into worker task YAML files."""

from __future__ import annotations

import datetime as dt
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Tuple

LIST_FIELDS_TASK = {"depends_on", "requirement_ids", "deliverables", "definition_of_done"}
LIST_FIELDS_REQUIREMENT = {"acceptance"}
WORKER_ID_PATTERN = re.compile(r"^worker_[0-9]{3}$")


class ParseError(ValueError):
    """Raised when lightweight YAML parsing fails."""


@dataclass
class ParsedLine:
    number: int
    indent: int
    text: str


def _strip_inline_comment(text: str) -> str:
    out: List[str] = []
    in_single = False
    in_double = False
    escaped = False

    for ch in text:
        if in_double:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_double = False
            continue

        if in_single:
            out.append(ch)
            if ch == "'":
                in_single = False
            continue

        if ch == "#":
            break
        out.append(ch)
        if ch == '"':
            in_double = True
        elif ch == "'":
            in_single = True

    return "".join(out).rstrip()


def _clean_lines(raw: str) -> List[ParsedLine]:
    parsed: List[ParsedLine] = []
    for idx, raw_line in enumerate(raw.splitlines(), start=1):
        line = raw_line.rstrip("\n")
        stripped = line.lstrip(" ")
        if not stripped or stripped.startswith("#"):
            continue

        indent = len(line) - len(stripped)
        cleaned = _strip_inline_comment(stripped).strip()
        if not cleaned:
            continue
        parsed.append(ParsedLine(number=idx, indent=indent, text=cleaned))
    return parsed


def _split_key_value(text: str, line_no: int) -> Tuple[str, str]:
    in_single = False
    in_double = False
    escaped = False

    for idx, ch in enumerate(text):
        if in_double:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_double = False
            continue

        if in_single:
            if ch == "'":
                in_single = False
            continue

        if ch == '"':
            in_double = True
            continue
        if ch == "'":
            in_single = True
            continue

        if ch == ":":
            key = text[:idx].strip()
            value = text[idx + 1 :].strip()
            if not key:
                raise ParseError(f"Line {line_no}: empty key")
            return key, value

    raise ParseError(f"Line {line_no}: invalid mapping entry '{text}'")


def _parse_scalar(text: str) -> Any:
    value = text.strip()
    if not value:
        return ""

    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        quote = value[0]
        body = value[1:-1]
        if quote == '"':
            body = body.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")
        else:
            body = body.replace("\\'", "'").replace("\\\\", "\\")
        return body

    lowered = value.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if lowered in {"null", "~"}:
        return None
    if re.fullmatch(r"-?\d+", value):
        return int(value)

    return value


def _parse_flow_list(text: str, line_no: int) -> List[Any]:
    raw = text.strip()
    if not (raw.startswith("[") and raw.endswith("]")):
        raise ParseError(f"Line {line_no}: invalid flow-style list '{text}'")

    body = raw[1:-1].strip()
    if not body:
        return []

    items: List[str] = []
    current: List[str] = []
    in_single = False
    in_double = False
    escaped = False

    for ch in body:
        if in_double:
            current.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_double = False
            continue

        if in_single:
            current.append(ch)
            if ch == "'":
                in_single = False
            continue

        if ch == ",":
            items.append("".join(current).strip())
            current = []
            continue

        current.append(ch)
        if ch == '"':
            in_double = True
        elif ch == "'":
            in_single = True

    items.append("".join(current).strip())

    parsed_items: List[Any] = []
    for item in items:
        if item:
            parsed_items.append(_parse_scalar(item))
    return parsed_items


def _parse_list_value(raw_value: str, line_no: int) -> Any:
    raw = raw_value.strip()
    if not raw:
        return []
    if raw == "[]":
        return []
    if raw.startswith("["):
        return _parse_flow_list(raw, line_no)
    return _parse_scalar(raw)


def _parse_block_list(lines: List[ParsedLine], start: int, parent_indent: int) -> Tuple[List[Any], int]:
    values: List[Any] = []
    idx = start

    while idx < len(lines):
        line = lines[idx]
        if line.indent <= parent_indent:
            break

        if line.indent != parent_indent + 2 or not line.text.startswith("- "):
            raise ParseError(
                f"Line {line.number}: invalid block list entry; expected indentation {parent_indent + 2}"
            )

        item_text = line.text[2:].strip()
        if not item_text:
            raise ParseError(f"Line {line.number}: empty block list item is not supported")
        values.append(_parse_scalar(item_text))
        idx += 1

    return values, idx


def _parse_map_item(
    lines: List[ParsedLine],
    start: int,
    item_indent: int,
    list_fields: set[str],
) -> Tuple[Dict[str, Any], int]:
    line = lines[start]
    if line.indent != item_indent or not line.text.startswith("- "):
        raise ParseError(f"Line {line.number}: expected list item at indent {item_indent}")

    item: Dict[str, Any] = {}
    first = line.text[2:].strip()
    idx = start + 1

    if first:
        key, value = _split_key_value(first, line.number)
        if key in list_fields:
            item[key] = _parse_list_value(value, line.number)
        else:
            item[key] = _parse_scalar(value)

    while idx < len(lines):
        current = lines[idx]
        if current.indent <= item_indent:
            break
        if current.indent == item_indent and current.text.startswith("- "):
            break
        if current.indent != item_indent + 2:
            raise ParseError(
                f"Line {current.number}: invalid indentation inside list item; expected {item_indent + 2}"
            )

        key, raw_value = _split_key_value(current.text, current.number)
        if key in list_fields:
            if raw_value:
                item[key] = _parse_list_value(raw_value, current.number)
                idx += 1
                continue

            values, idx = _parse_block_list(lines, idx + 1, current.indent)
            item[key] = values
            continue

        item[key] = _parse_scalar(raw_value)
        idx += 1

    return item, idx


def _parse_requirements(lines: List[ParsedLine], start: int, base_indent: int) -> Tuple[List[Dict[str, Any]], int]:
    requirements: List[Dict[str, Any]] = []
    idx = start

    while idx < len(lines):
        line = lines[idx]
        if line.indent <= base_indent:
            break
        if line.indent != base_indent + 2 or not line.text.startswith("- "):
            raise ParseError(f"Line {line.number}: invalid requirements entry")

        item, idx = _parse_map_item(lines, idx, base_indent + 2, LIST_FIELDS_REQUIREMENT)
        requirements.append(item)

    return requirements, idx


def _parse_tasks(lines: List[ParsedLine], start: int, base_indent: int) -> Tuple[List[Dict[str, Any]], int]:
    tasks: List[Dict[str, Any]] = []
    idx = start

    while idx < len(lines):
        line = lines[idx]
        if line.indent <= base_indent:
            break
        if line.indent != base_indent + 2 or not line.text.startswith("- "):
            raise ParseError(f"Line {line.number}: invalid tasks entry")

        item, idx = _parse_map_item(lines, idx, base_indent + 2, LIST_FIELDS_TASK)
        tasks.append(item)

    return tasks, idx


def parse_tasks_yaml(path: Path) -> Dict[str, Any]:
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise ParseError(f"Failed to read tasks file: {path}: {exc}") from exc

    lines = _clean_lines(raw)
    if not lines:
        raise ParseError(f"tasks file is empty: {path}")

    root: Dict[str, Any] = {}
    idx = 0
    while idx < len(lines):
        line = lines[idx]
        if line.indent != 0:
            raise ParseError(f"Line {line.number}: top-level key must start at column 1")

        key, value = _split_key_value(line.text, line.number)

        if key == "requirements":
            if value == "[]":
                root[key] = []
                idx += 1
            elif value:
                raise ParseError(f"Line {line.number}: requirements must be block list or []")
            else:
                parsed, idx = _parse_requirements(lines, idx + 1, line.indent)
                root[key] = parsed
            continue

        if key == "tasks":
            if value == "[]":
                root[key] = []
                idx += 1
            elif value:
                raise ParseError(f"Line {line.number}: tasks must be block list or []")
            else:
                parsed, idx = _parse_tasks(lines, idx + 1, line.indent)
                root[key] = parsed
            continue

        root[key] = _parse_scalar(value)
        idx += 1

    return root


def _ensure_required_root(root: Dict[str, Any]) -> None:
    missing = [k for k in ("version", "epic", "objective", "requirements", "tasks") if k not in root]
    if missing:
        raise ParseError(f"tasks.yaml missing root key(s): {', '.join(missing)}")


def _normalize_required_string_list(value: Any, context: str, field_name: str) -> List[str]:
    if not isinstance(value, list):
        raise ParseError(f"{context} field '{field_name}' must be a list; scalar values are not allowed")

    out: List[str] = []
    for item in value:
        text = str(item).strip()
        if text:
            out.append(text)
    return out


def _ensure_path_within(base_dir: Path, candidate: Path, context: str) -> None:
    base_resolved = base_dir.resolve()
    candidate_resolved = candidate.resolve()
    try:
        candidate_resolved.relative_to(base_resolved)
    except ValueError as exc:
        raise ParseError(
            f"{context}: resolved path '{candidate_resolved}' is outside '{base_resolved}'"
        ) from exc


def _validate_task_semantics(tasks: List[Dict[str, Any]], repo_root: Path) -> None:
    repo_root_resolved = repo_root.resolve()
    seen_task_ids: Dict[str, int] = {}
    duplicate_task_ids: Dict[str, List[int]] = {}
    for index, task in enumerate(tasks, start=1):
        task_id = str(task.get("id", "")).strip()
        previous_index = seen_task_ids.get(task_id)
        if previous_index is not None:
            duplicate_task_ids.setdefault(task_id, [previous_index]).append(index)
            continue
        seen_task_ids[task_id] = index

    if duplicate_task_ids:
        duplicate_parts: List[str] = []
        for task_id, indexes in sorted(duplicate_task_ids.items()):
            index_list = ", ".join(str(idx) for idx in indexes)
            duplicate_parts.append(f"'{task_id}' (task entries: {index_list})")
        raise ParseError(
            "tasks.yaml has duplicate task id(s): "
            + "; ".join(duplicate_parts)
        )

    known_task_ids = set(seen_task_ids.keys())

    for index, task in enumerate(tasks, start=1):
        task_id = task["id"] or f"(task #{index})"
        owner = task["owner"]
        if not owner:
            raise ParseError(
                f"tasks.yaml task '{task_id}' has empty owner; expected worker id like 'worker_001'"
            )
        if not WORKER_ID_PATTERN.fullmatch(owner):
            raise ParseError(
                f"tasks.yaml task '{task_id}' has invalid owner '{owner}'; "
                "expected pattern '^worker_[0-9]{3}$'"
            )

        for depends_id in task.get("depends_on", []):
            if depends_id not in known_task_ids:
                raise ParseError(
                    f"tasks.yaml task '{task_id}' depends_on references unknown task id '{depends_id}'"
                )

        for deliverable in task.get("deliverables", []):
            deliverable_path = Path(deliverable)
            if deliverable_path.is_absolute():
                raise ParseError(
                    f"tasks.yaml task '{task_id}' deliverable '{deliverable}' must be a relative path under repo_root"
                )
            if any(part == ".." for part in deliverable_path.parts):
                raise ParseError(
                    f"tasks.yaml task '{task_id}' deliverable '{deliverable}' contains '..' and is not allowed"
                )

            resolved_deliverable = (repo_root_resolved / deliverable_path).resolve()
            try:
                resolved_deliverable.relative_to(repo_root_resolved)
            except ValueError as exc:
                raise ParseError(
                    f"tasks.yaml task '{task_id}' deliverable '{deliverable}' resolves outside repo_root "
                    f"('{repo_root_resolved}')"
                ) from exc

    dependency_map: Dict[str, List[str]] = {task["id"]: task.get("depends_on", []) for task in tasks}
    visit_state: Dict[str, int] = {}
    path_stack: List[str] = []
    path_index: Dict[str, int] = {}

    def _dfs(task_id: str) -> None:
        visit_state[task_id] = 1
        path_index[task_id] = len(path_stack)
        path_stack.append(task_id)

        for dependency_id in dependency_map.get(task_id, []):
            state = visit_state.get(dependency_id, 0)
            if state == 0:
                _dfs(dependency_id)
                continue
            if state == 1:
                cycle_path = path_stack[path_index[dependency_id] :] + [dependency_id]
                raise ParseError(f"tasks.yaml depends_on has cycle: {' -> '.join(cycle_path)}")

        path_stack.pop()
        path_index.pop(task_id, None)
        visit_state[task_id] = 2

    for task in tasks:
        task_id = task["id"]
        if visit_state.get(task_id, 0) == 0:
            _dfs(task_id)


def _validate_output_path(queue_dir: Path, task_id: str, worker_id: str) -> Path:
    tasks_dir = queue_dir / "tasks"
    output_path = tasks_dir / f"{worker_id}.yaml"
    _ensure_path_within(
        tasks_dir,
        output_path,
        context=f"tasks.yaml task '{task_id}' owner '{worker_id}' output path check",
    )
    return output_path


def _validate_structure(root: Dict[str, Any], repo_root: Path) -> None:
    _ensure_required_root(root)

    requirements = root.get("requirements")
    tasks = root.get("tasks")
    if not isinstance(requirements, list):
        raise ParseError("tasks.yaml requirements must be a list")
    if not isinstance(tasks, list):
        raise ParseError("tasks.yaml tasks must be a list")

    for index, req in enumerate(requirements, start=1):
        if not isinstance(req, dict):
            raise ParseError(f"tasks.yaml requirement #{index} must be a mapping")
        for key in ("id", "title", "acceptance"):
            if key not in req:
                raise ParseError(f"tasks.yaml requirement #{index} missing '{key}'")

        req["id"] = str(req["id"]).strip()
        req["title"] = str(req["title"]).strip()
        req_id = req["id"] or f"(requirement #{index})"
        req["acceptance"] = _normalize_required_string_list(
            req.get("acceptance"),
            context=f"tasks.yaml requirement '{req_id}'",
            field_name="acceptance",
        )

    for index, task in enumerate(tasks, start=1):
        if not isinstance(task, dict):
            raise ParseError(f"tasks.yaml task #{index} must be a mapping")
        required = ("id", "owner", "depends_on", "requirement_ids", "deliverables", "definition_of_done")
        for key in required:
            if key not in task:
                raise ParseError(f"tasks.yaml task #{index} missing '{key}'")

        task["id"] = str(task["id"]).strip()
        task["owner"] = str(task["owner"]).strip()
        task_id = task["id"] or f"(task #{index})"
        context = f"tasks.yaml task '{task_id}'"
        task["depends_on"] = _normalize_required_string_list(
            task.get("depends_on"),
            context=context,
            field_name="depends_on",
        )
        task["requirement_ids"] = _normalize_required_string_list(
            task.get("requirement_ids"),
            context=context,
            field_name="requirement_ids",
        )
        task["deliverables"] = _normalize_required_string_list(
            task.get("deliverables"),
            context=context,
            field_name="deliverables",
        )
        task["definition_of_done"] = _normalize_required_string_list(
            task.get("definition_of_done"),
            context=context,
            field_name="definition_of_done",
        )

        status = task.get("status")
        if status is not None:
            task["status"] = str(status).strip()

        needs_architect = task.get("needs_architect")
        if needs_architect is None:
            task["needs_architect"] = False
        elif isinstance(needs_architect, bool):
            task["needs_architect"] = needs_architect
        else:
            task["needs_architect"] = str(needs_architect).strip().lower() == "true"

    _validate_task_semantics(tasks, repo_root)


def _validate_race_001(tasks: List[Dict[str, Any]]) -> None:
    assigned: Dict[str, Tuple[str, str]] = {}
    for task in tasks:
        task_id = task["id"]
        owner = task["owner"]
        for deliverable in task.get("deliverables", []):
            previous = assigned.get(deliverable)
            if previous and previous[0] != task_id:
                prev_id, prev_owner = previous
                raise ParseError(
                    "RACE-001 violation: file "
                    f"'{deliverable}' assigned to both {prev_id} ({prev_owner}) and {task_id} ({owner})"
                )
            assigned[deliverable] = (task_id, owner)


def _validate_owner_uniqueness(tasks: List[Dict[str, Any]]) -> None:
    seen: Dict[str, str] = {}
    for task in tasks:
        owner = task["owner"]
        task_id = task["id"]
        previous = seen.get(owner)
        if previous is not None:
            raise ParseError(
                f"owner collision: worker '{owner}' is assigned to both {previous} and {task_id}; "
                "cannot map both to a single worker YAML"
            )
        seen[owner] = task_id


def _yaml_quote(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def _emit_string_list(lines: List[str], indent: int, key: str, values: List[str]) -> None:
    prefix = " " * indent + f"{key}:"
    if not values:
        lines.append(prefix + " []")
        return

    lines.append(prefix)
    for value in values:
        lines.append(" " * (indent + 2) + f"- {_yaml_quote(value)}")


def _format_gate_suffix(task_id: str, index: int) -> str:
    match = re.search(r"(\d+)$", task_id)
    if match:
        return match.group(1).zfill(3)
    return f"{index + 1:03d}"


def _build_title(task: Dict[str, Any], req_map: Dict[str, Dict[str, Any]]) -> str:
    task_id = task["id"]
    explicit = str(task.get("title") or "").strip()
    if explicit:
        summary = explicit
    else:
        req_titles = [req_map[rid]["title"] for rid in task.get("requirement_ids", []) if rid in req_map]
        if req_titles:
            summary = req_titles[0]
        elif task.get("deliverables"):
            summary = task["deliverables"][0]
        else:
            summary = "implementation task"

    return f"{task_id}: {summary}"


def _build_description(
    objective: str,
    task: Dict[str, Any],
    req_map: Dict[str, Dict[str, Any]],
) -> str:
    lines: List[str] = []
    lines.append(f"tasks.yaml の {task['id']} を実装する。")
    lines.append("")
    lines.append("## Objective")
    lines.append(objective.strip() if objective.strip() else "(not provided)")
    lines.append("")
    lines.append("## Requirements")

    requirement_ids = task.get("requirement_ids", [])
    if requirement_ids:
        for req_id in requirement_ids:
            req = req_map.get(req_id)
            if req is None:
                lines.append(f"- {req_id}: (requirements に未定義)")
                continue

            lines.append(f"- {req_id}: {req['title']}")
            acceptance = req.get("acceptance", [])
            if acceptance:
                for ac in acceptance:
                    lines.append(f"  - AC: {ac}")
    else:
        lines.append("- (none)")

    lines.append("")
    lines.append("## Definition of Done")
    dod = task.get("definition_of_done", [])
    if dod:
        for item in dod:
            lines.append(f"- {item}")
    else:
        lines.append("- (none)")

    return "\n".join(lines)


def _build_prompt(queue_rel: str, worker_id: str) -> str:
    return "\n".join(
        [
            "あなたはこのYAMLに書かれているタスクを実行する。",
            "まずこのファイルを読み、taskの内容と制約を理解すること。",
            "",
            "ルール:",
            "- 共有ファイルは原則避ける。必要なら触ってよいが、必ずレポートで明記。",
            "- テストは原則実行しない（必要なら提案だけ）。",
            "- 指示されていない範囲のリファクタや整形はしない。",
            "- persona が指定されていれば、その専門家として作業する。",
            "- report YAML の更新は constraints の制約対象外。作業完了時に必ず更新すること。",
            "",
            "作業が終わったら、以下のレポート形式で",
            f"`{queue_rel}/reports/{worker_id}_report.yaml` を更新すること。",
            "summary は1行で簡潔に書くこと。",
            "persona を使った場合は report.persona に記載すること。",
        ]
    )


def _render_worker_yaml(
    parent_cmd_id: str,
    assigned_at: str,
    repo_root: str,
    queue_rel: str,
    task: Dict[str, Any],
    req_map: Dict[str, Dict[str, Any]],
    index: int,
    objective: str,
) -> str:
    worker_id = task["owner"]
    local_task_id = task["id"]
    expanded_task_id = f"{parent_cmd_id}_{local_task_id}"
    status = "assigned" if not task.get("depends_on") else "waiting"
    gate_suffix = _format_gate_suffix(local_task_id, index)
    gate_id = f"{parent_cmd_id}_gate_{gate_suffix}"
    deliverables = task.get("deliverables", [])

    title = _build_title(task, req_map)
    description = _build_description(objective, task, req_map)
    prompt = _build_prompt(queue_rel, worker_id)

    lines: List[str] = []
    lines.append("schema_version: 1")
    lines.append("task:")
    lines.append(f"  task_id: {_yaml_quote(expanded_task_id)}")
    lines.append(f"  parent_cmd_id: {_yaml_quote(parent_cmd_id)}")
    lines.append(f"  assigned_to: {_yaml_quote(worker_id)}")
    lines.append(f"  assigned_at: {_yaml_quote(assigned_at)}")
    lines.append(f"  status: {status}")
    lines.append("")
    lines.append(f"  title: {_yaml_quote(title)}")
    lines.append("  description: |")
    for text_line in description.splitlines():
        lines.append(f"    {text_line}")
    lines.append("")
    lines.append(f"  repo_root: {_yaml_quote(repo_root)}")
    lines.append('  persona: "senior_software_engineer"')
    lines.append("  phase: implement")
    lines.append("  loop_count: 0")
    lines.append("")
    lines.append("  quality_gate:")
    lines.append("    enabled_snapshot: true")
    lines.append(f"    gate_id: {_yaml_quote(gate_id)}")
    lines.append(f"    implementer_worker_id: {_yaml_quote(worker_id)}")
    lines.append("    reviewer_worker_id: null")
    lines.append("    source_task_id: null")
    lines.append("    max_loop_count: 3")
    lines.append('    checklist_template: ".yamibaito/templates/review-checklist.yaml"')
    lines.append("    review_checklist: []")
    lines.append("")
    lines.append("  constraints:")
    _emit_string_list(lines, 4, "allowed_paths", deliverables)
    lines.append("    forbidden_paths: []")
    _emit_string_list(lines, 4, "deliverables", deliverables)
    lines.append("    shared_files_policy: warn")
    lines.append("    tests_policy: none")
    lines.append("")
    lines.append("  codex:")
    lines.append("    mode: exec_stdin")
    lines.append("    sandbox: workspace-write")
    lines.append("    approval: on-request")
    lines.append("    model: high")
    lines.append("    web_search: false")
    lines.append("")
    lines.append("  prompt: |")
    for prompt_line in prompt.splitlines():
        lines.append(f"    {prompt_line}")

    return "\n".join(lines) + "\n"


def parse_cli(argv: List[str]) -> Dict[str, Any]:
    args: Dict[str, Any] = {
        "tasks_file": None,
        "queue_dir": None,
        "repo_root": ".",
        "session": "",
        "cmd_id": None,
        "dry_run": False,
    }

    idx = 0
    while idx < len(argv):
        token = argv[idx]
        if token in {"--tasks-file", "--queue-dir", "--repo-root", "--session", "--cmd-id"}:
            if idx + 1 >= len(argv):
                raise ParseError(f"Missing value for {token}")
            value = argv[idx + 1]
            if token == "--tasks-file":
                args["tasks_file"] = value
            elif token == "--queue-dir":
                args["queue_dir"] = value
            elif token == "--repo-root":
                args["repo_root"] = value
            elif token == "--session":
                args["session"] = value
            elif token == "--cmd-id":
                args["cmd_id"] = value
            idx += 2
            continue

        if token == "--dry-run":
            args["dry_run"] = True
            idx += 1
            continue

        raise ParseError(f"Unknown arg: {token}")

    if not args["tasks_file"]:
        raise ParseError("Missing --tasks-file")
    if not args["queue_dir"]:
        raise ParseError("Missing --queue-dir")

    return args


def run(argv: List[str]) -> int:
    cli = parse_cli(argv)
    tasks_file = Path(cli["tasks_file"])
    queue_dir = Path(cli["queue_dir"])
    repo_root = cli["repo_root"]
    repo_root_path = Path(repo_root)
    session = re.sub(r"[^A-Za-z0-9_-]", "_", cli["session"] or "")

    parsed = parse_tasks_yaml(tasks_file)
    _validate_structure(parsed, repo_root_path)

    tasks = parsed["tasks"]
    requirements = parsed["requirements"]
    _validate_race_001(tasks)
    _validate_owner_uniqueness(tasks)

    parent_cmd_id = (cli["cmd_id"] or str(parsed.get("epic", "")).strip())
    if not parent_cmd_id:
        raise ParseError("Unable to determine parent_cmd_id: provide --cmd-id or set epic in tasks.yaml")

    assigned_at = dt.datetime.now().replace(microsecond=0).isoformat()
    objective = str(parsed.get("objective", ""))
    queue_rel = f".yamibaito/queue_{session}" if session else ".yamibaito/queue"

    req_map: Dict[str, Dict[str, Any]] = {}
    for req in requirements:
        req_map[req["id"]] = req

    rendered: List[Tuple[str, Path, str]] = []
    for idx, task in enumerate(tasks):
        worker_id = task["owner"]
        output_path = _validate_output_path(queue_dir, task["id"], worker_id)
        content = _render_worker_yaml(
            parent_cmd_id=parent_cmd_id,
            assigned_at=assigned_at,
            repo_root=repo_root,
            queue_rel=queue_rel,
            task=task,
            req_map=req_map,
            index=idx,
            objective=objective,
        )
        rendered.append((worker_id, output_path, content))

    if cli["dry_run"]:
        for idx, (_, _, content) in enumerate(rendered):
            if idx > 0:
                print("---")
            sys.stdout.write(content)
        return 0

    tasks_dir = queue_dir / "tasks"
    tasks_dir.mkdir(parents=True, exist_ok=True)
    for _, output_path, content in rendered:
        output_path.write_text(content, encoding="utf-8")

    return 0


def main() -> None:
    try:
        code = run(sys.argv[1:])
    except ParseError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
    except OSError as exc:
        print(str(exc), file=sys.stderr)
        raise SystemExit(1)
    raise SystemExit(code)


if __name__ == "__main__":
    main()
