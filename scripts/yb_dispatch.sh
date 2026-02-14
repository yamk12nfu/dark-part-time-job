#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo_root="."
session_id=""
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
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

repo_root="$(cd "$repo_root" && pwd)"
session_id="$(echo "$session_id" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_suffix=""
if [ -n "$session_id" ]; then
  session_suffix="_${session_id}"
fi
panes_file="$repo_root/.yamibaito/panes${session_suffix}.json"

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
