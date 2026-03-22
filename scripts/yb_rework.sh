#!/bin/bash
set -euo pipefail

repo_root="."
session_id=""
task_id=""
worker_id=""
max_loops="3"

die() {
  local reason="$1"
  shift || true
  local details=""
  if [ $# -gt 0 ]; then
    details=" $*"
  fi
  echo "ERROR: reason=${reason} task_id=${task_id:-unknown} worker=${worker_id:-unknown}${details}" >&2
  exit 1
}

shell_quote_single() {
  # Return POSIX-safe single-quoted token.
  local quoted="$1"
  # Replace single quote with: '\'' (close, escaped quote, reopen).
  quoted=${quoted//\'/\'\\\'\'}
  printf "'%s'" "$quoted"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      if [ $# -lt 2 ]; then
        die "missing_arg_value" "arg=--repo"
      fi
      repo_root="$2"
      shift 2
      ;;
    --session)
      if [ $# -lt 2 ]; then
        die "missing_arg_value" "arg=--session"
      fi
      session_id="$2"
      shift 2
      ;;
    --task-id)
      if [ $# -lt 2 ]; then
        die "missing_arg_value" "arg=--task-id"
      fi
      task_id="$2"
      shift 2
      ;;
    --worker-id)
      if [ $# -lt 2 ]; then
        die "missing_arg_value" "arg=--worker-id"
      fi
      worker_id="$2"
      shift 2
      ;;
    --max-loops)
      if [ $# -lt 2 ]; then
        die "missing_arg_value" "arg=--max-loops"
      fi
      max_loops="$2"
      shift 2
      ;;
    *)
      die "unknown_arg" "arg=$1"
      ;;
  esac
done

if [ -z "$worker_id" ]; then
  die "missing_required_arg" "arg=--worker-id"
fi

if [ -z "$task_id" ]; then
  die "missing_required_arg" "arg=--task-id"
fi

if ! [[ "$max_loops" =~ ^[0-9]+$ ]]; then
  die "invalid_max_loops" "max_loops=$max_loops"
fi

if ! repo_root="$(cd "$repo_root" 2>/dev/null && pwd)"; then
  die "invalid_repo_root" "repo=$repo_root"
fi
session_id="$(printf '%s' "$session_id" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_suffix=""
if [ -n "$session_id" ]; then
  session_suffix="_${session_id}"
fi

panes_file="$repo_root/.yamibaito/panes${session_suffix}.json"
if [ ! -f "$panes_file" ]; then
  die "missing_panes_map" "panes_file=$panes_file"
fi

if ! work_dir="$(_PANES_FILE="$panes_file" _REPO_ROOT="$repo_root" python3 - <<'PY' 2>/dev/null
import json
import os
import re
import sys


def kv(value):
    return re.sub(r"[^A-Za-z0-9._:/-]", "_", str(value))

panes_file = os.environ["_PANES_FILE"]
repo_root = os.environ["_REPO_ROOT"]

try:
    with open(panes_file, "r", encoding="utf-8") as f:
        panes = json.load(f)
except json.JSONDecodeError as exc:
    print(f"error=json_decode_error line={exc.lineno} col={exc.colno}")
    raise SystemExit(1)
except Exception as exc:
    print(f"error=panes_read_failed type={kv(type(exc).__name__)}")
    raise SystemExit(1)

if not isinstance(panes, dict):
    print("error=panes_not_object")
    raise SystemExit(1)

if "work_dir" not in panes:
    print(repo_root)
    raise SystemExit(0)

candidate = panes.get("work_dir")
if not isinstance(candidate, str):
    print(f"error=invalid_work_dir_type type={kv(type(candidate).__name__)}")
    raise SystemExit(1)

if candidate == "":
    print("error=invalid_work_dir_empty")
    raise SystemExit(1)

if not os.path.isdir(candidate):
    print(f"error=invalid_work_dir_not_directory work_dir={kv(candidate)}")
    raise SystemExit(1)

print(candidate)
raise SystemExit(0)
PY
)"; then
  work_dir_detail="${work_dir:-error=unknown}"
  die "invalid_panes_map" "${work_dir_detail} panes_file=$panes_file stage=resolve_work_dir"
fi

queue_dir="$work_dir/.yamibaito/queue${session_suffix}"
if [ ! -d "$queue_dir" ]; then
  queue_dir="$repo_root/.yamibaito/queue${session_suffix}"
fi

task_file="$queue_dir/tasks/${worker_id}.yaml"
if [ ! -f "$task_file" ]; then
  die "missing_task_file" "task_file=$task_file"
fi

if ! current_loop="$(_TASK_FILE="$task_file" python3 - <<'PY' 2>/dev/null
import os
import re

path = os.environ["_TASK_FILE"]
try:
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
except Exception:
    print("error=task_file_read_failed")
    raise SystemExit(1)

match = re.search(r"(?m)^  loop_count:\s*(.+?)\s*$", content)
if not match:
    print("0")
    raise SystemExit(0)

raw = match.group(1).split("#", 1)[0].strip().strip("\"'")
try:
    parsed = int(raw)
    if parsed < 0:
        raise ValueError("negative")
except Exception:
    print("0")
    raise SystemExit(0)

print(str(parsed))
PY
)"; then
  current_loop_detail="${current_loop:-error=unknown}"
  die "loop_count_read_failed" "${current_loop_detail} task_file=$task_file"
fi

next_loop=$((current_loop + 1))

if [ "$next_loop" -gt "$max_loops" ]; then
  if ! oyabun_target="$(_PANES_FILE="$panes_file" python3 - <<'PY' 2>/dev/null
import json
import os
import re
import sys


def kv(value):
    return re.sub(r"[^A-Za-z0-9._:/-]", "_", str(value))


panes_file = os.environ["_PANES_FILE"]

try:
    with open(panes_file, "r", encoding="utf-8") as f:
        panes = json.load(f)
except json.JSONDecodeError as exc:
    print(f"error=json_decode_error line={exc.lineno} col={exc.colno}")
    raise SystemExit(1)
except Exception as exc:
    print(f"error=panes_read_failed type={kv(type(exc).__name__)}")
    raise SystemExit(1)

if not isinstance(panes, dict):
    print("error=panes_not_object")
    raise SystemExit(1)

session = panes.get("session")
oyabun = panes.get("oyabun")
if not isinstance(session, str) or not session:
    print("error=missing_session")
    raise SystemExit(1)
if not isinstance(oyabun, str) or not oyabun:
    print("error=missing_oyabun")
    raise SystemExit(1)

print(f"{session}:{oyabun}")
PY
)"; then
    oyabun_target_detail="${oyabun_target:-error=unknown}"
    die "invalid_panes_map" "${oyabun_target_detail} panes_file=$panes_file stage=resolve_oyabun_target"
  fi

  escalation_msg="品質ゲート上限超過。task_id: ${task_id} が ${max_loops} 回差し戻された。dashboard を見てくれ。"
  escalation_cmd="printf '%s\\n' -- $(shell_quote_single "$escalation_msg")"

  if ! tmux send-keys -t "$oyabun_target" "$escalation_cmd" 2>/dev/null; then
    die "escalation_send_failed" "target=$oyabun_target stage=send_command"
  fi
  if ! tmux send-keys -t "$oyabun_target" Enter 2>/dev/null; then
    die "escalation_send_failed" "target=$oyabun_target stage=send_enter"
  fi

  echo "ESCALATION: task_id=${task_id} worker=${worker_id} next_loop=${next_loop} max_loops=${max_loops} reason=max_loops_exceeded" >&2
  exit 2
