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
# 3点セット（新方式）
cp "$template_dir/PRD.md" "$plan_dir/PRD.md"
cp "$template_dir/SPEC.md" "$plan_dir/SPEC.md"
cp "$template_dir/tasks.yaml" "$plan_dir/tasks.yaml"
cp "$template_dir/review_prompt.md" "$plan_dir/review_prompt.md"

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
tmux send-keys -t "$session_name":0.1 "echo \"Run: yb plan-review\" && echo \"(writes: $plan_dir/plan_review_report.md)\"" C-m
sleep 2
# Ensure latest plan prompt is available
plan_prompt_src="$ORCH_ROOT/prompts/plan.md"
plan_prompt_dst="$repo_root/.yamibaito/prompts/plan.md"
if [ -f "$plan_prompt_src" ]; then
  mkdir -p "$(dirname "$plan_prompt_dst")"
  cp "$plan_prompt_src" "$plan_prompt_dst"
fi

plan_prompt="$plan_prompt_dst"
tmux send-keys -t "$session_name":0.0 "Please read file: \"$plan_prompt\" and follow it. You are the planner." C-m
sleep 2
tmux send-keys -t "$session_name":0.0 "Plan directory: \"$plan_dir\". Use PRD.md for product requirements, SPEC.md for implementation design, tasks.yaml for machine-readable task definitions. review_prompt.md is for Codex review, plan_review_report.md is for Codex review output. Plan is complete only when all 3 files (PRD.md, SPEC.md, tasks.yaml) are filled. When the user types \"plan-review\", run: yb plan-review." C-m

echo "yb plan: plan dir created at $plan_dir"
echo "yb plan: tmux session created: $session_name"
echo "Attach with: tmux attach -t $session_name"

if [ -z "${TMUX:-}" ]; then
  tmux attach -t "$session_name"
fi
