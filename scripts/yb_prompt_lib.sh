#!/bin/bash
set -euo pipefail

# Prompt resolution library for yamibaito orchestrator

resolve_prompt_path() {
  local repo_root="$1"
  local name="$2"
  local prompt_path="$repo_root/prompts/$name"
  local prompt_dir

  if [ ! -f "$prompt_path" ]; then
    echo "ERROR: Prompt file not found: $prompt_path" >&2
    return 1
  fi

  prompt_dir="$(cd "$(dirname "$prompt_path")" && pwd -P)"
  printf '%s\n' "$prompt_dir/$name"
}

ensure_prompt_link() {
  local repo_root="$1"
  local migrate_prompts=false
  local prompts_link="$repo_root/.yamibaito/prompts"
  local prompts_parent
  local desired_target="../prompts"

  case "${2:-}" in
    "")
      ;;
    --migrate-prompts)
      migrate_prompts=true
      ;;
    *)
      echo "ERROR: Unknown option for ensure_prompt_link: ${2}" >&2
      return 1
      ;;
  esac

  prompts_parent="$(dirname "$prompts_link")"

  if [ -L "$prompts_link" ]; then
    local current_target
    local current_abs=""
    local desired_abs=""

    current_target="$(readlink "$prompts_link")"

    if current_abs="$(cd "$prompts_parent" && cd "$current_target" 2>/dev/null && pwd -P)"; then
      :
    else
      current_abs=""
    fi

    if desired_abs="$(cd "$prompts_parent" && cd "$desired_target" 2>/dev/null && pwd -P)"; then
      :
    else
      desired_abs=""
    fi

    if [ -n "$current_abs" ] && [ -n "$desired_abs" ] && [ "$current_abs" = "$desired_abs" ]; then
      return 0
    fi

    if [ "$migrate_prompts" = true ]; then
      rm -f "$prompts_link"
    else
      echo "WARNING: $prompts_link is a symlink to '$current_target' (expected '$desired_target'). Re-run with --migrate-prompts to fix." >&2
      return 1
    fi
  fi

  if [ -e "$prompts_link" ]; then
    if [ "$migrate_prompts" = true ]; then
      local timestamp
      local backup_path

      timestamp="$(date +%Y%m%d%H%M%S)"
      backup_path="$prompts_parent/prompts.bak.$timestamp"
      mv "$prompts_link" "$backup_path"
      echo "MIGRATION: Backed up $prompts_link to $backup_path" >&2
      echo "MIGRATION: To restore: rm -f \"$prompts_link\" && mv \"$backup_path\" \"$prompts_link\"" >&2
    else
      echo "WARNING: $prompts_link exists as a real path. Re-run with --migrate-prompts to migrate safely." >&2
      return 1
    fi
  fi

  mkdir -p "$prompts_parent"

  if ! ln -s "$desired_target" "$prompts_link" 2>/dev/null; then
    echo "WARNING: Failed to create symlink $prompts_link -> $desired_target. Symlinks may not be supported on this filesystem." >&2
    return 1
  fi
}

validate_required_prompts() {
  local repo_root="$1"
  local required
  local prompt
  local missing=()

  required=("oyabun.md" "waka.md" "wakashu.md" "plan.md")

  for prompt in "${required[@]}"; do
    if [ ! -f "$repo_root/prompts/$prompt" ]; then
      missing+=("$prompt")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: Missing required prompts in $repo_root/prompts: ${missing[*]}" >&2
    return 1
  fi
}

# check_prompt_link <repo_root>
# 起動時に .yamibaito/prompts の整合性を検証する。
# リンク切れ・不一致の場合は stderr エラー + return 1。
# 契約:
# - 引数 repo_root を基準に、repo_root/.yamibaito/prompts -> ../prompts の整合性を検証する。
# - worktree 環境では repo_root（メインリポジトリルート）を渡すこと。worktree_root を渡してはならない。
# - worktree 側の symlink チェーン
#   （worktree/.yamibaito/prompts -> repo_root/.yamibaito/prompts）の検証はこの関数のスコープ外。
check_prompt_link() {
  local repo_root="$1"
  local prompts_link="$repo_root/.yamibaito/prompts"
  local prompts_parent
  local desired_target="../prompts"

  if [ ! -e "$prompts_link" ]; then
    echo "ERROR: $prompts_link does not exist. Run 'yb init --repo $repo_root' first." >&2
    return 1
  fi

  if [ -L "$prompts_link" ] && [ ! -d "$prompts_link" ]; then
    echo "ERROR: $prompts_link is a broken symlink (target: $(readlink "$prompts_link")). Run 'yb init --repo $repo_root' to fix." >&2
    return 1
  fi

  if [ -L "$prompts_link" ]; then
    local current_target
    local current_abs=""
    local desired_abs=""

    prompts_parent="$(dirname "$prompts_link")"
    current_target="$(readlink "$prompts_link")"

    if current_abs="$(cd "$prompts_parent" && cd "$current_target" 2>/dev/null && pwd -P)"; then
      :
    else
      current_abs=""
    fi

    if desired_abs="$(cd "$prompts_parent" && cd "$desired_target" 2>/dev/null && pwd -P)"; then
      :
    else
      desired_abs=""
    fi

    if [ -z "$current_abs" ] || [ -z "$desired_abs" ] || [ "$current_abs" != "$desired_abs" ]; then
      echo "ERROR: $prompts_link is a symlink to '$current_target' (expected '$desired_target'). Run 'yb init --repo $repo_root' to fix." >&2
      return 1
    fi
  fi

  return 0
}
