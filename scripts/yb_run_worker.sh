#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repo_root="."
worker_id=""
session_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo_root="$2"
      shift 2
      ;;
    --worker)
      worker_id="$2"
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

if [ -z "$worker_id" ]; then
  echo "Missing --worker" >&2
  exit 1
fi

repo_root="$(cd "$repo_root" && pwd)"
session_id="$(echo "$session_id" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_suffix=""
if [ -n "$session_id" ]; then
  session_suffix="_${session_id}"
fi
# queue_dir を work_dir ベースで構築（フォールバック: repo_root）
_panes_file="$repo_root/.yamibaito/panes${session_suffix}.json"
_work_dir="$repo_root"
if [ -f "$_panes_file" ]; then
  _resolved="$(_PANES_FILE="$_panes_file" _REPO_ROOT="$repo_root" python3 - <<'PY'
import json, os

panes_file = os.environ["_PANES_FILE"]
repo_root = os.environ["_REPO_ROOT"]

try:
    with open(panes_file, "r") as f:
        d = json.load(f)
    wd = d.get("work_dir", "")
    if wd and os.path.isdir(wd):
        print(wd)
    else:
        print(repo_root)
except Exception:
    print(repo_root)
PY
)"
  _work_dir="$_resolved"
fi
queue_dir="$_work_dir/.yamibaito/queue${session_suffix}"
if [ ! -d "$queue_dir" ]; then
  queue_dir="$repo_root/.yamibaito/queue${session_suffix}"
fi
task_file="$queue_dir/tasks/${worker_id}.yaml"

if [ ! -f "$task_file" ]; then
  echo "Missing task file: $task_file" >&2
  exit 1
fi

REPO_ROOT="$repo_root" TASK_FILE="$task_file" ORCH_ROOT="$ORCH_ROOT" PANES_SUFFIX="$session_suffix" SESSION_ID="$session_id" python3 - <<'PY'
import os, sys, subprocess, json, re

repo_root = os.environ["REPO_ROOT"]
task_file = os.environ["TASK_FILE"]
panes_suffix = os.environ.get("PANES_SUFFIX", "")
session_id = os.environ.get("SESSION_ID", "")

with open(task_file, "r", encoding="utf-8") as f:
    content = f.read()

# Extract sandbox mode from task YAML (default: workspace-write)
sandbox_match = re.search(r'^\s*sandbox:\s*(\S+)', content, re.MULTILINE)
sandbox = sandbox_match.group(1).strip('"\'') if sandbox_match else "workspace-write"

# Read work_dir from panes.json
panes_path = os.path.join(repo_root, ".yamibaito", f"panes{panes_suffix}.json")
work_dir = repo_root  # default
if os.path.exists(panes_path):
    try:
        with open(panes_path, "r", encoding="utf-8") as f:
            panes_data = json.load(f)
        if isinstance(panes_data, dict):
            work_dir = panes_data.get("work_dir", repo_root)
    except (json.JSONDecodeError, OSError):
        pass
if not isinstance(work_dir, str) or not work_dir or not os.path.isdir(work_dir):
    work_dir = repo_root

cmd = ["codex", "exec", "--sandbox", sandbox, "-"]
proc = subprocess.Popen(
    cmd,
    stdin=subprocess.PIPE,
    stdout=sys.stdout,
    stderr=sys.stderr,
    cwd=work_dir,
    text=True,
)
proc.communicate(content)
exit_code = proc.returncode

try:
    with open(panes_path, "r", encoding="utf-8") as f:
        panes = json.load(f)
    if isinstance(panes, dict):
        workers = panes.get("workers", {})
        if isinstance(workers, dict):
            session = panes.get("session")
            waka = panes.get("waka")
            if session and waka:
                notify = "worker finished; please run: yb collect --repo " + repo_root
                if session_id:
                    notify += " --session " + session_id
                subprocess.run(["tmux", "send-keys", "-t", f"{session}:{waka}", notify], check=False)
                subprocess.run(["tmux", "send-keys", "-t", f"{session}:{waka}", "Enter"], check=False)
except FileNotFoundError:
    pass
except json.JSONDecodeError:
    pass

sys.exit(exit_code)
PY
