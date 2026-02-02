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
queue_dir="$repo_root/.yamibaito/queue${session_suffix}"

if [ ! -f "$panes_file" ]; then
  echo "Missing panes map (run yb start): $panes_file" >&2
  exit 1
fi

REPO_ROOT="$repo_root" PANES_FILE="$panes_file" QUEUE_DIR="$queue_dir" ORCH_ROOT="$ORCH_ROOT" SESSION_ID="$session_id" python3 - <<'PY'
import json, os, subprocess, sys

repo_root = os.environ["REPO_ROOT"]
panes_file = os.environ["PANES_FILE"]
orch_root = os.environ["ORCH_ROOT"]
queue_dir = os.environ["QUEUE_DIR"]
session_id = os.environ.get("SESSION_ID", "")

with open(panes_file, "r", encoding="utf-8") as f:
    panes = json.load(f)

session = panes["session"]
workers = panes.get("workers", {})

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
    cmd = f'cd "{repo_root}" && "{orch_root}/scripts/yb_run_worker.sh" --repo "{repo_root}" --worker "{worker_id}"'
    if session_id:
        cmd += f' --session "{session_id}"'
    subprocess.run(["tmux", "send-keys", "-t", f"{session}:{pane}", cmd], check=False)
    subprocess.run(["tmux", "send-keys", "-t", f"{session}:{pane}", "Enter"], check=False)
PY
