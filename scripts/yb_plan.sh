#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo_root="."
title=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo_root="$2"
      shift 2
      ;;
    --title)
      title="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

repo_root="$(cd "$repo_root" && pwd)"
repo_name="$(basename "$repo_root" | sed 's/[^A-Za-z0-9_-]/_/g')"

config_dir="$repo_root/.yamibaito"
config_file="$config_dir/config.yaml"
if [ ! -f "$config_file" ]; then
  "$ORCH_ROOT/scripts/yb_init_repo.sh" --repo "$repo_root"
fi

plan_root="$config_dir/plan"
mkdir -p "$plan_root"

if [ -z "$title" ]; then
  echo "Enter short title (2-4 words, lowercase, hyphenated):"
  read -r title
fi

if [ -z "$title" ]; then
  title="plan"
fi

slug="$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+//; s/-+$//; s/-+/-/g')"
if [ -z "$slug" ]; then
  slug="plan"
fi

today="$(date "+%Y-%m-%d")"
base_name="${today}--${slug}"
plan_dir="$plan_root/$base_name"
suffix=1
while [ -e "$plan_dir" ]; do
  plan_dir="${plan_root}/${base_name}-${suffix}"
  suffix=$((suffix + 1))
done

mkdir -p "$plan_dir"

template_dir="$ORCH_ROOT/templates/plan"
cp "$template_dir/plan.md" "$plan_dir/plan.md"
cp "$template_dir/tasks.md" "$plan_dir/tasks.md"
cp "$template_dir/checklist.md" "$plan_dir/checklist.md"
cp "$template_dir/review_prompt.md" "$plan_dir/review_prompt.md"
cp "$template_dir/review_report.md" "$plan_dir/review_report.md"

session_name="yamibaito_plan_${repo_name}_${slug}"
if tmux has-session -t "$session_name" 2>/dev/null; then
  echo "tmux session already exists: $session_name" >&2
  echo "Attach with: tmux attach -t $session_name" >&2
  exit 1
fi

tmux new-session -d -s "$session_name" -n plan
# Split a small bottom pane for Codex.
tmux split-window -v -p 20 -t "$session_name":0
tmux select-pane -t "$session_name":0.0 -T "plan"
tmux select-pane -t "$session_name":0.1 -T "codex"

cat > "$plan_dir/panes.json" <<EOF
{"session":"$session_name","plan":"0.0","codex":"0.1"}
EOF

tmux send-keys -t "$session_name":0.0 "export PATH=\"$ORCH_ROOT/bin:\$PATH\" YB_PLAN_REPO=\"$repo_root\" YB_PLAN_DIR=\"$plan_dir\" && cd \"$repo_root\" && clear" C-m
tmux send-keys -t "$session_name":0.1 "export PATH=\"$ORCH_ROOT/bin:\$PATH\" YB_PLAN_REPO=\"$repo_root\" YB_PLAN_DIR=\"$plan_dir\" && cd \"$repo_root\" && clear" C-m
tmux send-keys -t "$session_name":0.0 "claude --dangerously-skip-permissions" C-m
tmux send-keys -t "$session_name":0.1 "echo \"Run: yb plan-review\" && echo \"(writes: $plan_dir/review_report.md)\"" C-m
sleep 2
plan_prompt="$repo_root/.yamibaito/prompts/plan.md"
tmux send-keys -t "$session_name":0.0 "Please read file: \"$plan_prompt\" and follow it. You are the planner." C-m
sleep 2
tmux send-keys -t "$session_name":0.0 "Plan directory: \"$plan_dir\". Use plan.md for the main plan, tasks.md for task breakdown, checklist.md for review checklist, review_prompt.md for Codex review, review_report.md for Codex output. When the user types \"/plan-review\", run: yb plan-review. The codex pane shows the command to run." C-m

echo "yb plan: plan dir created at $plan_dir"
echo "yb plan: tmux session created: $session_name"
echo "Attach with: tmux attach -t $session_name"

if [ -z "${TMUX:-}" ]; then
  tmux attach -t "$session_name"
fi
