#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

PROMPT_FILES=(
  "prompts/oyabun.md"
  "prompts/waka.md"
  "prompts/wakashu.md"
  "prompts/plan.md"
)

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

HAS_FAILURE=0

extract_front_matter() {
  local file_path="$1"
  local out_path="$2"
  awk '
    NR == 1 {
      if ($0 != "---") exit 0
      in_fm = 1
      next
    }
    in_fm && /^---$/ {
      closed = 1
      exit 0
    }
    in_fm { print }
    END {
      if (in_fm && !closed) exit 1
    }
  ' "${file_path}" > "${out_path}"
}

front_matter_path() {
  local relative_file="$1"
  local base
  base="$(basename "${relative_file}")"
  printf '%s/%s.fm\n' "${TMP_DIR}" "${base}"
}

strip_quotes_and_trim() {
  local input="$1"
  input="${input#"${input%%[![:space:]]*}"}"
  input="${input%"${input##*[![:space:]]}"}"
  input="${input%\"}"
  input="${input#\"}"
  input="${input%\'}"
  input="${input#\'}"
  printf '%s' "${input}"
}

get_top_level_value() {
  local fm_path="$1"
  local key="$2"
  local raw

  raw="$(awk -v key="${key}" '
    /^[[:space:]]*#/ { next }
    /^[^[:space:]][^:]*:[[:space:]]*/ {
      name = $0
      sub(/:.*/, "", name)
      if (name == key) {
        line = $0
        sub(/^[^:]*:[[:space:]]*/, "", line)
        sub(/[[:space:]]+#.*/, "", line)
        sub(/\r$/, "", line)
        print line
        found = 1
        exit
      }
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "${fm_path}")" || return 1

  strip_quotes_and_trim "${raw}"
}

get_nested_value() {
  local fm_path="$1"
  local section="$2"
  local key="$3"
  local raw

  raw="$(awk -v section="${section}" -v key="${key}" '
    /^[[:space:]]*#/ { next }
    {
      line = $0
      if (line ~ /^[^[:space:]][^:]*:[[:space:]]*(#.*)?$/) {
        name = line
        sub(/:.*/, "", name)
        if (name == section) {
          in_section = 1
          next
        }
        if (in_section) {
          exit
        }
      }

      if (in_section) {
        pattern = "^[[:space:]]+" key ":[[:space:]]*"
        if (line ~ pattern) {
          sub(pattern, "", line)
          sub(/[[:space:]]+#.*/, "", line)
          sub(/\r$/, "", line)
          print line
          found = 1
          exit
        }
      }
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "${fm_path}")" || return 1

  strip_quotes_and_trim "${raw}"
}

section_contains_phrase() {
  local fm_path="$1"
  local section="$2"
  local phrase="$3"

  awk -v section="${section}" -v phrase="${phrase}" '
    {
      line = $0
      if (line ~ /^[^[:space:]][^:]*:[[:space:]]*(#.*)?$/) {
        name = line
        sub(/:.*/, "", name)
        if (name == section) {
          in_section = 1
          next
        }
        if (in_section) {
          exit
        }
      }
      if (in_section && index(line, phrase) > 0) {
        found = 1
        exit
      }
    }
    END {
      exit(found ? 0 : 1)
    }
  ' "${fm_path}"
}

print_fail_detail() {
  local file="$1"
  local key="$2"
  local expected="$3"
  local actual="$4"
  printf '  FAIL: file=%s key=%s expected=%s actual=%s\n' "${file}" "${key}" "${expected}" "${actual}"
}

check_spec_version_consistency() {
  local idx=0
  local ref_value=""
  local check_failed=0
  local expected_label="present_and_identical"
  local values=()
  local file

  for file in "${PROMPT_FILES[@]}"; do
    local fm_path
    local value
    fm_path="$(front_matter_path "${file}")"
    if value="$(get_top_level_value "${fm_path}" "spec_version")"; then
      values[idx]="${value}"
      if [[ -z "${ref_value}" ]]; then
        ref_value="${value}"
      fi
    else
      values[idx]="__MISSING__"
      check_failed=1
    fi
    idx=$((idx + 1))
  done

  if [[ -n "${ref_value}" ]]; then
    expected_label="${ref_value}"
  fi

  idx=0
  for file in "${PROMPT_FILES[@]}"; do
    local current
    current="${values[idx]}"
    if [[ "${current}" == "__MISSING__" ]]; then
      check_failed=1
      idx=$((idx + 1))
      continue
    fi
    if [[ "${current}" != "${expected_label}" ]]; then
      check_failed=1
    fi
    idx=$((idx + 1))
  done

  if [[ "${check_failed}" -eq 0 ]]; then
    echo "[CHECK] spec_version consistency ... OK"
    return 0
  fi

  echo "[CHECK] spec_version consistency ... FAIL"
  idx=0
  for file in "${PROMPT_FILES[@]}"; do
    local current
    current="${values[idx]}"
    if [[ "${current}" == "__MISSING__" ]]; then
      print_fail_detail "${file}" "spec_version" "${expected_label}" "missing"
    elif [[ "${current}" != "${expected_label}" ]]; then
      print_fail_detail "${file}" "spec_version" "${expected_label}" "${current}"
    fi
    idx=$((idx + 1))
  done

  HAS_FAILURE=1
}

check_required_keys_for_file() {
  local file="$1"
  local fm_path="$2"
  local check_failed=0
  local details=()
  local value

  if ! value="$(get_top_level_value "${fm_path}" "spec_version")"; then
    check_failed=1
    details+=("spec_version|present|missing")
  fi

  if ! value="$(get_top_level_value "${fm_path}" "prompt_version")"; then
    check_failed=1
    details+=("prompt_version|present|missing")
  fi

  if ! value="$(get_nested_value "${fm_path}" "send_keys" "method")"; then
    check_failed=1
    details+=("send_keys.method|present|missing")
  fi

  if ! value="$(get_nested_value "${fm_path}" "notification" "worker_completion")"; then
    check_failed=1
    details+=("notification.worker_completion|present|missing")
  fi

  if value="$(get_top_level_value "${fm_path}" "version")"; then
    check_failed=1
    if [[ -z "${value}" ]]; then
      value="(empty)"
    fi
    details+=("version|absent|${value}")
  fi

  if [[ "${check_failed}" -eq 0 ]]; then
    echo "[CHECK] required keys: ${file} ... OK"
  else
    echo "[CHECK] required keys: ${file} ... FAIL"
    local detail
    for detail in "${details[@]}"; do
      local key expected actual
      key="${detail%%|*}"
      expected="${detail#*|}"
      expected="${expected%%|*}"
      actual="${detail##*|}"
      print_fail_detail "${file}" "${key}" "${expected}" "${actual}"
    done
    HAS_FAILURE=1
  fi
}

check_send_keys_method_uniformity() {
  local check_failed=0
  local file
  local details=()

  for file in "${PROMPT_FILES[@]}"; do
    local fm_path
    local method
    fm_path="$(front_matter_path "${file}")"
    if ! method="$(get_nested_value "${fm_path}" "send_keys" "method")"; then
      check_failed=1
      details+=("${file}|send_keys.method|two_step_send_keys|missing")
      continue
    fi

    if [[ "${method}" != "two_step_send_keys" ]]; then
      check_failed=1
      details+=("${file}|send_keys.method|two_step_send_keys|${method}")
    fi
  done

  if [[ "${check_failed}" -eq 0 ]]; then
    echo "[CHECK] send_keys.method uniformity ... OK"
  else
    echo "[CHECK] send_keys.method uniformity ... FAIL"
    local detail
    for detail in "${details[@]}"; do
      local target_file key expected actual
      target_file="${detail%%|*}"
      key="${detail#*|}"
      key="${key%%|*}"
      expected="${detail#*|*|}"
      expected="${expected%%|*}"
      actual="${detail##*|}"
      print_fail_detail "${target_file}" "${key}" "${expected}" "${actual}"
    done
    HAS_FAILURE=1
  fi
}

check_notification_path_consistency() {
  local check_failed=0
  local waka_file="prompts/waka.md"
  local wakashu_file="prompts/wakashu.md"
  local waka_fm
  local wakashu_fm
  local value
  local details=()

  waka_fm="$(front_matter_path "${waka_file}")"
  wakashu_fm="$(front_matter_path "${wakashu_file}")"

  if value="$(get_nested_value "${wakashu_fm}" "send_keys" "to_waka_allowed")"; then
    if [[ "${value}" != "false" ]]; then
      check_failed=1
      details+=("${wakashu_file}|send_keys.to_waka_allowed|false|${value}")
    fi
  else
    check_failed=1
    details+=("${wakashu_file}|send_keys.to_waka_allowed|false|missing")
  fi

  if value="$(get_nested_value "${waka_fm}" "notification" "worker_completion")"; then
    if [[ "${value}" != "yb_run_worker_notify" ]]; then
      check_failed=1
      details+=("${waka_file}|notification.worker_completion|yb_run_worker_notify|${value}")
    fi
  else
    check_failed=1
    details+=("${waka_file}|notification.worker_completion|yb_run_worker_notify|missing")
  fi

  if section_contains_phrase "${waka_fm}" "workflow" "若衆の tmux send-keys"; then
    check_failed=1
    details+=("${waka_file}|workflow|phrase_not_present:若衆の tmux send-keys|contains_phrase")
  fi

  if [[ "${check_failed}" -eq 0 ]]; then
    echo "[CHECK] notification path consistency ... OK"
  else
    echo "[CHECK] notification path consistency ... FAIL"
    local detail
    for detail in "${details[@]}"; do
      local target_file key expected actual
      target_file="${detail%%|*}"
      key="${detail#*|}"
      key="${key%%|*}"
      expected="${detail#*|*|}"
      expected="${expected%%|*}"
      actual="${detail##*|}"
      print_fail_detail "${target_file}" "${key}" "${expected}" "${actual}"
    done
    HAS_FAILURE=1
  fi
}

for relative_file in "${PROMPT_FILES[@]}"; do
  absolute_file="${REPO_ROOT}/${relative_file}"
  if [[ ! -f "${absolute_file}" ]]; then
    echo "Missing file: ${relative_file}" >&2
    exit 1
  fi
  if ! extract_front_matter "${absolute_file}" "$(front_matter_path "${relative_file}")"; then
    echo "[CHECK] front matter extraction: ${relative_file} ... FAIL"
    HAS_FAILURE=1
    continue
  fi
done

check_spec_version_consistency

for relative_file in "${PROMPT_FILES[@]}"; do
  check_required_keys_for_file "${relative_file}" "$(front_matter_path "${relative_file}")"
done

check_send_keys_method_uniformity
check_notification_path_consistency

echo "==="
if [[ "${HAS_FAILURE}" -eq 0 ]]; then
  echo "All checks passed."
  exit 0
fi

echo "Validation failed."
exit 1