fi

if ! update_task_result="$(_TASK_FILE="$task_file" _NEXT_LOOP="$next_loop" _TASK_ID="$task_id" python3 - <<'PY' 2>/dev/null
import os
import re
import sys

path = os.environ["_TASK_FILE"]
next_loop = os.environ["_NEXT_LOOP"]
expected_task_id = os.environ["_TASK_ID"]


def kv(value):
    return re.sub(r"[^A-Za-z0-9._:/-]", "_", str(value))


try:
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
except Exception as exc:
    print(f"error=task_file_read_failed type={kv(type(exc).__name__)}")
    raise SystemExit(1)

task_id_match = re.search(r"(?m)^  task_id:\s*(.+?)\s*$", content)
if not task_id_match:
    print("error=missing_field field=task.task_id")
    raise SystemExit(1)

file_task_id = task_id_match.group(1).split("#", 1)[0].strip().strip("\"'")
if file_task_id != expected_task_id:
    print(
        f"error=task_id_mismatch expected_task_id={kv(expected_task_id)} file_task_id={kv(file_task_id)}"
    )
    raise SystemExit(1)


def replace_required(pattern, replacer, source, field_name):
    updated, count = re.subn(pattern, replacer, source, count=1, flags=re.MULTILINE)
    if count == 0:
        print(f"error=missing_field field={field_name}")
        raise SystemExit(1)
    return updated


content = replace_required(
    r"^  status:\s*[^#\n]*(\s*#.*)?$",
    lambda m: f"  status: assigned{m.group(1) or ''}",
    content,
    "task.status",
)
content = replace_required(
    r"^  loop_count:\s*[^#\n]*(\s*#.*)?$",
    lambda m: f"  loop_count: {next_loop}{m.group(1) or ''}",
    content,
    "task.loop_count",
)
content = replace_required(
    r"^  phase:\s*[^#\n]*(\s*#.*)?$",
    lambda m: f"  phase: implement{m.group(1) or ''}",
    content,
    "task.phase",
)

try:
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)
except Exception as exc:
    print(f"error=task_file_write_failed type={kv(type(exc).__name__)}")
    raise SystemExit(1)
PY
 )"; then
  update_task_detail="${update_task_result:-error=unknown}"
  die "task_yaml_update_failed" "${update_task_detail} task_file=$task_file"
fi

echo "REWORK: task_id=${task_id} worker=${worker_id} loop_count=${next_loop}/${max_loops}"
