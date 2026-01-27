#!/bin/bash
set -euo pipefail

repo_root="."
worker_id=""
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
task_file="$repo_root/.yamibaito/queue/tasks/${worker_id}.yaml"

if [ ! -f "$task_file" ]; then
  echo "Missing task file: $task_file" >&2
  exit 1
fi

REPO_ROOT="$repo_root" TASK_FILE="$task_file" python3 - <<'PY'
import os, sys, subprocess, json

repo_root = os.environ["REPO_ROOT"]
task_file = os.environ["TASK_FILE"]

with open(task_file, "r", encoding="utf-8") as f:
    content = f.read()

cmd = ["codex", "exec", "-"]
proc = subprocess.Popen(
    cmd,
    stdin=subprocess.PIPE,
    stdout=sys.stdout,
    stderr=sys.stderr,
    cwd=repo_root,
    text=True,
)
proc.communicate(content)
sys.exit(proc.returncode)
PY
