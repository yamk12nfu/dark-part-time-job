#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 引数処理（yb_start.sh と同じ形式）
repo_root="."
session_id=""
delete_worktree=false
from_ref=""
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
    --delete-worktree)
      delete_worktree=true
      shift
      ;;
    --from)
      from_ref="$2"
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
session_id="$(echo "$session_id" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_suffix=""
if [ -n "$session_id" ]; then
  session_suffix="_${session_id}"
fi
session_name="yamibaito_${repo_name}${session_suffix}"
panes_file="$repo_root/.yamibaito/panes${session_suffix}.json"

# panes から worktree 情報を復元（restart 時の再利用元）
wt_root=""
wt_branch=""
if [ -n "$session_id" ] && [ -f "$panes_file" ]; then
  wt_info=$(python3 -c "
import json, sys
try:
    with open('$panes_file', 'r') as f:
        data = json.load(f)
    root = data.get('worktree_root')
    branch = data.get('worktree_branch')
    if not isinstance(root, str):
        root = ''
    if not isinstance(branch, str):
        branch = ''
    print(f'{root}\\t{branch}')
except (json.JSONDecodeError, OSError, KeyError):
    sys.exit(1)
" 2>/dev/null) || true
  if [ -n "${wt_info:-}" ]; then
    IFS=$'\t' read -r wt_root wt_branch <<< "$wt_info"
  fi
fi

if [ -n "$wt_root" ] && [ ! -d "$wt_root" ]; then
  echo "warning: panes.json の worktree_root が存在しません: $wt_root" >&2
  wt_root=""
fi

if [ -n "$wt_root" ]; then
  wt_branch_from_path="$(git -C "$repo_root" gtr list --porcelain 2>/dev/null | awk -F'\t' -v p="$wt_root" '$1 == p {print $2; exit}' || true)"
  if [ -n "$wt_branch_from_path" ]; then
    wt_branch="$wt_branch_from_path"
  fi
fi

# 既存セッションを kill
if tmux has-session -t "$session_name" 2>/dev/null; then
  echo "Killing existing session: $session_name"
  tmux kill-session -t "$session_name"
fi

# === --delete-worktree 時のみ worktree を削除 ===
if [ "$delete_worktree" = "true" ] && [ -n "$session_id" ]; then
  if [ -n "$wt_root" ]; then
    echo "worktree を削除(path): $wt_root"
    if ! git -C "$repo_root" worktree remove "$wt_root" --force 2>&1; then
      echo "warning: worktree remove '$wt_root' に失敗しました。手動で確認してください。" >&2
    fi
  else
    # フォールバック: config の branch_prefix + session_id
    if [ -z "$wt_branch" ]; then
      config_file="$repo_root/.yamibaito/config.yaml"
      wt_prefix="yamibaito"
      if [ -f "$config_file" ]; then
        cfg_prefix=$(python3 -c "
import sys
for line in open('$config_file'):
    if 'branch_prefix' in line and ':' in line:
        print(line.split(':',1)[1].strip().strip('\"').strip(\"'\"))
        sys.exit(0)
sys.exit(1)
" 2>/dev/null) || true
        if [ -n "$cfg_prefix" ]; then
          wt_prefix="$cfg_prefix"
        fi
      fi
      wt_branch="${wt_prefix}/${session_id}"
      echo "warning: panes.json から worktree_root/worktree_branch を取得できず、${wt_branch} を推定して削除を試みます" >&2
    else
      echo "warning: worktree_root がないため branch ベース削除にフォールバックします: $wt_branch" >&2
    fi
    if [ -n "$wt_branch" ]; then
      echo "worktree を削除(branch fallback): $wt_branch"
      if ! git -C "$repo_root" gtr rm "$wt_branch" --yes 2>&1; then
        echo "warning: gtr rm '$wt_branch' に失敗しました。手動で確認してください。" >&2
      fi
    fi
  fi
fi

# yb start を実行
start_args=("--repo" "$repo_root")
if [ -n "$session_id" ]; then
  start_args+=("--session" "$session_id")
fi
if [ -n "$from_ref" ]; then
  start_args+=("--from" "$from_ref")
fi

# restart 時は panes の worktree 情報を yb start へ引き継ぐ
if [ "$delete_worktree" = "false" ] && [ -n "$wt_root" ]; then
  restart_wt_prefix=""
  if [ -n "$wt_branch" ] && [[ "$wt_branch" == */* ]]; then
    restart_wt_prefix="${wt_branch%/*}"
  fi
  if [ -n "$restart_wt_prefix" ]; then
    grep_real="$(command -v grep)"
    tmp_bin="$(mktemp -d "${TMPDIR:-/tmp}/yb-restart.XXXXXX")"
    cat > "$tmp_bin/grep" <<EOF
#!/bin/bash
if [ -n "\${YB_RESTART_WORKTREE_PREFIX:-}" ] && [ "\${1:-}" = "-E" ] && [ "\${2:-}" = "^\\s*branch_prefix:" ]; then
  printf 'branch_prefix: "%s"\\n' "\$YB_RESTART_WORKTREE_PREFIX"
  exit 0
fi
exec "$grep_real" "\$@"
EOF
    chmod +x "$tmp_bin/grep"
    exec env PATH="$tmp_bin:$PATH" \
      YB_RESTART_WORKTREE_ROOT="$wt_root" \
      YB_RESTART_WORKTREE_BRANCH="$wt_branch" \
      YB_RESTART_WORKTREE_PREFIX="$restart_wt_prefix" \
      "$ORCH_ROOT/scripts/yb_start.sh" "${start_args[@]}"
  fi
  exec env YB_RESTART_WORKTREE_ROOT="$wt_root" \
    YB_RESTART_WORKTREE_BRANCH="$wt_branch" \
    "$ORCH_ROOT/scripts/yb_start.sh" "${start_args[@]}"
fi

if [ -n "$session_id" ] && [ -z "$wt_branch" ]; then
  config_file="$repo_root/.yamibaito/config.yaml"
  wt_prefix="yamibaito"
  if [ -f "$config_file" ]; then
    cfg_prefix=$(python3 -c "
import sys
for line in open('$config_file'):
    if 'branch_prefix' in line and ':' in line:
        print(line.split(':',1)[1].strip().strip('\"').strip(\"'\"))
        sys.exit(0)
sys.exit(1)
" 2>/dev/null) || true
    if [ -n "$cfg_prefix" ]; then
      wt_prefix="$cfg_prefix"
    fi
  fi
  wt_branch="${wt_prefix}/${session_id}"
  echo "warning: panes.json から worktree_branch を取得できず、${wt_branch} を推定します" >&2
fi
exec env YB_RESTART_WORKTREE_ROOT="$wt_root" \
  YB_RESTART_WORKTREE_BRANCH="$wt_branch" \
  "$ORCH_ROOT/scripts/yb_start.sh" "${start_args[@]}"
