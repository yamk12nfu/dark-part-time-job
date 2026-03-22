#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo_root="."
session_id=""
planner_mode=0
architect_done_mode=0
cmd_id=""
dry_run=0
role=""
task_id=""
mode_only_arg=""
cmd_id_value_missing=0
role_value_missing=0
task_id_value_missing=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo_root="$2"
      shift 2
      ;;
    --session)
      session_id="$2"
      shift 2
      ;;
    --planner)
      planner_mode=1
      shift
      ;;
    --architect-done)
      architect_done_mode=1
      shift
      ;;
    --cmd-id)
      if [ -z "$mode_only_arg" ]; then
        mode_only_arg="--cmd-id"
      fi
      if [ $# -lt 2 ]; then
        cmd_id_value_missing=1
        shift
      else
        cmd_id="$2"
        shift 2
      fi
      ;;
    --dry-run)
      dry_run=1
      if [ -z "$mode_only_arg" ]; then
        mode_only_arg="--dry-run"
      fi
      shift
      ;;
    --role)
      if [ $# -lt 2 ]; then
        role_value_missing=1
        shift
      else
        role="$2"
        shift 2
      fi
      ;;
    --task-id)
      if [ $# -lt 2 ]; then
        task_id_value_missing=1
        shift
      else
        task_id="$2"
        shift 2
      fi
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ "$planner_mode" -eq 1 ] && [ "$architect_done_mode" -eq 1 ]; then
  echo "--planner and --architect-done are mutually exclusive" >&2
  exit 1
fi

if [ "$planner_mode" -ne 1 ] && [ "$architect_done_mode" -ne 1 ] && [ -n "$mode_only_arg" ]; then
  echo "Unknown arg: $mode_only_arg" >&2
  exit 1
fi

if [ "$planner_mode" -eq 0 ] && [ "$architect_done_mode" -eq 1 ] && [ "$dry_run" -eq 1 ]; then
  echo "Unknown arg: --dry-run" >&2
  exit 1
fi

if { [ "$planner_mode" -eq 1 ] || [ "$architect_done_mode" -eq 1 ]; } && [ "$cmd_id_value_missing" -eq 1 ]; then
  echo "Missing value for --cmd-id" >&2
  exit 1
fi

if [ "$role_value_missing" -eq 1 ]; then
  echo "Missing value for --role" >&2
  exit 1
fi

if [ "$task_id_value_missing" -eq 1 ]; then
  echo "Missing value for --task-id" >&2
  exit 1
fi

if [ "$planner_mode" -eq 1 ] && [ -n "$role" ]; then
  echo "Unknown arg: --role" >&2
  exit 1
fi

if [ "$planner_mode" -eq 1 ] && [ -n "$task_id" ]; then
  echo "Unknown arg: --task-id" >&2
  exit 1
fi

if [ -n "$role" ] && [ "$role" != "reviewer" ] && [ "$role" != "quality-gate" ]; then
  echo "Invalid --role: $role (expected reviewer|quality-gate)" >&2
  exit 1
fi

if [ -n "$role" ] && [ -z "$task_id" ]; then
  echo "Missing --task-id" >&2
  exit 1
fi

if [ -z "$role" ] && [ -n "$task_id" ]; then
  echo "--task-id requires --role" >&2
  exit 1
fi

repo_root="$(cd "$repo_root" && pwd)"
session_id="$(echo "$session_id" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_suffix=""
if [ -n "$session_id" ]; then
  session_suffix="_${session_id}"
fi
panes_file="$repo_root/.yamibaito/panes${session_suffix}.json"
dispatch_mode="default"
smoke_test_mode="${YB_DISPATCH_SMOKE_TEST:-0}"

if [ "$planner_mode" -eq 1 ]; then
  dispatch_mode="planner"
  if [ -z "$cmd_id" ]; then
    echo "Missing --cmd-id" >&2
    exit 1
  fi

  work_dir="$repo_root"
  if [ -f "$panes_file" ]; then
    resolved_work_dir="$(_PANES_FILE="$panes_file" _REPO_ROOT="$repo_root" python3 - <<'PY'
import json
import os

panes_file = os.environ["_PANES_FILE"]
repo_root = os.environ["_REPO_ROOT"]

try:
    with open(panes_file, "r", encoding="utf-8") as f:
        panes = json.load(f)
    if isinstance(panes, dict):
        candidate = panes.get("work_dir", "")
        if isinstance(candidate, str) and candidate and os.path.isdir(candidate):
            print(candidate)
            raise SystemExit(0)
except Exception:
    pass

print(repo_root)
PY
)"
    work_dir="$resolved_work_dir"
  fi

  queue_dir="$work_dir/.yamibaito/queue${session_suffix}"
  if [ ! -d "$queue_dir" ]; then
    queue_dir="$repo_root/.yamibaito/queue${session_suffix}"
  fi

  planner_cmd=(
    "$ORCH_ROOT/scripts/yb_planner.sh"
    --repo "$repo_root"
    --session "$session_id"
    --cmd-id "$cmd_id"
  )
  if [ "$dry_run" -eq 1 ]; then
    planner_cmd+=(--dry-run)
  fi
  if ! "${planner_cmd[@]}"; then
    exit 1
  fi

  task_expand_cmd=(
    python3 "$ORCH_ROOT/scripts/yb_task_expand.py"
    --tasks-file "$queue_dir/plan/$cmd_id/tasks.yaml"
    --queue-dir "$queue_dir"
    --repo-root "$repo_root"
    --session "$session_id"
    --cmd-id "$cmd_id"
  )
  if [ "$dry_run" -eq 1 ]; then
    task_expand_cmd+=(--dry-run)
  fi
  if ! "${task_expand_cmd[@]}"; then
    exit 1
  fi

  if [ "$dry_run" -eq 1 ]; then
    exit 0
  fi
fi

if [ "$architect_done_mode" -eq 1 ]; then
  dispatch_mode="architect_done"
  if [ -z "$cmd_id" ]; then
    echo "Missing --cmd-id" >&2
    exit 1
  fi
fi

if [ "$smoke_test_mode" != "1" ] && [ ! -f "$panes_file" ]; then
  echo "Missing panes map (run yb start): $panes_file" >&2
  exit 1
fi

REPO_ROOT="$repo_root" PANES_FILE="$panes_file" ORCH_ROOT="$ORCH_ROOT" SESSION_ID="$session_id" DISPATCH_MODE="$dispatch_mode" CMD_ID="$cmd_id" SMOKE_TEST_MODE="$smoke_test_mode" DISPATCH_ROLE="$role" DISPATCH_TASK_ID="$task_id" python3 - <<'PY'
import datetime
import glob
import json
import os
import shlex
import subprocess
import sys


def fail(message, code=1):
    print(message, file=sys.stderr)
    sys.exit(code)


def leading_spaces(line):
    return len(line) - len(line.lstrip(" "))


def strip_inline_comment(value):
    in_single = False
    in_double = False
    escaped = False
    result = []
    for ch in value:
        if ch == "\\" and in_double and not escaped:
            escaped = True
            result.append(ch)
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single and not escaped:
            in_double = not in_double
        elif ch == "#" and not in_single and not in_double:
            break
        escaped = False
        result.append(ch)
    return "".join(result).rstrip()


def parse_scalar(raw_value):
    stripped = strip_inline_comment(raw_value).strip()
    if not stripped:
        return ""
    if len(stripped) >= 2 and stripped[0] == stripped[-1] and stripped[0] in {'"', "'"}:
        stripped = stripped[1:-1]
    lowered = stripped.lower()
    if lowered == "true":
        return True
    if lowered == "false":
        return False
    if lowered in ("null", "~"):
        return None
    return stripped


def parse_yaml_mapping(content):
    data = {}
    stack = [(-1, data)]

    for raw_line in content.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        indent = leading_spaces(raw_line)
        line = raw_line[indent:]
        if line.startswith("- ") or ":" not in line:
            continue

        key_part, raw_value = line.split(":", 1)
        key = key_part.strip()
        if not key:
            continue

        while len(stack) > 1 and indent <= stack[-1][0]:
            stack.pop()
        parent = stack[-1][1]

        value = strip_inline_comment(raw_value).strip()
        if value == "":
            child = {}
            parent[key] = child
            stack.append((indent, child))
            continue
        if value.startswith("|") or value.startswith(">"):
            parent[key] = ""
            continue
        parent[key] = parse_scalar(raw_value)

    return data


def to_text(value):
    if value is None:
        return ""
    text = str(value).strip()
    if text.lower() in ("null", "~"):
        return ""
    return text


def to_int(value, default=0):
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return default


def to_bool(value, default=False):
    if isinstance(value, bool):
        return value
    text = str(value).strip().lower()
    if text == "true":
        return True
    if text == "false":
        return False
    return default


