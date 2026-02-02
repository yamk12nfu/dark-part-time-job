#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo_root="."
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo_root="$2"
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

repo_root="$(cd "$repo_root" && pwd)"

config_dir="$repo_root/.yamibaito"
queue_dir="$config_dir/queue"
tasks_dir="$queue_dir/tasks"
reports_dir="$queue_dir/reports"
prompts_dir="$config_dir/prompts"
skills_dir="$config_dir/skills"
plan_dir="$config_dir/plan"

mkdir -p "$tasks_dir" "$reports_dir" "$prompts_dir" "$skills_dir" "$plan_dir"

if [ ! -f "$config_dir/config.yaml" ]; then
  cp "$ORCH_ROOT/templates/config.yaml" "$config_dir/config.yaml"
fi

if [ ! -f "$queue_dir/director_to_planner.yaml" ]; then
  cp "$ORCH_ROOT/templates/queue/director_to_planner.yaml" "$queue_dir/director_to_planner.yaml"
fi

if [ ! -f "$reports_dir/_index.json" ]; then
  cat > "$reports_dir/_index.json" <<'EOF'
{"processed_reports":[]}
EOF
fi

if [ ! -f "$repo_root/dashboard.md" ]; then
  cp "$ORCH_ROOT/templates/dashboard.md" "$repo_root/dashboard.md"
fi

cp "$ORCH_ROOT/prompts/oyabun.md" "$prompts_dir/oyabun.md"
cp "$ORCH_ROOT/prompts/waka.md" "$prompts_dir/waka.md"
cp "$ORCH_ROOT/prompts/wakashu.md" "$prompts_dir/wakashu.md"
cp "$ORCH_ROOT/prompts/plan.md" "$prompts_dir/plan.md"

worker_count=$(grep -E "^\\s*codex_count:" "$config_dir/config.yaml" | awk '{print $2}')
if [ -z "$worker_count" ]; then
  worker_count=3
fi

for i in $(seq 1 "$worker_count"); do
  worker_id=$(printf "worker_%03d" "$i")
  task_file="$tasks_dir/${worker_id}.yaml"
  report_file="$reports_dir/${worker_id}_report.yaml"
  if [ ! -f "$task_file" ]; then
    cp "$ORCH_ROOT/templates/queue/tasks/worker_task.yaml" "$task_file"
    sed -i "" "s/{{WORKER_ID}}/${worker_id}/g" "$task_file"
  fi
  if [ ! -f "$report_file" ]; then
    cp "$ORCH_ROOT/templates/queue/reports/worker_report.yaml" "$report_file"
    sed -i "" "s/{{WORKER_ID}}/${worker_id}/g" "$report_file"
  fi
done

echo "yb init: initialized repo at $repo_root"
