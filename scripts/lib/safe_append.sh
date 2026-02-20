#!/bin/bash

# safe_append return codes
SAFE_APPEND_ERR_NONE=70
SAFE_APPEND_ERR_EMPTY=71
SAFE_APPEND_ERR_IO=72
SAFE_APPEND_ERR_VERIFY=73
SAFE_APPEND_ERR_TIMEOUT=74

_safe_append_trim() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

_safe_append_run_with_timeout() {
  local timeout="$1"
  shift

  if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [ "$timeout" -le 0 ]; then
    "$@"
    return $?
  fi

  local marker
  marker="$(mktemp)"

  "$@" &
  local target_pid=$!

  (
    sleep "$timeout"
    if kill -0 "$target_pid" 2>/dev/null; then
      echo "timeout" > "$marker"
      kill -TERM "$target_pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$target_pid" 2>/dev/null || true
    fi
  ) &
  local watcher_pid=$!

  local status=0
  if wait "$target_pid"; then
    status=0
  else
    status=$?
  fi

  kill "$watcher_pid" 2>/dev/null || true
  wait "$watcher_pid" 2>/dev/null || true

  if [ -s "$marker" ]; then
    status=$SAFE_APPEND_ERR_TIMEOUT
  fi

  rm -f "$marker"
  return "$status"
}

_safe_append_once() {
  local filepath="$1"
  local content="$2"

  local target_dir
  target_dir="$(dirname "$filepath")"
  if [ -n "$target_dir" ] && [ "$target_dir" != "." ]; then
    mkdir -p "$target_dir" 2>/dev/null || return $SAFE_APPEND_ERR_IO
  fi

  printf '%s\n' "$content" >> "$filepath" || return $SAFE_APPEND_ERR_IO

  local expected_tail
  expected_tail="$(printf '%s\n' "$content" | tail -n 1)"
  local actual_tail
  actual_tail="$(tail -n 1 "$filepath" 2>/dev/null || true)"

  [ "$actual_tail" = "$expected_tail" ] || return $SAFE_APPEND_ERR_VERIFY
  return 0
}

safe_append() {
  local filepath="${1:-}"
  if [ "$#" -lt 2 ]; then
    echo "error: safe_append content is required (None detected)" >&2
    return $SAFE_APPEND_ERR_NONE
  fi

  local content="$2"
  if [ -z "$filepath" ]; then
    echo "error: safe_append filepath is required" >&2
    return $SAFE_APPEND_ERR_IO
  fi
  if [ "$content" = "None" ]; then
    echo "error: safe_append content must not be None" >&2
    return $SAFE_APPEND_ERR_NONE
  fi

  local trimmed
  trimmed="$(_safe_append_trim "$content")"
  if [ -z "$trimmed" ]; then
    echo "warning: safe_append rejected empty content for $filepath" >&2
    return $SAFE_APPEND_ERR_EMPTY
  fi

  local retry_max="${SAFE_APPEND_RETRY_MAX:-2}"
  local timeout="${SAFE_APPEND_TIMEOUT:-10}"
  local retry_interval="${SAFE_APPEND_RETRY_INTERVAL:-1}"
  if ! [[ "$retry_max" =~ ^[0-9]+$ ]]; then
    retry_max=2
  fi
  if ! [[ "$retry_interval" =~ ^[0-9]+$ ]]; then
    retry_interval=1
  fi

  local attempt=0
  local total=$((retry_max + 1))
  local status=0
  while [ "$attempt" -le "$retry_max" ]; do
    _safe_append_run_with_timeout "$timeout" _safe_append_once "$filepath" "$content" && return 0
    status=$?
    echo "warning: safe_append failed for $filepath (attempt $((attempt + 1))/$total, rc=$status)" >&2
    if [ "$attempt" -lt "$retry_max" ]; then
      sleep "$retry_interval"
    fi
    attempt=$((attempt + 1))
  done

  echo "error: safe_append exhausted retries for $filepath" >&2
  return "$status"
}