def read_text(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def write_text(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def extract_literal_block(content, key, key_indent):
    lines = content.splitlines()
    prefix = " " * key_indent + f"{key}:"
    for idx, line in enumerate(lines):
        if not line.startswith(prefix):
            continue
        suffix = line[len(prefix) :].strip()
        if not suffix.startswith("|"):
            continue
        block = []
        for next_line in lines[idx + 1 :]:
            if next_line.strip() == "":
                block.append("")
                continue
            indent = leading_spaces(next_line)
            if indent <= key_indent:
                break
            trim = key_indent + 2
            block.append(next_line[trim:] if len(next_line) >= trim else "")
        return "\n".join(block).rstrip()
    return ""


def extract_list_values(content, key, key_indent):
    lines = content.splitlines()
    prefix = " " * key_indent + f"{key}:"
    for idx, line in enumerate(lines):
        if not line.startswith(prefix):
            continue
        suffix = line[len(prefix) :].strip()
        if suffix.startswith("[") and suffix.endswith("]"):
            inner = suffix[1:-1].strip()
            if not inner:
                return []
            values = []
            for part in inner.split(","):
                item = to_text(parse_scalar(part))
                if item:
                    values.append(item)
            return values

        values = []
        for next_line in lines[idx + 1 :]:
            if next_line.strip() == "":
                continue
            indent = leading_spaces(next_line)
            if indent <= key_indent:
                break
            stripped = next_line.strip()
            if not stripped.startswith("- "):
                continue
            item = to_text(parse_scalar(stripped[2:]))
            if item:
                values.append(item)
        return values
    return []


def extract_section_block(content, key, key_indent):
    lines = content.splitlines()
    prefix = " " * key_indent + f"{key}:"
    for idx, line in enumerate(lines):
        if not line.startswith(prefix):
            continue
        section_lines = [line]
        for next_line in lines[idx + 1 :]:
            if next_line.strip() == "":
                section_lines.append(next_line)
                continue
            indent = leading_spaces(next_line)
            if indent <= key_indent:
                break
            section_lines.append(next_line)
        return "\n".join(section_lines).strip()
    return ""


def yaml_quote(value):
    text = to_text(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{text}"'


def yaml_scalar(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, int):
        return str(value)
    return yaml_quote(value)


def emit_yaml_list(lines, indent, key, values):
    prefix = " " * indent
    if values:
        lines.append(f"{prefix}{key}:")
        for item in values:
            lines.append(f"{prefix}  - {yaml_quote(item)}")
    else:
        lines.append(f"{prefix}{key}: []")


def emit_yaml_block(lines, indent, key, text):
    prefix = " " * indent
    lines.append(f"{prefix}{key}: |")
    if text:
        for row in text.splitlines():
            lines.append(f"{prefix}  {row}")
    else:
        lines.append(f"{prefix}  ")


def truncate_text(text, max_lines=120, max_chars=8000):
    rows = text.splitlines()
    clipped = False
    if len(rows) > max_lines:
        rows = rows[:max_lines]
        clipped = True
    result = "\n".join(rows)
    if len(result) > max_chars:
        result = result[:max_chars]
        clipped = True
    if clipped:
        result += "\n... (truncated)"
    return result


def run_git_capture(args):
    try:
        proc = subprocess.run(["git", "-C", work_dir] + args, capture_output=True, text=True, check=False)
    except OSError as exc:
        return f"(failed to run git {' '.join(args)}: {exc})"
    output = proc.stdout.strip()
    error_text = proc.stderr.strip()
    if proc.returncode != 0 and not output:
        return f"(git {' '.join(args)} failed: {error_text or f'rc={proc.returncode}'})"
    return output or "(no changes)"


def send_two_step(session_name, pane_id, command):
    target = f"{session_name}:{pane_id}"
    for step, payload in (("command", command), ("enter", "Enter")):
        proc = subprocess.run(
            ["tmux", "send-keys", "-t", target, payload],
            capture_output=True,
            text=True,
            check=False,
        )
        if proc.returncode != 0:
            detail = to_text(proc.stderr) or to_text(proc.stdout) or f"rc={proc.returncode}"
            fail(
                f"tmux send-keys failed: target={target} step={step} rc={proc.returncode} detail={detail}",
                code=1,
            )


def build_worker_command(worker_id):
    cmd = f'cd "{work_dir}" && "{orch_root}/scripts/yb_run_worker.sh" --repo "{repo_root}" --worker "{worker_id}"'
    if session_id:
        cmd += f' --session "{session_id}"'
    return cmd


def get_role_entry(v2_roles, role_key):
    if not isinstance(v2_roles, dict):
        return {}
    candidates = [role_key, role_key.replace("-", "_"), role_key.replace("_", "-")]
    for candidate in candidates:
        entry = v2_roles.get(candidate)
        if isinstance(entry, dict):
            return entry
    return {}


def resolve_role_pane(role_key, fallback_worker_id):
    pane = ""
    entry = get_role_entry(panes_data.get("v2_roles"), role_key)
    if entry:
        pane = to_text(entry.get("pane"))
    if not pane:
        entry = get_role_entry(config_data.get("v2_roles"), role_key)
        if entry:
            pane = to_text(entry.get("pane"))
    if pane:
        return pane
    if fallback_worker_id:
        return to_text(workers.get(fallback_worker_id))
    return ""


def read_task_record(task_path):
    content = read_text(task_path)
    parsed = parse_yaml_mapping(content)
    task_node = parsed.get("task")
    if not isinstance(task_node, dict):
        task_node = {}
    return {"path": task_path, "content": content, "task": task_node}


def find_task_record_by_id(tasks_dir, target_task_id):
    fallback = None
    for task_path in sorted(glob.glob(os.path.join(tasks_dir, "*.yaml"))):
        try:
            record = read_task_record(task_path)
        except OSError:
            continue
        if to_text(record["task"].get("task_id")) == target_task_id:
            phase = to_text(record["task"].get("phase")).lower()
            if phase == "implement":
                return record
            if fallback is None:
                fallback = record
    return fallback


def normalize_string_list(raw_values):
    if not isinstance(raw_values, list):
        return []
    values = []
    for raw in raw_values:
        text = to_text(raw)
        if text:
            values.append(text)
    return values


def parse_inline_yaml_list(raw_value):
    stripped = strip_inline_comment(raw_value).strip()
    if not (stripped.startswith("[") and stripped.endswith("]")):
        return None
    inner = stripped[1:-1].strip()
    if not inner:
        return []
    values = []
    for part in inner.split(","):
        item = to_text(parse_scalar(part))
        if item:
            values.append(item)
    return values


def resolve_worker_id_by_pane(pane_id):
    target = to_text(pane_id)
    if not target:
        return ""
    for worker_id, pane in workers.items():
        if to_text(pane) == target:
            return worker_id
    return ""


def derive_parent_cmd_id_from_task_id(task_id):
    marker = "_task_"
    idx = task_id.find(marker)
    if idx <= 0:
        return ""
    return task_id[:idx]


def read_report_record(report_path):
    content = read_text(report_path)
    parsed = parse_yaml_mapping(content)
    report_node = parsed.get("report")
    if not isinstance(report_node, dict):
        report_node = {}
    worker_id = to_text(report_node.get("worker_id"))
    if not worker_id:
        basename = os.path.basename(report_path)
        worker_id = basename.replace("_report.yaml", "")
    return {
        "path": report_path,
        "content": content,
        "report": report_node,
        "worker_id": worker_id,
        "task_id": to_text(report_node.get("task_id")),
        "review_target_task_id": to_text(report_node.get("review_target_task_id")),
        "parent_cmd_id": to_text(report_node.get("parent_cmd_id")),
        "phase": to_text(report_node.get("phase")),
    }


def collect_report_hints_for_task(reports_dir, source_task_id):
    hints = {
        "reports_dir": reports_dir,
        "implement_report": None,
        "review_reports": [],
        "implementer_worker_id": "",
        "reviewer_worker_id": "",
        "parent_cmd_id": "",
        "persona": "",
        "loop_count": 0,
        "gate_id": "",
        "enabled_snapshot": None,
        "deliverables": [],
    }
    if not os.path.isdir(reports_dir):
        return hints

    for report_path in sorted(glob.glob(os.path.join(reports_dir, "*_report.yaml"))):
        if not os.path.isfile(report_path):
            continue
        try:
            record = read_report_record(report_path)
        except OSError:
            continue

        if record["task_id"] == source_task_id:
            if hints["implement_report"] is None:
                hints["implement_report"] = record
            else:
                current_phase = to_text(hints["implement_report"]["phase"]).lower()
                phase = to_text(record["phase"]).lower()
                if current_phase == "review" and phase != "review":
                    hints["implement_report"] = record

        if record["review_target_task_id"] == source_task_id:
            hints["review_reports"].append(record)

    implement_report = hints["implement_report"]
    if implement_report is not None:
        report_data = implement_report["report"]
        hints["implementer_worker_id"] = to_text(implement_report.get("worker_id"))
        hints["parent_cmd_id"] = to_text(report_data.get("parent_cmd_id"))
        hints["persona"] = to_text(report_data.get("persona"))
        hints["loop_count"] = to_int(report_data.get("loop_count"), 0)
        hints["gate_id"] = to_text(report_data.get("gate_id"))
        enabled_snapshot = report_data.get("enabled_snapshot")
        if enabled_snapshot is not None:
            hints["enabled_snapshot"] = to_bool(enabled_snapshot, True)
        hints["deliverables"] = extract_list_values(implement_report["content"], "files_changed", 2)

    if hints["review_reports"]:
        hints["reviewer_worker_id"] = to_text(hints["review_reports"][0].get("worker_id"))
        if not hints["parent_cmd_id"]:
            hints["parent_cmd_id"] = to_text(hints["review_reports"][0].get("parent_cmd_id"))
        if not hints["gate_id"]:
            hints["gate_id"] = to_text(hints["review_reports"][0]["report"].get("gate_id"))

    if not hints["parent_cmd_id"]:
        hints["parent_cmd_id"] = derive_parent_cmd_id_from_task_id(source_task_id)

    return hints


def parse_plan_task_entries(plan_content):
    entries = []
    in_tasks = False
    current = None
    current_list_key = ""

    for raw_line in plan_content.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue

        indent = leading_spaces(raw_line)
        if indent == 0 and stripped == "tasks:":
            in_tasks = True
            current = None
            current_list_key = ""
            continue
        if not in_tasks:
            continue
        if indent == 0 and stripped != "tasks:":
            break

        if indent == 2 and stripped.startswith("- "):
            if current is not None:
                entries.append(current)
            current = {}
            current_list_key = ""
            remainder = stripped[2:]
            if ":" in remainder:
                key, raw_value = remainder.split(":", 1)
                key = key.strip()
                inline_values = parse_inline_yaml_list(raw_value)
                if inline_values is not None:
                    current[key] = inline_values
                else:
                    value = strip_inline_comment(raw_value).strip()
                    if value == "":
                        current[key] = []
                        current_list_key = key
                    else:
                        current[key] = parse_scalar(raw_value)
            continue

        if current is None:
            continue

        if indent >= 4 and stripped.startswith("- "):
            item = to_text(parse_scalar(stripped[2:]))
            if item and current_list_key:
                existing = current.get(current_list_key)
                if not isinstance(existing, list):
                    existing = []
                existing.append(item)
                current[current_list_key] = existing
            continue

        if indent >= 4 and ":" in stripped and not stripped.startswith("- "):
            key, raw_value = stripped.split(":", 1)
            key = key.strip()
            inline_values = parse_inline_yaml_list(raw_value)
            if inline_values is not None:
                current[key] = inline_values
                current_list_key = ""
                continue
            value = strip_inline_comment(raw_value).strip()
            if value == "":
                current[key] = []
                current_list_key = key
            else:
                current[key] = parse_scalar(raw_value)
                current_list_key = ""

    if current is not None:
        entries.append(current)

    return entries


def build_source_task_from_plan(source_task_id, plan_entry, parent_cmd_id, report_hints):
    quality_gate_cfg = config_data.get("quality_gate")
    if not isinstance(quality_gate_cfg, dict):
        quality_gate_cfg = {}
    codex_cfg = config_data.get("codex")
    if not isinstance(codex_cfg, dict):
        codex_cfg = {}

    local_id = to_text(plan_entry.get("id"))
    implementer_worker_id = to_text(plan_entry.get("owner")) or to_text(report_hints.get("implementer_worker_id"))
    reviewer_worker_id = to_text(report_hints.get("reviewer_worker_id"))
    deliverables = normalize_string_list(plan_entry.get("deliverables"))
    definition_of_done = normalize_string_list(plan_entry.get("definition_of_done"))
    requirement_ids = normalize_string_list(plan_entry.get("requirement_ids"))

    description_lines = [
        "## Reconstructed Source Task (plan fallback)",
        f"- source_task_id: {source_task_id}",
        f"- plan_task_id: {local_id or '(unknown)'}",
    ]
    if requirement_ids:
        description_lines.append("")
        description_lines.append("### requirement_ids")
        for req_id in requirement_ids:
            description_lines.append(f"- {req_id}")
    if deliverables:
        description_lines.append("")
        description_lines.append("### deliverables")
        for path in deliverables:
            description_lines.append(f"- {path}")
    if definition_of_done:
        description_lines.append("")
        description_lines.append("### definition_of_done")
        for item in definition_of_done:
            description_lines.append(f"- {item}")

    enabled_snapshot = report_hints.get("enabled_snapshot")
    if enabled_snapshot is None:
        enabled_snapshot = True

    source_task = {
        "task_id": source_task_id,
        "parent_cmd_id": parent_cmd_id,
        "assigned_to": implementer_worker_id,
        "title": f"{source_task_id} (plan fallback)",
        "description": "\n".join(description_lines),
        "repo_root": ".",
        "persona": to_text(report_hints.get("persona")) or "senior_software_engineer",
        "phase": "implement",
        "loop_count": to_int(report_hints.get("loop_count"), 0),
        "quality_gate": {
            "enabled_snapshot": bool(enabled_snapshot),
            "gate_id": to_text(report_hints.get("gate_id")) or source_task_id,
            "implementer_worker_id": implementer_worker_id,
            "reviewer_worker_id": reviewer_worker_id or None,
            "source_task_id": source_task_id,
            "max_loop_count": to_int(quality_gate_cfg.get("max_rework_loops"), 3),
            "checklist_template": to_text(quality_gate_cfg.get("checklist_template_path"))
            or ".yamibaito/templates/review-checklist.yaml",
            "review_checklist": [],
        },
        "constraints": {
            "allowed_paths": list(deliverables),
            "forbidden_paths": [],
            "deliverables": list(deliverables),
            "shared_files_policy": "warn",
            "tests_policy": "none",
        },
        "codex": {
            "mode": to_text(codex_cfg.get("mode")) or "exec_stdin",
            "sandbox": to_text(codex_cfg.get("sandbox")) or "workspace-write",
            "approval": to_text(codex_cfg.get("approval")) or "on-request",
            "model": to_text(codex_cfg.get("model")) or "high",
            "web_search": to_bool(codex_cfg.get("web_search"), False),
        },
    }
    return source_task


def find_source_record_from_plan(queue_dir, source_task_id, report_hints):
    plan_root = os.path.join(queue_dir, "plan")
    if not os.path.isdir(plan_root):
        return None

    candidate_cmd_ids = []
    hint_cmd_id = to_text(report_hints.get("parent_cmd_id"))
    if hint_cmd_id:
        candidate_cmd_ids.append(hint_cmd_id)
    derived_cmd_id = derive_parent_cmd_id_from_task_id(source_task_id)
    if derived_cmd_id and derived_cmd_id not in candidate_cmd_ids:
        candidate_cmd_ids.append(derived_cmd_id)

    candidate_paths = []
    for cmd_id in candidate_cmd_ids:
        candidate_paths.append(os.path.join(plan_root, cmd_id, "tasks.yaml"))
    candidate_paths.extend(sorted(glob.glob(os.path.join(plan_root, "*", "tasks.yaml"))))

    seen = set()
    for plan_path in candidate_paths:
        if plan_path in seen:
            continue
        seen.add(plan_path)
        if not os.path.isfile(plan_path):
            continue

        parent_cmd_id = os.path.basename(os.path.dirname(plan_path))
        try:
            plan_content = read_text(plan_path)
        except OSError:
            continue
        for entry in parse_plan_task_entries(plan_content):
            local_id = to_text(entry.get("id"))
            if not local_id:
                continue
            expanded_id = local_id
            if parent_cmd_id and not local_id.startswith(f"{parent_cmd_id}_"):
                expanded_id = f"{parent_cmd_id}_{local_id}"
            if source_task_id not in (local_id, expanded_id):
                continue
            source_task = build_source_task_from_plan(
                source_task_id=source_task_id,
                plan_entry=entry,
                parent_cmd_id=parent_cmd_id,
                report_hints=report_hints,
            )
            return {"path": plan_path, "content": plan_content, "task": source_task, "origin": "plan"}
    return None


def build_source_record_from_reports(source_task_id, report_hints):
    implement_report = report_hints.get("implement_report")
    review_reports = report_hints.get("review_reports")
    if implement_report is None and not review_reports:
        return None

    quality_gate_cfg = config_data.get("quality_gate")
    if not isinstance(quality_gate_cfg, dict):
        quality_gate_cfg = {}
    codex_cfg = config_data.get("codex")
    if not isinstance(codex_cfg, dict):
        codex_cfg = {}

    implementer_worker_id = to_text(report_hints.get("implementer_worker_id"))
    reviewer_worker_id = to_text(report_hints.get("reviewer_worker_id"))
    parent_cmd_id = to_text(report_hints.get("parent_cmd_id")) or derive_parent_cmd_id_from_task_id(source_task_id)
    deliverables = normalize_string_list(report_hints.get("deliverables"))

    source_path = ""
    if implement_report is not None:
        source_path = to_text(implement_report.get("path"))
    elif review_reports:
        source_path = to_text(review_reports[0].get("path"))

    summary = ""
    notes = ""
    if implement_report is not None:
        report_node = implement_report.get("report")
        if isinstance(report_node, dict):
            summary = to_text(report_node.get("summary"))
            notes = to_text(report_node.get("notes"))

    description_lines = [
        "## Reconstructed Source Task (report fallback)",
        f"- source_task_id: {source_task_id}",
        f"- source_report: {source_path or '(unknown)'}",
    ]
    if summary:
        description_lines.append("")
        description_lines.append("### implementer_summary")
        description_lines.append(summary)
    if notes:
        description_lines.append("")
        description_lines.append("### implementer_notes")
        description_lines.append(notes)
    if deliverables:
        description_lines.append("")
        description_lines.append("### deliverables (from report.files_changed)")
        for path in deliverables:
            description_lines.append(f"- {path}")

    enabled_snapshot = report_hints.get("enabled_snapshot")
    if enabled_snapshot is None:
        enabled_snapshot = True

    source_task = {
        "task_id": source_task_id,
        "parent_cmd_id": parent_cmd_id,
        "assigned_to": implementer_worker_id,
        "title": f"{source_task_id} (report fallback)",
        "description": "\n".join(description_lines),
        "repo_root": ".",
        "persona": to_text(report_hints.get("persona")) or "senior_software_engineer",
        "phase": "implement",
        "loop_count": to_int(report_hints.get("loop_count"), 0),
        "quality_gate": {
            "enabled_snapshot": bool(enabled_snapshot),
            "gate_id": to_text(report_hints.get("gate_id")) or source_task_id,
            "implementer_worker_id": implementer_worker_id or None,
            "reviewer_worker_id": reviewer_worker_id or None,
            "source_task_id": source_task_id,
            "max_loop_count": to_int(quality_gate_cfg.get("max_rework_loops"), 3),
            "checklist_template": to_text(quality_gate_cfg.get("checklist_template_path"))
            or ".yamibaito/templates/review-checklist.yaml",
            "review_checklist": [],
        },
        "constraints": {
            "allowed_paths": list(deliverables),
            "forbidden_paths": [],
            "deliverables": list(deliverables),
            "shared_files_policy": "warn",
            "tests_policy": "none",
        },
        "codex": {
            "mode": to_text(codex_cfg.get("mode")) or "exec_stdin",
            "sandbox": to_text(codex_cfg.get("sandbox")) or "workspace-write",
            "approval": to_text(codex_cfg.get("approval")) or "on-request",
            "model": to_text(codex_cfg.get("model")) or "high",
            "web_search": to_bool(codex_cfg.get("web_search"), False),
        },
    }
    return {"path": source_path, "content": "", "task": source_task, "origin": "reports"}


def resolve_source_record(queue_dir, tasks_dir, source_task_id):
    reports_dir = os.path.join(queue_dir, "reports")
    report_hints = collect_report_hints_for_task(reports_dir, source_task_id)

    source_record = find_task_record_by_id(tasks_dir, source_task_id)
    if source_record is not None:
        source_record["origin"] = "tasks"
        source_record["report_hints"] = report_hints
        return source_record

    plan_record = find_source_record_from_plan(queue_dir, source_task_id, report_hints)
    if plan_record is not None:
        plan_record["report_hints"] = report_hints
        return plan_record

    report_record = build_source_record_from_reports(source_task_id, report_hints)
    if report_record is not None:
        report_record["report_hints"] = report_hints
        return report_record

    return None


def resolve_checklist_path(source_qg):
    checklist_rel = to_text(source_qg.get("checklist_template")) or ".yamibaito/templates/review-checklist.yaml"
    candidates = [
        os.path.join(repo_root, checklist_rel),
        os.path.join(work_dir, checklist_rel),
        os.path.join(repo_root, ".yamibaito", "templates", "review-checklist.yaml"),
        os.path.join(repo_root, "templates", "review-checklist.yaml"),
    ]
    seen = set()
    for candidate in candidates:
        if candidate in seen:
            continue
        seen.add(candidate)
        if os.path.isfile(candidate):
            return candidate
    return candidates[-1]


REVIEW_CHECKLIST_ITEM_IDS = [
    "security_alignment",
    "error_retry_timeout",
    "observability",
    "test_strategy",
    "acceptance_criteria_fit",
    "requirement_coverage",
]


def build_role_prompt(role_name, report_path):
    role_header = "reviewer" if role_name == "reviewer" else "quality-gate"
    checklist_items = ", ".join(REVIEW_CHECKLIST_ITEM_IDS)
    lines = [
        f"あなたは {role_header} としてこのYAMLのタスクを実行する。",
        "まず task.description の入力データを読み、レビュー契約に沿って判断結果を構造化して返すこと。",
        "",
        "ルール:",
        "- 指示されていない範囲の実装変更はしない。",
        "- review_result は必ず \"approve\" または \"rework\" を設定すること。",
        f"- review_checklist は 6観点（{checklist_items}）の各 item_id に result (ok/ng) と comment を記載すること。",
        "- review_result が \"rework\" の場合は rework_instructions に具体的な修正指示を記載すること。",
        "- report YAML の更新は constraints の制約対象外。作業完了時に必ず更新すること。",
        "",
        "作業が終わったら以下の report YAML を更新すること:",
        f"- {report_path}",
        "summary は1行で簡潔に書くこと。",
    ]
    return "\n".join(lines)


def render_role_task_yaml(
    source_task,
    source_content,
    role_name,
    target_worker_id,
    source_task_id,
    description_text,
    persona,
    implementer_worker_id,
    reviewer_worker_id,
):
    source_qg = source_task.get("quality_gate")
    if not isinstance(source_qg, dict):
        source_qg = {}
    source_constraints = source_task.get("constraints")
    if not isinstance(source_constraints, dict):
        source_constraints = {}
    source_codex = source_task.get("codex")
    if not isinstance(source_codex, dict):
        source_codex = {}

    now_iso = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()
    title_prefix = "[Reviewer]" if role_name == "reviewer" else "[Quality Gate]"
    source_title = to_text(source_task.get("title")) or source_task_id

    allowed_paths = extract_list_values(source_content, "allowed_paths", 4)
    if not allowed_paths:
        allowed_paths = normalize_string_list(source_constraints.get("allowed_paths"))
    forbidden_paths = extract_list_values(source_content, "forbidden_paths", 4)
    if not forbidden_paths:
        forbidden_paths = normalize_string_list(source_constraints.get("forbidden_paths"))
    deliverables = extract_list_values(source_content, "deliverables", 4)
    if not deliverables:
        deliverables = normalize_string_list(source_constraints.get("deliverables"))

    loop_count = to_int(source_task.get("loop_count"), 0)
    max_loop_count = to_int(source_qg.get("max_loop_count"), 3)

    report_path = os.path.join(queue_dir, "reports", f"{target_worker_id}_report.yaml")
    prompt_text = build_role_prompt(role_name, report_path)

    lines = []
    lines.append("schema_version: 1")
    lines.append("task:")
    lines.append(f"  task_id: {yaml_quote(source_task_id)}")
    lines.append(f"  parent_cmd_id: {yaml_quote(to_text(source_task.get('parent_cmd_id')))}")
    lines.append(f"  assigned_to: {yaml_quote(target_worker_id)}")
    lines.append(f"  assigned_at: {yaml_quote(now_iso)}")
    lines.append("  status: assigned")
    lines.append("")
    lines.append(f"  title: {yaml_quote(f'{title_prefix} {source_title}')}")
    emit_yaml_block(lines, 2, "description", description_text)
    lines.append("")
    lines.append(f"  repo_root: {yaml_quote(to_text(source_task.get('repo_root')) or '.')}")
    lines.append(f"  persona: {yaml_quote(persona)}")
    lines.append("  phase: review")
    lines.append(f"  loop_count: {loop_count}")
    lines.append("")
    lines.append("  quality_gate:")
    lines.append(f"    enabled_snapshot: {yaml_scalar(to_bool(source_qg.get('enabled_snapshot'), True))}")
    lines.append(f"    gate_id: {yaml_scalar(to_text(source_qg.get('gate_id')) or None)}")
    lines.append(f"    implementer_worker_id: {yaml_scalar(implementer_worker_id or None)}")
    lines.append(f"    reviewer_worker_id: {yaml_scalar(reviewer_worker_id or None)}")
    lines.append(f"    source_task_id: {yaml_quote(source_task_id)}")
    lines.append(f"    max_loop_count: {max_loop_count}")
    lines.append(
        f"    checklist_template: {yaml_quote(to_text(source_qg.get('checklist_template')) or '.yamibaito/templates/review-checklist.yaml')}"
    )
    lines.append("    review_checklist: []")
    lines.append("")
    lines.append("  constraints:")
    emit_yaml_list(lines, 4, "allowed_paths", allowed_paths)
    emit_yaml_list(lines, 4, "forbidden_paths", forbidden_paths)
    emit_yaml_list(lines, 4, "deliverables", deliverables)
    lines.append(
        f"    shared_files_policy: {yaml_quote(to_text(source_constraints.get('shared_files_policy')) or 'warn')}"
    )
    lines.append(f"    tests_policy: {yaml_quote(to_text(source_constraints.get('tests_policy')) or 'none')}")
    lines.append("")
    lines.append("  codex:")
    lines.append(f"    mode: {yaml_quote(to_text(source_codex.get('mode')) or 'exec_stdin')}")
    lines.append(f"    sandbox: {yaml_quote(to_text(source_codex.get('sandbox')) or 'workspace-write')}")
    lines.append(f"    approval: {yaml_quote(to_text(source_codex.get('approval')) or 'on-request')}")
    lines.append(f"    model: {yaml_quote(to_text(source_codex.get('model')) or 'high')}")
    lines.append(f"    web_search: {'true' if to_bool(source_codex.get('web_search'), False) else 'false'}")
    lines.append("")
    emit_yaml_block(lines, 2, "prompt", prompt_text)
    lines.append("")
    return "\n".join(lines)


def resolve_source_description(source_content, source_task):
    description = extract_literal_block(source_content, "description", 2)
    if description:
        return description
    return to_text(source_task.get("description")) or "(description not found)"


def resolve_reviewer_worker_id(source_task, source_qg, report_hints):
    reviewer_worker_id = to_text(source_qg.get("reviewer_worker_id"))
    if reviewer_worker_id:
        return reviewer_worker_id

    reviewer_worker_id = to_text(report_hints.get("reviewer_worker_id"))
    if reviewer_worker_id:
        return reviewer_worker_id

    reviewer_pane = resolve_role_pane("reviewer", "")
    if reviewer_pane:
        reviewer_worker_id = resolve_worker_id_by_pane(reviewer_pane)
        if reviewer_worker_id:
            return reviewer_worker_id

    implementer_worker_id = (
        to_text(source_qg.get("implementer_worker_id"))
        or to_text(source_task.get("assigned_to"))
        or to_text(report_hints.get("implementer_worker_id"))
    )

    quality_gate_cfg = config_data.get("quality_gate")
    if isinstance(quality_gate_cfg, dict):
        for key in ("reviewer_worker_id", "default_reviewer_worker_id", "reviewer_worker"):
            candidate = to_text(quality_gate_cfg.get(key))
            if candidate and candidate in workers:
                return candidate

    workers_cfg = config_data.get("workers")
    if isinstance(workers_cfg, dict):
        for key in ("reviewer_worker_id", "reviewer_worker", "reviewer"):
            candidate = to_text(workers_cfg.get(key))
            if candidate and candidate in workers:
                return candidate

    tasks_dir = os.path.join(queue_dir, "tasks")
    available = []
    idle = []
    for worker_id in workers.keys():
        candidate = to_text(worker_id)
        if not candidate:
            continue
        if implementer_worker_id and candidate == implementer_worker_id:
            continue
        available.append(candidate)
        if not os.path.isdir(tasks_dir):
            continue
        _, status = read_task_status(os.path.join(tasks_dir, f"{candidate}.yaml"))
        if status == "idle":
            idle.append(candidate)

    if idle:
        return idle[0]
    if available:
        return available[0]
    return ""


def read_task_status(task_path):
    if not os.path.exists(task_path):
        return None, None
    try:
        record = read_task_record(task_path)
    except OSError:
        return None, None
    task_node = record["task"]
    return to_text(task_node.get("task_id")), to_text(task_node.get("status"))


def resolve_quality_gate_worker(source_task):
    source_qg = source_task.get("quality_gate")
    if not isinstance(source_qg, dict):
        source_qg = {}
    for key in ("quality_gate_worker_id", "gate_worker_id", "dedicated_worker_id", "worker_id"):
        candidate = to_text(source_qg.get(key))
        if candidate:
            return candidate
    assigned_to = to_text(source_task.get("assigned_to"))
    implementer = to_text(source_qg.get("implementer_worker_id"))
    if assigned_to and assigned_to != implementer:
        return assigned_to
    return ""


def find_report_record_for_quality_gate(reports_dir, source_task_id, reviewer_worker_id):
    if not os.path.isdir(reports_dir):
        return None

    candidate_paths = []
    if reviewer_worker_id:
        candidate_paths.append(os.path.join(reports_dir, f"{reviewer_worker_id}_report.yaml"))
    candidate_paths.extend(sorted(glob.glob(os.path.join(reports_dir, "*_report.yaml"))))

    seen = set()
    for report_path in candidate_paths:
        if report_path in seen:
            continue
        seen.add(report_path)
        if not os.path.isfile(report_path):
            continue
        try:
            content = read_text(report_path)
        except OSError:
            continue
        parsed = parse_yaml_mapping(content)
        report = parsed.get("report")
        if not isinstance(report, dict):
            report = {}
        review_target = to_text(report.get("review_target_task_id"))
        review_result = to_text(report.get("review_result"))
        basename = os.path.basename(report_path)
        reviewer_filename = f"{reviewer_worker_id}_report.yaml" if reviewer_worker_id else ""
        if source_task_id and review_target != source_task_id:
            continue
        if not review_result:
            continue
        if reviewer_filename and basename == reviewer_filename:
            return {"path": report_path, "content": content, "report": report}
        if source_task_id and review_target == source_task_id:
            return {"path": report_path, "content": content, "report": report}
    return None


def parse_bool(raw_value):
    parsed = parse_scalar(raw_value)
    if isinstance(parsed, bool):
        return parsed
    return to_text(parsed).lower() == "true"


def parse_design_guidance(raw_value, present_when_empty=False):
    parsed = parse_scalar(raw_value)
    if isinstance(parsed, bool):
        return parsed
    text = to_text(parsed).lower()
    if not text:
        return present_when_empty
    return text not in {"null", "~", "pending", "false", "none"}


def parse_architect_metadata_from_description(description_lines):
    needs_architect = None
    design_guidance = None
    for raw_line in description_lines:
        line = raw_line.strip()
        if not line:
            continue
        if line == "--- ARCHITECT DESIGN GUIDANCE ---":
            design_guidance = True
            continue
        if line.startswith("- "):
            line = line[2:].strip()
        if ":" not in line:
            continue
        key, raw_value = line.split(":", 1)
        key = key.strip()
        raw_value = raw_value.strip()
        if key == "needs_architect":
            needs_architect = parse_bool(raw_value)
        elif key == "design_guidance":
            design_guidance = parse_design_guidance(raw_value, present_when_empty=True)
    return needs_architect, design_guidance


def read_worker_task_fields(task_path):
    if not os.path.exists(task_path):
        return None, None, False, False
    task_id = None
    status = None
    needs_architect = None
    design_guidance = None
    in_task = False
    in_description = False
    description_indent = 0
    description_lines = []
    with open(task_path, "r", encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            stripped = line.strip()
            indent = len(line) - len(line.lstrip(" "))

            if in_description:
                if not stripped:
                    description_lines.append("")
                    continue
                if indent >= description_indent:
                    description_lines.append(line[description_indent:])
                    continue
                in_description = False

            if not stripped or stripped.startswith("#"):
                continue

            if not in_task:
                if indent == 0 and stripped == "task:":
                    in_task = True
                continue

            if indent == 0 and stripped.endswith(":"):
                break
            if indent != 2:
                continue
            if ":" not in stripped:
                continue

            key, raw_value = stripped.split(":", 1)
            key = key.strip()
            raw_value = raw_value.strip()
            value = parse_scalar(raw_value)
            if key == "task_id" and not task_id:
                task_id = to_text(value)
            elif key == "status" and not status:
                status = to_text(value)
            elif key == "needs_architect":
                needs_architect = parse_bool(raw_value)
            elif key == "design_guidance":
                design_guidance = parse_design_guidance(raw_value, present_when_empty=(raw_value == ""))
            elif key == "description":
                is_multiline = raw_value.startswith("|") or raw_value.startswith(">") or value in {"|", ">"}
                if raw_value == "" or is_multiline:
                    in_description = True
                    description_indent = indent + 2

    desc_needs_architect, desc_design_guidance = parse_architect_metadata_from_description(description_lines)
    if needs_architect is None:
        needs_architect = desc_needs_architect
    if design_guidance is None:
        design_guidance = desc_design_guidance
    return task_id, status, bool(needs_architect), bool(design_guidance)


def apply_plan_field(task, key, raw_value):
    if key == "id":
        task["id"] = to_text(parse_scalar(raw_value))
    elif key == "owner":
        task["owner"] = to_text(parse_scalar(raw_value))
    elif key == "needs_architect":
        task["needs_architect"] = parse_bool(raw_value)


def read_plan_task_map(tasks_path):
    if not os.path.exists(tasks_path):
        raise FileNotFoundError(tasks_path)

    task_map = {}
    in_tasks = False
    current = None

    def flush_current():
        if not isinstance(current, dict):
            return
        owner = to_text(current.get("owner"))
        if owner:
            task_map[owner] = {
                "id": to_text(current.get("id")),
                "needs_architect": bool(current.get("needs_architect", False)),
            }

    with open(tasks_path, "r", encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            indent = len(line) - len(line.lstrip(" "))

            if not in_tasks:
                if indent == 0 and stripped.startswith("tasks:"):
                    in_tasks = True
                continue

            if indent == 0 and not stripped.startswith("- "):
                break

            if indent == 2 and stripped.startswith("- "):
                flush_current()
                current = {"id": "", "owner": "", "needs_architect": False}
                inline = stripped[2:].strip()
                if inline and ":" in inline:
                    key, raw_value = inline.split(":", 1)
                    apply_plan_field(current, key.strip(), raw_value.strip())
                continue

            if indent == 4 and isinstance(current, dict) and ":" in stripped:
                key, raw_value = stripped.split(":", 1)
                apply_plan_field(current, key.strip(), raw_value.strip())

    flush_current()
    return task_map


def resolve_worker_needs_architect(worker_id, worker_needs_architect, plan_task_map):
    plan_task = plan_task_map.get(worker_id)
    if isinstance(plan_task, dict):
        return bool(plan_task.get("needs_architect", False))
    return worker_needs_architect


def planner_route(has_architect_pane, needs_architect):
    if needs_architect and not has_architect_pane:
        return None
    if needs_architect:
        return "architect"
    return "implementer"


def should_dispatch_architect_done(needs_architect, design_guidance):
    return needs_architect and design_guidance


def should_abort_architect_launch(has_architect_pane, architect_targets, architect_agent):
    return has_architect_pane and bool(architect_targets) and not architect_agent


def send_to_pane(target, command):
    if ":" not in target:
        fail(f"Invalid tmux target: {target}")
    session_name, pane_id = target.split(":", 1)
    send_two_step(session_name, pane_id, command)


def dispatch_implementer(worker_id, pane):
    send_to_pane(f"{session}:{pane}", build_worker_command(worker_id))


def should_skip_default_dispatch(resolved_needs_architect, design_guidance):
    return resolved_needs_architect and not design_guidance


def dispatch_default_workers(
    active_worker_tasks,
    dispatch_implementer_fn=None,
    skip_reporter_fn=None,
):
    if dispatch_implementer_fn is None:
        dispatch_implementer_fn = dispatch_implementer

    for worker_id, pane, task_id, _, resolved_needs_architect, design_guidance in active_worker_tasks:
        if should_skip_default_dispatch(resolved_needs_architect, design_guidance):
            if skip_reporter_fn is None:
                print(
                    f"default: skip worker '{worker_id}' ({task_id}) because design_guidance is missing",
                    file=sys.stderr,
                )
            else:
                skip_reporter_fn(worker_id, task_id)
            continue
        dispatch_implementer_fn(worker_id, pane)


def resolve_architect_agent():
    sys.path.insert(0, os.path.join(orch_root, "scripts", "lib"))
    try:
        from agent_config import build_initial_message, build_launch_command, load_agent_config
    except Exception as exc:
        print(f"Failed to import agent_config for architect routing: {exc}", file=sys.stderr)
        return None

    config_path = os.path.join(repo_root, ".yamibaito", "config.yaml")
    try:
        agent_cfg = load_agent_config(config_path, "architect")
        launch_command = build_launch_command(agent_cfg)
    except Exception as exc:
        print(f"Failed to resolve architect command: {exc}", file=sys.stderr)
        return None

    if not launch_command:
        print("Failed to resolve architect command: empty command", file=sys.stderr)
        return None

    mode = str(agent_cfg.get("mode", "interactive")).strip().lower() or "interactive"
    initial_message = ""
    if mode == "interactive":
        prompt_path = os.path.join(repo_root, "prompts", "v2", "architect.md")
        try:
            initial_message = build_initial_message(
                agent_cfg,
                prompt_path=prompt_path,
                role="architect",
            )
        except Exception as exc:
            print(f"Failed to resolve architect initial message: {exc}", file=sys.stderr)
            return None

    return {
        "command": launch_command,
        "mode": mode,
        "initial_message": initial_message,
    }


def dispatch_architect(architect_agent, worker_id, task_id, task_path):
    target = f"{session}:{architect_pane}"
    env_bits = [
        f"YB_TARGET_WORKER={shlex.quote(worker_id)}",
        f"YB_TARGET_TASK={shlex.quote(task_id)}",
        f"YB_TARGET_TASK_FILE={shlex.quote(task_path)}",
    ]
    launch_cmd = shlex.join(architect_agent["command"])

    if architect_agent.get("mode") == "batch_stdin":
        cmd = (
            f"cd {shlex.quote(work_dir)} && cat {shlex.quote(task_path)} | "
            f"env {' '.join(env_bits)} {launch_cmd}"
        )
        send_to_pane(target, cmd)
        return

    cmd = f"cd {shlex.quote(work_dir)} && {' '.join(env_bits)} {launch_cmd}"
    send_to_pane(target, cmd)

    initial_message = str(architect_agent.get("initial_message", "")).strip()
    if initial_message:
        send_to_pane(target, initial_message)

    task_message = (
        f'Please read task file: "{task_path}" and execute architect role for '
        f'task_id "{task_id}" (worker "{worker_id}").'
    )
    send_to_pane(target, task_message)


def collect_active_worker_tasks(workers_map, queue_dir, plan_task_map):
    active_worker_tasks = []
    for worker_id, pane in workers_map.items():
        task_path = os.path.join(queue_dir, "tasks", f"{worker_id}.yaml")
        task_id, status, needs_architect, design_guidance = read_worker_task_fields(task_path)
        if not task_id or task_id == "null":
            continue
        if status not in ("assigned", "in_progress"):
            continue
        resolved_needs_architect = resolve_worker_needs_architect(worker_id, needs_architect, plan_task_map)
        active_worker_tasks.append(
            (worker_id, pane, task_id, task_path, resolved_needs_architect, design_guidance)
        )
    return active_worker_tasks


def dispatch_planner_workers(
    active_worker_tasks,
    has_architect_pane,
    resolve_architect_agent_fn=resolve_architect_agent,
    dispatch_architect_fn=dispatch_architect,
    dispatch_implementer_fn=dispatch_implementer,
):
    architect_targets = []
    implementer_targets = []
    for worker_id, pane, task_id, task_path, resolved_needs_architect, _ in active_worker_tasks:
        route = planner_route(has_architect_pane, resolved_needs_architect)
        if route is None:
            return (
                f"planner: blocked worker '{worker_id}' ({task_id}) because needs_architect=true "
                "but architect pane is not configured"
            )
        if route == "architect":
            architect_targets.append((worker_id, task_id, task_path))
            continue
        implementer_targets.append((worker_id, pane))

    architect_agent = None
    if has_architect_pane and architect_targets:
        architect_agent = resolve_architect_agent_fn()
        if should_abort_architect_launch(has_architect_pane, architect_targets, architect_agent):
            return "architect pane is configured but architect command resolution failed"

    for worker_id, task_id, task_path in architect_targets:
        dispatch_architect_fn(architect_agent, worker_id, task_id, task_path)
    for worker_id, pane in implementer_targets:
        dispatch_implementer_fn(worker_id, pane)

    return None


def run_smoke_tests():
    import tempfile
    import unittest

    class DispatchSmokeTests(unittest.TestCase):
        def test_planner_dispatch_with_architect_pane(self):
            self.assertEqual(planner_route(True, True), "architect")

        def test_planner_dispatch_without_architect_pane(self):
            self.assertIsNone(planner_route(False, True))

        def test_planner_blocked_worker_without_architect_pane_has_no_dispatch_side_effects(self):
            active_worker_tasks = [
                ("worker_001", "pane_worker_001", "cmd_0001_task_001", "/tmp/worker_001.yaml", True, False)
            ]
            dispatch_counts = {"architect": 0, "implementer": 0}

            def fake_resolve_architect_agent():
                return {"command": ["echo", "unused"]}

            def fake_dispatch_architect(*_args):
                dispatch_counts["architect"] += 1

            def fake_dispatch_implementer(*_args):
                dispatch_counts["implementer"] += 1

            planner_error = dispatch_planner_workers(
                active_worker_tasks,
                False,
                resolve_architect_agent_fn=fake_resolve_architect_agent,
                dispatch_architect_fn=fake_dispatch_architect,
                dispatch_implementer_fn=fake_dispatch_implementer,
            )

            self.assertEqual(
                planner_error,
                "planner: blocked worker 'worker_001' (cmd_0001_task_001) because needs_architect=true "
                "but architect pane is not configured",
            )
            self.assertEqual(dispatch_counts["architect"], 0)
            self.assertEqual(dispatch_counts["implementer"], 0)

        def test_architect_done_with_embedded_design_guidance(self):
            body = "\n".join(
                [
                    "schema_version: 1",
                    "task:",
                    '  task_id: "cmd_0001_task_001"',
                    "  status: assigned",
                    "  description: |",
                    "    ## Architect",
                    "    - needs_architect: true",
                    "    - design_guidance: embedded",
                    "    --- ARCHITECT DESIGN GUIDANCE ---",
                    "    decision: keep-plan-as-source",
                    "",
                ]
            )
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as tmp:
                tmp.write(body)
                tmp_path = tmp.name
            try:
                _, _, needs_architect, design_guidance = read_worker_task_fields(tmp_path)
            finally:
                os.remove(tmp_path)
            self.assertTrue(should_dispatch_architect_done(needs_architect, design_guidance))

        def test_architect_done_with_top_level_design_guidance(self):
            body = "\n".join(
                [
                    "schema_version: 1",
                    "task:",
                    '  task_id: "cmd_0001_task_001"',
                    "  status: assigned",
                    "  needs_architect: true",
                    "  design_guidance: complete",
                    "",
                ]
            )
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as tmp:
                tmp.write(body)
                tmp_path = tmp.name
            try:
                _, _, needs_architect, design_guidance = read_worker_task_fields(tmp_path)
            finally:
                os.remove(tmp_path)
            self.assertTrue(should_dispatch_architect_done(needs_architect, design_guidance))

        def test_architect_launch_failure_is_fatal(self):
            targets = [("worker_001", "cmd_0001_task_001", "/tmp/worker_001.yaml")]
            self.assertTrue(should_abort_architect_launch(True, targets, None))
            self.assertFalse(should_abort_architect_launch(False, targets, None))

        def test_planner_mixed_task_aborts_without_tmux_side_effects_on_architect_resolution_failure(self):
            with tempfile.TemporaryDirectory() as tmpdir:
                tasks_dir = os.path.join(tmpdir, "tasks")
                os.makedirs(tasks_dir, exist_ok=True)

                with open(os.path.join(tasks_dir, "worker_001.yaml"), "w", encoding="utf-8") as f:
                    f.write(
                        "\n".join(
                            [
                                "schema_version: 1",
                                "task:",
                                '  task_id: "cmd_0001_task_001"',
                                "  status: assigned",
                                "  needs_architect: true",
                                "",
                            ]
                        )
                    )
                with open(os.path.join(tasks_dir, "worker_002.yaml"), "w", encoding="utf-8") as f:
                    f.write(
                        "\n".join(
                            [
                                "schema_version: 1",
                                "task:",
                                '  task_id: "cmd_0001_task_002"',
                                "  status: assigned",
                                "  needs_architect: false",
                                "",
                            ]
                        )
                    )

                workers_map = {
                    "worker_001": "pane_architect_target",
                    "worker_002": "pane_implementer_target",
                }
                active_worker_tasks = collect_active_worker_tasks(workers_map, tmpdir, {})
                calls = []

                def fake_resolve_architect_agent():
                    return None

                def fake_dispatch_architect(*_args):
                    calls.append("architect")

                def fake_dispatch_implementer(*_args):
                    calls.append("implementer")

                planner_error = dispatch_planner_workers(
                    active_worker_tasks,
                    True,
                    resolve_architect_agent_fn=fake_resolve_architect_agent,
                    dispatch_architect_fn=fake_dispatch_architect,
                    dispatch_implementer_fn=fake_dispatch_implementer,
                )

            self.assertEqual(
                planner_error,
                "architect pane is configured but architect command resolution failed",
            )
            self.assertEqual(calls, [])

        def test_default_mode_dispatch_helper_skips_worker_without_design_guidance(self):
            active_worker_tasks = [
                ("worker_001", "pane_worker_001", "cmd_0001_task_001", "/tmp/worker_001.yaml", True, False)
            ]
            implementer_calls = 0
            skipped_workers = []

            def fake_dispatch_implementer(*_args):
                nonlocal implementer_calls
                implementer_calls += 1

            def fake_skip_reporter(worker_id, task_id):
                skipped_workers.append((worker_id, task_id))

            dispatch_default_workers(
                active_worker_tasks,
                dispatch_implementer_fn=fake_dispatch_implementer,
                skip_reporter_fn=fake_skip_reporter,
            )

            self.assertEqual(implementer_calls, 0)
            self.assertEqual(skipped_workers, [("worker_001", "cmd_0001_task_001")])

    suite = unittest.defaultTestLoader.loadTestsFromTestCase(DispatchSmokeTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


repo_root = os.environ["REPO_ROOT"]
panes_file = os.environ["PANES_FILE"]
orch_root = os.environ["ORCH_ROOT"]
session_id = os.environ.get("SESSION_ID", "")
dispatch_mode = to_text(os.environ.get("DISPATCH_MODE", "default")) or "default"
cmd_id = to_text(os.environ.get("CMD_ID", ""))
smoke_test_mode = to_text(os.environ.get("SMOKE_TEST_MODE", "0")) == "1"
dispatch_role = to_text(os.environ.get("DISPATCH_ROLE", ""))
dispatch_task_id = to_text(os.environ.get("DISPATCH_TASK_ID", ""))
session_suffix = f"_{session_id}" if session_id else ""

if smoke_test_mode:
    sys.exit(run_smoke_tests())

try:
    with open(panes_file, "r", encoding="utf-8") as f:
        panes_data = json.load(f)
    if not isinstance(panes_data, dict):
        raise TypeError("panes map must be a JSON object")
    session = panes_data["session"]
    workers = panes_data["workers"]
    if not isinstance(session, str) or not session:
        raise TypeError("session must be a non-empty string")
    if not isinstance(workers, dict):
        raise TypeError("workers must be a JSON object")
except (json.JSONDecodeError, OSError, KeyError, TypeError) as e:
    fail(f"Invalid panes map: {panes_file}: {e}")

work_dir = panes_data.get("work_dir", repo_root)
if not isinstance(work_dir, str) or not work_dir or not os.path.isdir(work_dir):
    work_dir = repo_root
architect_pane = panes_data.get("architect", "")
if not isinstance(architect_pane, str):
    architect_pane = ""

queue_dir = os.path.join(work_dir, ".yamibaito", f"queue{session_suffix}")
if not os.path.isdir(queue_dir):
    queue_dir = os.path.join(repo_root, ".yamibaito", f"queue{session_suffix}")

config_data = {}
config_path = os.path.join(repo_root, ".yamibaito", "config.yaml")
if os.path.isfile(config_path):
    try:
        config_data = parse_yaml_mapping(read_text(config_path))
    except OSError:
        config_data = {}

if dispatch_role:
    tasks_dir = os.path.join(queue_dir, "tasks")
    if not os.path.isdir(tasks_dir):
        fail(f"Missing tasks dir: {tasks_dir}")
    source_record = resolve_source_record(queue_dir, tasks_dir, dispatch_task_id)
    if source_record is None:
        reports_dir = os.path.join(queue_dir, "reports")
        plan_dir = os.path.join(queue_dir, "plan")
        fail(
            f"Missing task for --task-id {dispatch_task_id}: searched tasks={tasks_dir} plan={plan_dir} reports={reports_dir}"
        )

    source_task = source_record["task"]
    source_content = source_record["content"]
    source_origin = to_text(source_record.get("origin")) or "tasks"
    report_hints = source_record.get("report_hints")
    if not isinstance(report_hints, dict):
        report_hints = {}
    source_qg = source_task.get("quality_gate")
    if not isinstance(source_qg, dict):
        source_qg = {}
    source_constraints = source_task.get("constraints")
    if not isinstance(source_constraints, dict):
        source_constraints = {}

    implementer_worker_id = (
        to_text(source_qg.get("implementer_worker_id"))
        or to_text(source_task.get("assigned_to"))
        or to_text(report_hints.get("implementer_worker_id"))
    )
    reviewer_worker_id = resolve_reviewer_worker_id(source_task, source_qg, report_hints)
    source_description = resolve_source_description(source_content, source_task)

    print(
        f"dispatch_source: role={dispatch_role} task_id={dispatch_task_id} source={source_origin} path={to_text(source_record.get('path')) or '(unknown)'}",
        file=sys.stderr,
    )

    if dispatch_role == "reviewer":
        if not reviewer_worker_id:
            fail(
                "Missing reviewer worker: could not resolve from task.quality_gate.reviewer_worker_id, reports, or reviewer pane mapping"
            )
        if implementer_worker_id and implementer_worker_id == reviewer_worker_id:
            fail(
                f"CONFLICT: implementer ({implementer_worker_id}) == reviewer ({reviewer_worker_id}). Assign a different reviewer."
            )

        role_pane = resolve_role_pane("reviewer", reviewer_worker_id)
        if not role_pane:
            fail("Failed to resolve reviewer pane from v2_roles/workers")

        pathspecs = extract_list_values(source_content, "deliverables", 4)
        if not pathspecs:
            pathspecs = normalize_string_list(source_constraints.get("deliverables"))
        if not pathspecs:
            pathspecs = extract_list_values(source_content, "allowed_paths", 4)
        if not pathspecs:
            pathspecs = normalize_string_list(source_constraints.get("allowed_paths"))

        stat_args = ["diff", "--stat", "--no-color"]
        name_args = ["diff", "--name-status", "--no-color"]
        if pathspecs:
            stat_args.extend(["--"] + pathspecs)
            name_args.extend(["--"] + pathspecs)
        diff_stat = truncate_text(run_git_capture(stat_args))
        diff_names = truncate_text(run_git_capture(name_args))

        checklist_path = resolve_checklist_path(source_qg)
        if os.path.isfile(checklist_path):
            checklist_text = truncate_text(read_text(checklist_path))
        else:
            checklist_text = f"(missing checklist: {checklist_path})"

        reviewer_description = "\n".join(
            [
                "## Reviewer Dispatch Input",
                f"- source_task_id: {dispatch_task_id}",
                f"- implementer_worker_id: {implementer_worker_id or '(unknown)'}",
                f"- reviewer_worker_id: {reviewer_worker_id}",
                "",
                "### Implementer Diff Summary (`git diff --stat`)",
                diff_stat or "(no diff summary)",
                "",
                "### Implementer Diff Files (`git diff --name-status`)",
                diff_names or "(no file changes)",
                "",
                "### Task Requirements",
                source_description,
                "",
                f"### Review Checklist ({checklist_path})",
                checklist_text,
            ]
        ).strip()

        quality_gate_cfg = config_data.get("quality_gate")
        if not isinstance(quality_gate_cfg, dict):
            quality_gate_cfg = {}
        reviewer_persona = to_text(quality_gate_cfg.get("reviewer_persona")) or to_text(source_task.get("persona"))
        if not reviewer_persona:
            reviewer_persona = "qa_engineer"

        reviewer_task_yaml = render_role_task_yaml(
            source_task=source_task,
            source_content=source_content,
            role_name="reviewer",
            target_worker_id=reviewer_worker_id,
            source_task_id=dispatch_task_id,
            description_text=reviewer_description,
            persona=reviewer_persona,
            implementer_worker_id=implementer_worker_id,
            reviewer_worker_id=reviewer_worker_id,
        )
        reviewer_task_path = os.path.join(tasks_dir, f"{reviewer_worker_id}.yaml")
        write_text(reviewer_task_path, reviewer_task_yaml)
        send_two_step(session, role_pane, build_worker_command(reviewer_worker_id))
        print(
            f"dispatch_log: role=reviewer task_id={dispatch_task_id} worker={reviewer_worker_id} pane={role_pane}",
            file=sys.stderr,
        )
        sys.exit(0)

    if dispatch_role == "quality-gate":
        quality_gate_worker_id = resolve_quality_gate_worker(source_task)
        if not quality_gate_worker_id:
            quality_gate_pane = resolve_role_pane("quality_gate", "")
            if quality_gate_pane:
                quality_gate_worker_id = resolve_worker_id_by_pane(quality_gate_pane)
        if not quality_gate_worker_id:
            fail(
                "Missing dedicated quality-gate worker. Set task.quality_gate.quality_gate_worker_id or equivalent key."
            )
        if reviewer_worker_id and quality_gate_worker_id == reviewer_worker_id:
            fail(
                f"CONFLICT: reviewer ({reviewer_worker_id}) == quality-gate ({quality_gate_worker_id}). Assign a dedicated quality-gate worker."
            )

        role_pane = resolve_role_pane("quality_gate", quality_gate_worker_id)
        if not role_pane:
            fail("Failed to resolve quality-gate pane from v2_roles/workers")

        reports_dir = os.path.join(queue_dir, "reports")
        report_record = find_report_record_for_quality_gate(reports_dir, dispatch_task_id, reviewer_worker_id)
        if report_record is None:
            fail(
                f"Missing reviewer report for task_id={dispatch_task_id}: requires review_target_task_id match and non-null review_result ({reports_dir})"
            )

        report_data = report_record["report"]
        report_content = report_record["content"]
        recommendation = to_text(report_data.get("recommendation")) or to_text(report_data.get("review_result"))
        if not recommendation:
            fail(
                f"Invalid reviewer report for task_id={dispatch_task_id}: recommendation/review_result is empty ({report_record['path']})"
            )
        findings_block = extract_section_block(report_content, "findings", 2)
        if not findings_block:
            findings_block = extract_section_block(report_content, "rework_instructions", 2)
        if not findings_block:
            summary = to_text(report_data.get("summary")) or "(no reviewer findings found)"
            findings_block = f"findings:\n  - {summary}"

        loop_count = to_int(source_task.get("loop_count"), 0)
        gate_description = "\n".join(
            [
                "## Quality-Gate Dispatch Input",
                f"- source_task_id: {dispatch_task_id}",
                f"- reviewer_worker_id: {reviewer_worker_id or '(unknown)'}",
                f"- quality_gate_worker_id: {quality_gate_worker_id}",
                f"- loop_count: {loop_count}",
                "",
                "### Reviewer Recommendation",
                recommendation,
                "",
                f"### Reviewer Findings (from {report_record['path']})",
                findings_block,
                "",
                "### Task Requirements",
                source_description,
            ]
        ).strip()

        gate_persona = to_text(source_task.get("persona")) or "senior_software_engineer"
        gate_task_yaml = render_role_task_yaml(
            source_task=source_task,
            source_content=source_content,
            role_name="quality-gate",
            target_worker_id=quality_gate_worker_id,
            source_task_id=dispatch_task_id,
            description_text=gate_description,
            persona=gate_persona,
            implementer_worker_id=implementer_worker_id,
            reviewer_worker_id=reviewer_worker_id,
        )
        gate_task_path = os.path.join(tasks_dir, f"{quality_gate_worker_id}.yaml")
        write_text(gate_task_path, gate_task_yaml)
        send_two_step(session, role_pane, build_worker_command(quality_gate_worker_id))
        print(
            f"dispatch_log: role=quality-gate task_id={dispatch_task_id} worker={quality_gate_worker_id} pane={role_pane}",
            file=sys.stderr,
        )
        sys.exit(0)

plan_task_map = {}
if dispatch_mode in {"planner", "architect_done"}:
    if not cmd_id:
        fail("Missing --cmd-id")
    plan_tasks_path = os.path.join(queue_dir, "plan", cmd_id, "tasks.yaml")
    try:
        plan_task_map = read_plan_task_map(plan_tasks_path)
    except OSError as exc:
        mode_label = "--planner" if dispatch_mode == "planner" else "--architect-done"
        fail(f"Failed to read planner tasks for {mode_label}: {plan_tasks_path}: {exc}")

active_worker_tasks = collect_active_worker_tasks(workers, queue_dir, plan_task_map)

if dispatch_mode == "planner":
    planner_error = dispatch_planner_workers(active_worker_tasks, bool(architect_pane))
    if planner_error:
        fail(planner_error)
elif dispatch_mode == "architect_done":
    for worker_id, pane, task_id, _, resolved_needs_architect, design_guidance in active_worker_tasks:
        if not resolved_needs_architect:
            continue
        if not should_dispatch_architect_done(resolved_needs_architect, design_guidance):
            print(
                f"architect-done: skip worker '{worker_id}' ({task_id}) because design_guidance is missing",
                file=sys.stderr,
            )
            continue
        dispatch_implementer(worker_id, pane)
else:
    dispatch_default_workers(active_worker_tasks)
PY
