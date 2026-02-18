#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo_root="."
# Usage: yb init --repo <repo_root>
#   --repo <path>        Target repository root (default: .)
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
source "$ORCH_ROOT/scripts/yb_prompt_lib.sh"

config_dir="$repo_root/.yamibaito"
queue_dir="$config_dir/queue"
tasks_dir="$queue_dir/tasks"
reports_dir="$queue_dir/reports"
skills_dir="$config_dir/skills"
plan_dir="$config_dir/plan"

mkdir -p "$tasks_dir" "$reports_dir" "$skills_dir" "$plan_dir"

# Plan テンプレート（3点セット）
for tmpl in PRD.md SPEC.md tasks.yaml; do
  cp "$ORCH_ROOT/templates/plan/$tmpl" "$plan_dir/$tmpl"
done

if [ ! -f "$config_dir/config.yaml" ]; then
  cp "$ORCH_ROOT/templates/config.yaml" "$config_dir/config.yaml"
fi

cp "$ORCH_ROOT/templates/queue/director_to_planner.yaml" "$queue_dir/director_to_planner.yaml"

if [ ! -f "$reports_dir/_index.json" ]; then
  cat > "$reports_dir/_index.json" <<'EOF'
{"processed_reports":[]}
EOF
fi

cp "$ORCH_ROOT/templates/dashboard.md" "$repo_root/dashboard.md"

# === Prompt files ===
prompts_dir="$config_dir/prompts"

# レガシー symlink の除去（.yamibaito/prompts が ../prompts への symlink だった場合）
if [ -L "$prompts_dir" ]; then
  rm "$prompts_dir"
  echo "MIGRATION: .yamibaito/prompts の旧 symlink を除去しました。" >&2
fi

# Legacy migration: repo_root/prompts/ → .yamibaito/prompts/
legacy_prompts_dir="$repo_root/prompts"
if [ -d "$legacy_prompts_dir" ] && { [ ! -d "$prompts_dir" ] || [ -z "$(ls -A "$prompts_dir" 2>/dev/null)" ]; }; then
  mkdir -p "$prompts_dir"
  for f in "$legacy_prompts_dir"/*.md; do
    [ -f "$f" ] || continue
    fname="$(basename "$f")"
    if [ ! -f "$prompts_dir/$fname" ]; then
      cp "$f" "$prompts_dir/$fname"
    fi
  done
  echo "MIGRATION: prompts/ を .yamibaito/prompts/ にコピーしました。repo_root/prompts/ は不要になったため削除できます。" >&2
fi

# $ORCH_ROOT/prompts/ からの初期配置（新規リポジトリ用）
mkdir -p "$prompts_dir"
for prompt in oyabun.md waka.md wakashu.md plan.md; do
  cp "$ORCH_ROOT/prompts/$prompt" "$prompts_dir/$prompt"
done

templates_dir="$config_dir/templates"
mkdir -p "$templates_dir"
cp "$ORCH_ROOT/templates/review-checklist.yaml" "$templates_dir/review-checklist.yaml"

validate_required_prompts "$repo_root"

worker_count=$(grep -E "^\\s*codex_count:" "$config_dir/config.yaml" | awk '{print $2}')
if [ -z "$worker_count" ]; then
  worker_count=3
fi

for i in $(seq 1 "$worker_count"); do
  worker_id=$(printf "worker_%03d" "$i")
  task_file="$tasks_dir/${worker_id}.yaml"
  report_file="$reports_dir/${worker_id}_report.yaml"
  cp "$ORCH_ROOT/templates/queue/tasks/worker_task.yaml" "$task_file"
  sed -i "" "s/{{WORKER_ID}}/${worker_id}/g" "$task_file"
  cp "$ORCH_ROOT/templates/queue/reports/worker_report.yaml" "$report_file"
  sed -i "" "s/{{WORKER_ID}}/${worker_id}/g" "$report_file"
done

# === .gitignore に .yamibaito/ と dashboard.md を追記 ===
gitignore_file="$repo_root/.gitignore"
if [ -f "$gitignore_file" ]; then
  # 末尾改行を保証
  if [ -s "$gitignore_file" ] && [ "$(tail -c1 "$gitignore_file" | wc -l)" -eq 0 ]; then
    echo "" >> "$gitignore_file"
  fi
  if ! grep -qxF '.yamibaito/' "$gitignore_file"; then
    echo '.yamibaito/' >> "$gitignore_file"
  fi
  if ! grep -qxF 'dashboard.md' "$gitignore_file"; then
    echo 'dashboard.md' >> "$gitignore_file"
  fi
else
  cat > "$gitignore_file" <<'GITIGNORE'
.yamibaito/
dashboard.md
GITIGNORE
fi

echo "yb init: initialized repo at $repo_root"
