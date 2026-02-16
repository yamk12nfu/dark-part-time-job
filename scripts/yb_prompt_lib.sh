#!/bin/bash
set -euo pipefail

# Prompt resolution library for yamibaito orchestrator

resolve_prompt_path() {
  local repo_root="$1"
  local name="$2"
  local prompt_path="$repo_root/.yamibaito/prompts/$name"
  local prompt_dir

  if [ ! -f "$prompt_path" ]; then
    echo "ERROR: Prompt file not found: $prompt_path" >&2
    return 1
  fi

  prompt_dir="$(cd "$(dirname "$prompt_path")" && pwd -P)"
  printf '%s\n' "$prompt_dir/$name"
}

validate_required_prompts() {
  local repo_root="$1"
  local required
  local prompt
  local missing=()

  required=("oyabun.md" "waka.md" "wakashu.md" "plan.md")

  for prompt in "${required[@]}"; do
    if [ ! -f "$repo_root/.yamibaito/prompts/$prompt" ]; then
      missing+=("$prompt")
    fi
  done

  if [ "${#missing[@]}" -gt 0 ]; then
    echo "ERROR: Missing required prompts in $repo_root/.yamibaito/prompts: ${missing[*]}" >&2
    return 1
  fi
}
