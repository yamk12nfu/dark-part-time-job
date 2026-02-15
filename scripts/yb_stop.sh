#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo_root="."
session_id=""
keep_worktree=false
delete_branch=false
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
    --keep-worktree)
      keep_worktree=true
      shift
      ;;
    --delete-branch)
      delete_branch=true
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

repo_root="$(cd "$repo_root" && pwd)"
repo_name="$(basename "$repo_root" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_id="$(echo "$session_id" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_suffix=""
if [ -n "$session_id" ]; then
  session_suffix="_${session_id}"
fi
session_name="yamibaito_${repo_name}${session_suffix}"

# tmux セッションを終了
if tmux has-session -t "$session_name" 2>/dev/null; then
  echo "Killing session: $session_name"
  tmux kill-session -t "$session_name"
else
  echo "Session not found: $session_name (skipping kill)"
fi

# worktree 削除（--keep-worktree 未指定時）
if [ "$keep_worktree" = "false" ] && [ -n "$session_id" ]; then
  panes_file="$repo_root/.yamibaito/panes${session_suffix}.json"
  wt_branch=""
  if [ -f "$panes_file" ]; then
    wt_branch=$(ORCH_ROOT="$ORCH_ROOT" PANES_FILE="$panes_file" python3 -c "
import os, sys
_orch = os.environ.get(\"ORCH_ROOT\", \"\")
if _orch:
    sys.path.insert(0, os.path.join(_orch, \"scripts\"))
try:
    from lib.panes import load_panes
except ModuleNotFoundError as _exc:
    print(f\"error: {_exc} — ORCH_ROOT={_orch!r}/scripts/lib/panes.py を確認してください\", file=sys.stderr)
    sys.exit(1)
try:
    data = load_panes(os.environ['PANES_FILE'])
    worktree = data.get('worktree', {})
    enabled = worktree.get('enabled', False)
    branch = worktree.get('branch', '')
    if enabled and branch:
        print(branch)
except Exception:
    sys.exit(1)
") || true
  fi
  if [ -n "$wt_branch" ]; then
    echo "worktree を削除: $wt_branch"
    gtr_args=("$wt_branch" "--yes")
    if [ "$delete_branch" = "true" ]; then
      gtr_args+=("--delete-branch")
    fi
    if ! git -C "$repo_root" gtr rm "${gtr_args[@]}" 2>&1; then
      echo "warning: gtr rm '${gtr_args[*]}' に失敗しました。手動で確認してください。" >&2
    fi
  fi
fi

echo "yb stop: session stopped: $session_name"
