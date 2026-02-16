#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo_root="."
migrate_prompts=false
# Usage: yb init --repo <repo_root> [--migrate-prompts]
#   --repo <path>        Target repository root (default: .)
#   --migrate-prompts    Convert legacy .yamibaito/prompts/ directory to symlink.
#                        Backs up existing directory to .yamibaito/prompts.bak.<timestamp>.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo_root="$2"
      shift 2
      ;;
    --migrate-prompts)
      migrate_prompts=true
      shift
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
  if [ ! -f "$plan_dir/$tmpl" ]; then
    cp "$ORCH_ROOT/templates/plan/$tmpl" "$plan_dir/$tmpl"
  fi
done

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

# === Seed prompt files for new repos ===
prompts_dir="$repo_root/prompts"
mkdir -p "$prompts_dir"
for pfile in oyabun.md waka.md wakashu.md plan.md; do
  if [ ! -f "$prompts_dir/$pfile" ]; then
    cp "$ORCH_ROOT/prompts/$pfile" "$prompts_dir/$pfile"
  fi
done

# === Migration from legacy prompts setup ===
# 旧構成: .yamibaito/prompts/ が実ディレクトリで、prompts/*.md のコピーを保持
# 新構成: .yamibaito/prompts は ../prompts（= repo_root/prompts）へのシンボリックリンク
#
# 移行手順:
#   1. yb init --repo <repo_root> --migrate-prompts を実行
#   2. 旧ディレクトリは .yamibaito/prompts.bak.<timestamp> に退避される
#   3. 退避ファイルに独自変更がないか確認し、不要なら削除
#
# 方針:
#   シンボリックリンク非対応環境はサポート対象外
#   ln -s 失敗時は初期化を停止する
if [ "$migrate_prompts" = true ]; then
  ensure_prompt_link "$repo_root" --migrate-prompts
else
  ensure_prompt_link "$repo_root"
fi
validate_required_prompts "$repo_root"

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
