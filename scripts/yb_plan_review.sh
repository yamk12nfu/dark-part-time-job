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

prd_file="$plan_dir/PRD.md"
spec_file="$plan_dir/SPEC.md"
tasks_file="$plan_dir/tasks.yaml"
for f in "$prd_file" "$spec_file" "$tasks_file"; do
  if [ ! -f "$f" ]; then
    echo "Missing: $f" >&2
    exit 1
  fi
done

review_report="$plan_dir/plan_review_report.md"
runtime_prompt="$plan_dir/review_prompt_runtime.md"

validator="$ORCH_ROOT/scripts/yb_plan_validate.py"
set +e
validate_output="$("$validator" --plan-dir "$plan_dir" 2>&1)"
validate_exit=$?
set -e

if [ $validate_exit -ne 0 ]; then
  cat > "$review_report" <<EOF
# Plan Review Report

## Static Validation

Result: FAIL

Fail reasons:

$validate_output

LLM review skipped (static validation failed).
EOF
  echo "yb plan-review: static validation FAILED. See $review_report"
  exit 1
fi

# Write static validation result first (always preserved even if Codex fails)
cat > "$review_report" <<EOF
# Plan Review Report

## Static Validation

Result: PASS

$validate_output

## LLM Review

(Codex による LLM レビュー実行中... 完了後にこのセクションが更新されます)
EOF

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

cat "$review_prompt" > "$runtime_prompt"
cat >> "$runtime_prompt" <<EOF

---

This is a requirements/plan review, not a code review.

## Review Targets (absolute paths)
- $prd_file    (PRD.md - プロダクト要件)
- $spec_file   (SPEC.md - 実装設計)
- $tasks_file  (tasks.yaml - タスク定義)

## 追加観点（3点セット固有）
- AC（Given/When/Then）が薄い / 足りない箇所を指摘
- Open Questions が不足している箇所を指摘
- タスク粒度が大きすぎ/小さすぎ、依存関係が不適切な箇所を指摘
- NFR（セキュリティ/ログ/性能）の漏れを指摘
- tasks.yaml の requirement_ids が PRD.md の FR/NFR と対応しているか

Read ONLY these files. Do not search for other files or directories.
EOF

cmd="codex exec \"\$(cat \"$runtime_prompt\")\" | tee -a \"$review_report\""
tmux send-keys -t "$session_name":"$codex_pane" "$cmd"
tmux send-keys -t "$session_name":"$codex_pane" Enter

echo "yb plan-review: static validation PASSED."
echo "yb plan-review: LLM review を Codex ペインに送信しました。"
echo "yb plan-review: 完了後 $review_report を確認してください。"
