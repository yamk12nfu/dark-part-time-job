#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo_root="."
session_id=""
planner_mode=0
cmd_id=""
dry_run=0
planner_only_arg=""
cmd_id_value_missing=0
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
    --cmd-id)
      if [ -z "$planner_only_arg" ]; then
        planner_only_arg="--cmd-id"
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
      if [ -z "$planner_only_arg" ]; then
        planner_only_arg="--dry-run"
      fi
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ "$planner_mode" -ne 1 ] && [ -n "$planner_only_arg" ]; then
  echo "Unknown arg: $planner_only_arg" >&2
  exit 1
fi

if [ "$planner_mode" -eq 1 ] && [ "$cmd_id_value_missing" -eq 1 ]; then
  echo "Missing value for --cmd-id" >&2
  exit 1
fi

repo_root="$(cd "$repo_root" && pwd)"
session_id="$(echo "$session_id" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_suffix=""
if [ -n "$session_id" ]; then
  session_suffix="_${session_id}"
fi
panes_file="$repo_root/.yamibaito/panes${session_suffix}.json"

if [ "$planner_mode" -eq 1 ]; then
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

if [ ! -f "$panes_file" ]; then
  echo "Missing panes map (run yb start): $panes_file" >&2
  exit 1
fi

REPO_ROOT="$repo_root" PANES_FILE="$panes_file" ORCH_ROOT="$ORCH_ROOT" SESSION_ID="$session_id" python3 - <<'PY'
import json, os, subprocess, sys

repo_root = os.environ["REPO_ROOT"]
panes_file = os.environ["PANES_FILE"]
orch_root = os.environ["ORCH_ROOT"]
session_id = os.environ.get("SESSION_ID", "")
session_suffix = f"_{session_id}" if session_id else ""

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
    print(f"Invalid panes map: {panes_file}: {e}", file=sys.stderr)
    sys.exit(1)

work_dir = panes_data.get("work_dir", repo_root)
if not isinstance(work_dir, str) or not work_dir or not os.path.isdir(work_dir):
    work_dir = repo_root

# Build queue_dir from work_dir first, then fall back to repo_root for compatibility.
queue_dir = os.path.join(work_dir, ".yamibaito", f"queue{session_suffix}")
if not os.path.isdir(queue_dir):
    queue_dir = os.path.join(repo_root, ".yamibaito", f"queue{session_suffix}")

def read_task_status(task_path):
    if not os.path.exists(task_path):
        return None, None
    task_id = None
    status = None
    with open(task_path, "r", encoding="utf-8") as f:
        for line in f:
            if line.strip().startswith("task_id:"):
                task_id = line.split(":", 1)[1].strip().strip('"')
            if line.strip().startswith("status:"):
                status = line.split(":", 1)[1].strip().strip('"')
    return task_id, status

for worker_id, pane in workers.items():
    task_path = os.path.join(queue_dir, "tasks", f"{worker_id}.yaml")
    task_id, status = read_task_status(task_path)
    if not task_id or task_id == "null":
        continue
    if status not in ("assigned", "in_progress"):
        continue
    cmd = f'cd "{work_dir}" && "{orch_root}/scripts/yb_run_worker.sh" --repo "{repo_root}" --worker "{worker_id}"'
    if session_id:
        cmd += f' --session "{session_id}"'
    subprocess.run(["tmux", "send-keys", "-t", f"{session}:{pane}", cmd], check=False)
    subprocess.run(["tmux", "send-keys", "-t", f"{session}:{pane}", "Enter"], check=False)
PY
