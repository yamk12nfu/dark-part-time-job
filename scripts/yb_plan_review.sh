#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo_root=""
plan_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo_root="$2"
      shift 2
      ;;
    --plan-dir)
      plan_dir="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ -z "$repo_root" ]; then
  repo_root="${YB_PLAN_REPO:-}"
fi
if [ -z "$plan_dir" ]; then
  plan_dir="${YB_PLAN_DIR:-}"
fi

if [ -z "$repo_root" ]; then
  echo "Missing --repo (or YB_PLAN_REPO)" >&2
  exit 1
fi
if [ -z "$plan_dir" ]; then
  echo "Missing --plan-dir (or YB_PLAN_DIR)" >&2
  exit 1
fi

repo_root="$(cd "$repo_root" && pwd)"

plan_dir="$(cd "$plan_dir" && pwd)"
panes_file="$plan_dir/panes.json"
if [ ! -f "$panes_file" ]; then
  echo "Missing panes.json: $panes_file" >&2
  exit 1
fi

read -r session_name codex_pane < <(python3 - "$panes_file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
print(data["session"], data["codex"])
PY
)

if ! tmux has-session -t "$session_name" 2>/dev/null; then
  echo "tmux session not found: $session_name" >&2
  exit 1
fi

review_prompt="$plan_dir/review_prompt.md"
if [ ! -f "$review_prompt" ]; then
  echo "Missing review prompt: $review_prompt" >&2
  exit 1
fi

plan_file="$plan_dir/plan.md"
tasks_file="$plan_dir/tasks.md"
checklist_file="$plan_dir/checklist.md"
if [ ! -f "$plan_file" ]; then
  echo "Missing plan: $plan_file" >&2
  exit 1
fi
if [ ! -f "$tasks_file" ]; then
  echo "Missing tasks: $tasks_file" >&2
  exit 1
fi
if [ ! -f "$checklist_file" ]; then
  echo "Missing checklist: $checklist_file" >&2
  exit 1
fi

review_report="$plan_dir/review_report.md"
runtime_prompt="$plan_dir/review_prompt_runtime.md"
cat "$review_prompt" > "$runtime_prompt"
cat >> "$runtime_prompt" <<EOF

---

This is a requirements/plan review, not a code review.

## Review Targets (absolute paths)
- $plan_file
- $tasks_file
- $checklist_file

Read ONLY these files. Do not search for other files or directories.
EOF

cmd="codex exec \"\$(cat \"$runtime_prompt\")\" | tee \"$review_report\""
tmux send-keys -t "$session_name":"$codex_pane" "$cmd"
tmux send-keys -t "$session_name":"$codex_pane" Enter

echo "yb plan-review: sent to codex pane ($session_name:$codex_pane)"
