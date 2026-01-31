#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 引数処理（yb_start.sh と同じ形式）
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
repo_name="$(basename "$repo_root" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_name="yamibaito_${repo_name}"

# 既存セッションを kill
if tmux has-session -t "$session_name" 2>/dev/null; then
  echo "Killing existing session: $session_name"
  tmux kill-session -t "$session_name"
fi

# yb start を実行
exec "$ORCH_ROOT/scripts/yb_start.sh" --repo "$repo_root"
