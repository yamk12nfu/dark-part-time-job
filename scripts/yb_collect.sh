#!/bin/bash
set -euo pipefail

repo_root="."
session_id=""
lock_timeout="30"
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
    --lock-timeout)
      lock_timeout="$2"
      if ! [[ "$lock_timeout" =~ ^[0-9]+$ ]]; then
        echo "error: --lock-timeout must be a non-negative integer (got '$lock_timeout')" >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

repo_root="$(cd "$repo_root" && pwd)"
session_id="$(echo "$session_id" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_suffix=""
if [ -n "$session_id" ]; then
  session_suffix="_${session_id}"
fi

SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

READ_RETRY_MAX=2
READ_TIMEOUT=10
APPEND_RETRY_MAX=2
APPEND_TIMEOUT=10
COLLECT_RETRY_MAX=1
COLLECT_TIMEOUT=60
RETRY_INTERVAL_SECONDS=1

SAFE_APPEND_LIB="$SCRIPTS_DIR/lib/safe_append.sh"
if [ -f "$SAFE_APPEND_LIB" ]; then
  # shellcheck source=/dev/null
  source "$SAFE_APPEND_LIB"
else
  echo "warning: [APPEND] safe_append helper unavailable: $SAFE_APPEND_LIB" >&2
fi

run_with_timeout() {
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
    status=124
  fi

  rm -f "$marker"
  return "$status"
}

RECOVERY_WARNING_LINES=()

emit_recovery_warning() {
  local stage="$1"
  local message="$2"
  local stamp
  stamp="$(date "+%Y-%m-%dT%H:%M:%S")"
  local line="- [WARN][$stamp][$stage] $message"
  RECOVERY_WARNING_LINES+=("$line")
  echo "warning: [$stage] $message" >&2
}

flush_recovery_warnings_to_dashboard() {
  local dashboard_path="$1"
  [ "${#RECOVERY_WARNING_LINES[@]}" -eq 0 ] && return 0

  for line in "${RECOVERY_WARNING_LINES[@]}"; do
    if declare -F safe_append >/dev/null 2>&1; then
      if ! SAFE_APPEND_RETRY_MAX="$APPEND_RETRY_MAX" \
        SAFE_APPEND_TIMEOUT="$APPEND_TIMEOUT" \
        SAFE_APPEND_RETRY_INTERVAL="$RETRY_INTERVAL_SECONDS" \
        safe_append "$dashboard_path" "$line"; then
        echo "warning: [APPEND] failed to append warning with safe_append: $dashboard_path" >&2
        printf '%s\n' "$line" >> "$dashboard_path" 2>/dev/null || true
      fi
    else
      printf '%s\n' "$line" >> "$dashboard_path" 2>/dev/null || true
    fi
  done

  RECOVERY_WARNING_LINES=()
}

resolve_work_dir_with_python() {
  PANES_FILE="$panes_file" REPO_ROOT="$repo_root" python3 - <<'PY'
import json, os

repo_root = os.environ["REPO_ROOT"]
panes_file = os.environ["PANES_FILE"]
work_dir = repo_root

try:
    with open(panes_file, "r", encoding="utf-8") as f:
        panes_data = json.load(f)
    if isinstance(panes_data, dict):
        candidate = panes_data.get("work_dir", repo_root)
        if isinstance(candidate, str) and candidate and os.path.isdir(candidate):
            work_dir = candidate
except (OSError, json.JSONDecodeError):
    pass

print(work_dir)
PY
}

work_dir="$repo_root"
panes_file="$repo_root/.yamibaito/panes${session_suffix}.json"
warning_dashboard_file="$repo_root/dashboard.md"
if [ -f "$panes_file" ]; then
  resolved_work_dir=""
  read_attempt=0
  while [ "$read_attempt" -le "$READ_RETRY_MAX" ]; do
    if resolved_candidate="$(run_with_timeout "$READ_TIMEOUT" resolve_work_dir_with_python)"; then
      resolved_work_dir="$resolved_candidate"
      break
    fi

    read_status=$?
    emit_recovery_warning \
      "READ" \
      "work_dir resolve failed for $panes_file (attempt $((read_attempt + 1))/$((READ_RETRY_MAX + 1)), rc=$read_status)"
    if [ "$read_attempt" -lt "$READ_RETRY_MAX" ]; then
      sleep "$RETRY_INTERVAL_SECONDS"
    fi
    read_attempt=$((read_attempt + 1))
  done

  if [ -n "$resolved_work_dir" ]; then
    work_dir="$resolved_work_dir"
  elif [ "$read_attempt" -gt "$READ_RETRY_MAX" ]; then
    echo "error: [READ] retries exhausted for $panes_file; continue with repo_root=$repo_root" >&2
  fi
fi
warning_dashboard_file="$work_dir/dashboard.md"

run_collect_once() {
REPO_ROOT="$repo_root" SESSION_SUFFIX="$session_suffix" LOCK_TIMEOUT="$lock_timeout" SCRIPTS_DIR="$SCRIPTS_DIR" READ_RETRY_MAX="$READ_RETRY_MAX" READ_TIMEOUT="$READ_TIMEOUT" APPEND_RETRY_MAX="$APPEND_RETRY_MAX" APPEND_TIMEOUT="$APPEND_TIMEOUT" COLLECT_RETRY_MAX="$COLLECT_RETRY_MAX" COLLECT_TIMEOUT="$COLLECT_TIMEOUT" RETRY_INTERVAL_SECONDS="$RETRY_INTERVAL_SECONDS" python3 - <<'PY'
import atexit, datetime, errno, fcntl, json, os, re, shutil, signal, subprocess, sys, tempfile
try:
    import yaml
except ImportError:
    yaml = None

repo_root = os.environ["REPO_ROOT"]
session_suffix = os.environ.get("SESSION_SUFFIX", "")
scripts_dir_env = os.environ.get("SCRIPTS_DIR", "")

def _fallback_normalize_target_value(value):
    if value is None:
        return ""
    normalized = str(value).strip()
    if not normalized or normalized.lower() == "null":
        return ""
    return normalized

def _fallback_resolve_target(parent_cmd_id, task_id):
    parent = _fallback_normalize_target_value(parent_cmd_id)
    if parent:
        return parent

    task = _fallback_normalize_target_value(task_id)
    if task:
        return task

    return "unknown"

def _fallback_validate_feedback_entry(entry):
    if not isinstance(entry, dict):
        return False, ["feedback_entry"]

    missing_fields = [
        field for field in FALLBACK_REQUIRED_FEEDBACK_FIELDS if field not in entry
    ]
    if missing_fields:
        return False, missing_fields

    return True, []

resolve_target = _fallback_resolve_target
validate_feedback_entry = _fallback_validate_feedback_entry
FALLBACK_REQUIRED_FEEDBACK_FIELDS = (
    "datetime",
    "role",
    "target",
    "issue",
    "root_cause",
    "action",
    "expected_metric",
    "evidence",
)
REQUIRED_FEEDBACK_FIELDS = FALLBACK_REQUIRED_FEEDBACK_FIELDS

config_file = os.path.join(repo_root, ".yamibaito/config.yaml")
panes_file = os.path.join(repo_root, f".yamibaito/panes{session_suffix}.json")

# 若衆の名前マッピングを読み込む（queue_dir 構築前に work_dir が必要）
worker_names = {}
panes_data = {}
if os.path.exists(panes_file):
    try:
        with open(panes_file, "r", encoding="utf-8") as f:
            panes_data = json.load(f)
            if not isinstance(panes_data, dict):
                panes_data = {}
            worker_names = panes_data.get("worker_names", {})
            if not isinstance(worker_names, dict):
                worker_names = {}
    except (json.JSONDecodeError, OSError):
        pass

work_dir = panes_data.get("work_dir", repo_root) if panes_data else repo_root
if not isinstance(work_dir, str) or not work_dir or not os.path.isdir(work_dir):
    work_dir = repo_root

scripts_dir_candidates = []
for candidate in (
    scripts_dir_env,
    os.path.join(work_dir, "scripts"),
    os.path.join(repo_root, "scripts"),
):
    if not isinstance(candidate, str) or not candidate:
        continue
    normalized = os.path.abspath(candidate)
    if not os.path.isdir(normalized):
        continue
    if normalized not in scripts_dir_candidates:
        scripts_dir_candidates.append(normalized)

for candidate in reversed(scripts_dir_candidates):
    if candidate not in sys.path:
        sys.path.insert(0, candidate)

try:
    from lib.feedback import REQUIRED_FEEDBACK_FIELDS as imported_required_feedback_fields
    from lib.feedback import resolve_target as imported_resolve_target
    from lib.feedback import validate_feedback_entry as imported_validate_feedback_entry
except Exception:
    print(
        "warning: feedback helpers unavailable; feedback validation is skipped for this run.",
        file=sys.stderr,
    )
else:
    resolve_target = imported_resolve_target
    validate_feedback_entry = imported_validate_feedback_entry
    if isinstance(imported_required_feedback_fields, (list, tuple)):
        REQUIRED_FEEDBACK_FIELDS = tuple(imported_required_feedback_fields)

# queue_dir を work_dir ベースで構築（フォールバック: repo_root）
queue_dir = os.path.join(work_dir, ".yamibaito", f"queue{session_suffix}")
if not os.path.isdir(queue_dir):
    queue_dir = os.path.join(repo_root, ".yamibaito", f"queue{session_suffix}")
if not os.path.isdir(queue_dir):
    print(f"warning: queue dir not found: {queue_dir}", file=sys.stderr)
    sys.exit(0)  # 正常終了（queue 未作成はエラーではない）

# --- 排他制御 (fcntl.flock) ---
lock_timeout = int(os.environ.get("LOCK_TIMEOUT", "30"))
if lock_timeout < 0:
    print(f"error: --lock-timeout must be >= 0 (got {lock_timeout})", file=sys.stderr)
    sys.exit(1)
lock_file_path = os.path.join(queue_dir, ".collect.lock")
lock_fd = None
try:
    lock_fd = open(lock_file_path, "w")
    if lock_timeout > 0:
        timed_out = [False]
        def _alarm_handler(signum, frame):
            timed_out[0] = True
            raise OSError(errno.EAGAIN, "lock timeout")
        old_handler = signal.signal(signal.SIGALRM, _alarm_handler)
        signal.alarm(lock_timeout)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
        except OSError as e:
            if timed_out[0] or e.errno == errno.EAGAIN:
                print(f"error: collect lock acquisition timed out ({lock_timeout}s). Another collect may be running.", file=sys.stderr)
                sys.exit(2)
            raise
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, old_handler)
    elif lock_timeout == 0:
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (BlockingIOError, OSError) as e:
            if e.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                print("error: collect lock is held by another process (non-blocking mode, --lock-timeout 0).", file=sys.stderr)
                sys.exit(2)
            raise
except SystemExit:
    raise
except Exception as e:
    print(f"error: failed to acquire collect lock: {e}", file=sys.stderr)
    sys.exit(2)

atexit.register(lock_fd.close)
tasks_dir = os.path.join(queue_dir, "tasks")
reports_dir = os.path.join(queue_dir, "reports")
index_file = os.path.join(reports_dir, "_index.json")
try:
    os.makedirs(reports_dir, exist_ok=True)
except OSError as e:
    print(f"error: cannot create/access reports dir {reports_dir}: {e}", file=sys.stderr)
    sys.exit(1)
if not os.access(reports_dir, os.W_OK):
    print(f"error: reports dir is not writable: {reports_dir}", file=sys.stderr)
    sys.exit(1)

# queue_rel を work_dir 相対に変更（タスクプロンプトの相対パス用）
queue_rel = os.path.relpath(queue_dir, work_dir)

dashboard_file = os.path.join(work_dir, "dashboard.md")

def get_worker_display_name(worker_id):
    """worker_id から表示名を取得（名前があれば名前、なければ worker_id）"""
    name = worker_names.get(worker_id)
    if name:
        return f"{name}({worker_id})"
    return worker_id

def read_simple_kv(path, keys):
    data = {k: None for k in keys}
    if not os.path.exists(path):
        return data
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            stripped = line.strip()
            for k in keys:
                if stripped.startswith(f"{k}:"):
                    value = stripped.split(":", 1)[1].strip().strip('"')
                    data[k] = value
    return data

def normalize_text(value):
    if value is None:
        return None
    normalized = str(value).strip().strip('"').strip("'")
    if not normalized or normalized.lower() == "null":
        return None
    return normalized

def strip_inline_comment(value):
    if value is None:
        return None
    text = str(value)
    if " #" in text:
        text = text.split(" #", 1)[0]
    return text

def normalize_phase(value):
    phase = normalize_text(strip_inline_comment(value))
    if not phase:
        return "implement"
    return phase.lower()

def normalize_review_result(value):
    result = normalize_text(strip_inline_comment(value))
    if not result:
        return None
    lowered = result.lower()
    return lowered if lowered in ("approve", "rework") else None

_safe_log_token_pattern = re.compile(r"[^A-Za-z0-9_.:-]")

def sanitize_log_token(value, default="-"):
    normalized = normalize_text(value)
    if not normalized:
        return default
    sanitized = _safe_log_token_pattern.sub("_", normalized)
    return sanitized if sanitized else default

def format_review_result_for_display(value):
    if value is None:
        return "null"
    return str(value).strip().strip('"').strip("'")

def normalize_enabled_snapshot(value, default=True):
    normalized = normalize_text(value)
    if normalized is None:
        return default
    lowered = normalized.lower()
    if lowered in ("true", "yes", "1", "on"):
        return True
    if lowered in ("false", "no", "0", "off"):
        return False
    return default

def parse_non_negative_int(value, default=0):
    try:
        parsed = int(str(value).strip())
        if parsed >= 0:
            return parsed
    except (TypeError, ValueError):
        pass
    return default

def parse_yaml_list_block(path, key):
    items = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return items

    in_block = False
    base_indent = 0
    for raw_line in lines:
        line = raw_line.rstrip("\n")
        stripped = line.lstrip()
        indent = len(line) - len(stripped)

        if not in_block:
            if stripped == f"{key}:":
                in_block = True
                base_indent = indent
            continue

        if stripped and indent < base_indent:
            break
        if stripped.startswith("- "):
            item = normalize_text(stripped[2:])
            if item:
                items.append(item)

    return items

def parse_review_checklist_block(path):
    items = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return items

    in_block = False
    base_indent = 0
    current = None
    for raw_line in lines:
        line = raw_line.rstrip("\n")
        stripped = line.lstrip()
        indent = len(line) - len(stripped)

        if not in_block:
            if stripped == "review_checklist:":
                in_block = True
                base_indent = indent
            continue

        if stripped and indent < base_indent:
            break
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("- "):
            if current:
                items.append(current)
            current = {}
            inline_kv = stripped[2:].strip()
            if ":" in inline_kv:
                k, v = inline_kv.split(":", 1)
                current[k.strip()] = normalize_text(v)
            continue
        if current is not None and ":" in stripped:
            k, v = stripped.split(":", 1)
            current[k.strip()] = normalize_text(v)

    if current:
        items.append(current)
    return items

def parse_feedback_entries_block(path):
    entries = []
    malformed_count = 0
    has_feedback_field = False
    raw_feedback = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return has_feedback_field, raw_feedback, malformed_count

    in_block = False
    base_indent = 0
    current = None
    for raw_line in lines:
        line = raw_line.rstrip("\n")
        stripped = line.lstrip()
        indent = len(line) - len(stripped)

        if not in_block:
            if stripped.startswith("feedback:"):
                key, _, tail = stripped.partition(":")
                if key.strip() != "feedback":
                    continue
                has_feedback_field = True
                in_block = True
                base_indent = indent
                tail_value = tail.strip()
                if tail_value and tail_value != "[]":
                    malformed_count += 1
            continue

        if stripped and indent <= base_indent:
            break
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("- "):
            if current is not None:
                entries.append(current)
            current = {}
            inline_kv = stripped[2:].strip()
            if inline_kv:
                if ":" in inline_kv:
                    k, v = inline_kv.split(":", 1)
                    current[k.strip()] = normalize_text(v)
                else:
                    malformed_count += 1
                    current = None
            continue
        if current is not None and ":" in stripped:
            k, v = stripped.split(":", 1)
            current[k.strip()] = normalize_text(v)
        else:
            malformed_count += 1

    if current is not None:
        entries.append(current)

    return has_feedback_field, entries, malformed_count

def load_report_payload(path):
    if yaml is None:
        return None
    try:
        with open(path, "r", encoding="utf-8") as f:
            payload = yaml.safe_load(f) or {}
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    report_payload = payload.get("report", payload)
    return report_payload if isinstance(report_payload, dict) else None

def load_valid_feedback_entries(report_path, report, report_payload):
    entries = []
    valid_count = 0
    invalid_count = 0
    has_feedback_field = False
    raw_feedback = None

    if isinstance(report_payload, dict):
        has_feedback_field = "feedback" in report_payload
        raw_feedback = report_payload.get("feedback")
    else:
        has_feedback_field, parsed_feedback_entries, malformed_count = parse_feedback_entries_block(report_path)
        raw_feedback = parsed_feedback_entries
        invalid_count += malformed_count

    if raw_feedback is None and not has_feedback_field:
        return entries, valid_count, invalid_count, has_feedback_field

    if not isinstance(raw_feedback, list):
        invalid_count += 1
        report_name = os.path.basename(report_path) or report_path
        print(
            f"warning: feedback field skipped ({report_name}): feedback must be a list",
            file=sys.stderr,
        )
        return entries, valid_count, invalid_count, has_feedback_field

    normalized_target = resolve_target(report.get("parent_cmd_id"), report.get("task_id"))
    report_name = os.path.basename(report_path) or report_path

    for index, raw_entry in enumerate(raw_feedback, start=1):
        is_valid, missing_fields = validate_feedback_entry(raw_entry)
        if not is_valid:
            invalid_count += 1
            missing_names = [name for name in missing_fields if isinstance(name, str) and name]
            missing_summary = ", ".join(missing_names) if missing_names else "invalid_entry"
            print(
                f"warning: feedback entry skipped ({report_name}#{index}): missing {missing_summary}",
                file=sys.stderr,
            )
            continue

        entry = dict(raw_entry)
        entry["target"] = normalized_target
        entries.append(entry)
        valid_count += 1

    return entries, valid_count, invalid_count, has_feedback_field

def infer_gate_id(report):
    direct_gate_id = normalize_text(report.get("gate_id"))
    if direct_gate_id:
        return direct_gate_id
    review_target = normalize_text(report.get("review_target_task_id"))
    if review_target:
        return review_target
    task_id = normalize_text(report.get("task_id"))
    if not task_id:
        return "unknown"
    if re.search(r"_R\d+$", task_id):
        prefix = re.sub(r"_R\d+$", "", task_id)
        if prefix:
            return prefix
    return task_id

def summarize_rework_instructions(instructions, limit=100):
    if not instructions:
        return "修正指示なし"
    summary = " / ".join(instructions)
    summary = " ".join(summary.split())
    if len(summary) > limit:
        return summary[:limit - 3] + "..."
    return summary

def list_files(dir_path, suffix):
    if not os.path.isdir(dir_path):
        return []
    return [os.path.join(dir_path, f) for f in os.listdir(dir_path) if f.endswith(suffix)]

FEEDBACK_AUDIT_RELATIVE_PATHS = (
    ".yamibaito/feedback/global.md",
    ".yamibaito/feedback/waka.md",
    ".yamibaito/feedback/workers.md",
)
ENTRY_HEADER_PATTERN = re.compile(r"^\s*###\s+")
DIFF_HUNK_PATTERN = re.compile(r"^@@ -(\d+)(?:,\d+)? \+\d+(?:,\d+)? @@")

def build_required_field_patterns(required_fields):
    patterns = []
    for field_name in required_fields:
        if not isinstance(field_name, str):
            continue
        normalized = field_name.strip()
        if not normalized:
            continue
        patterns.append(re.compile(rf"^\s*(?:-\s*)?{re.escape(normalized)}\s*:"))
    return patterns

def extract_tampered_line_numbers(diff_text, required_field_patterns):
    line_numbers = []
    old_line_number = None
    for raw_line in diff_text.splitlines():
        if raw_line.startswith("@@"):
            match = DIFF_HUNK_PATTERN.match(raw_line)
            old_line_number = int(match.group(1)) if match else None
            continue
        if old_line_number is None:
            continue
        if raw_line.startswith("---") or raw_line.startswith("+++"):
            continue
        if raw_line.startswith("-"):
            removed_line = raw_line[1:]
            is_required_field = any(pattern.match(removed_line) for pattern in required_field_patterns)
            if ENTRY_HEADER_PATTERN.match(removed_line) or is_required_field:
                line_numbers.append(old_line_number)
            old_line_number += 1
            continue
        if raw_line.startswith("+"):
            continue
        old_line_number += 1
    return sorted(set(line_numbers))

def format_line_ranges(line_numbers):
    if not line_numbers:
        return "-"
    normalized_lines = sorted(set(line_numbers))
    ranges = []
    range_start = normalized_lines[0]
    range_end = normalized_lines[0]
    for line_number in normalized_lines[1:]:
        if line_number == range_end + 1:
            range_end = line_number
            continue
        if range_start == range_end:
            ranges.append(str(range_start))
        else:
            ranges.append(f"{range_start}-{range_end}")
        range_start = line_number
        range_end = line_number
    if range_start == range_end:
        ranges.append(str(range_start))
    else:
        ranges.append(f"{range_start}-{range_end}")
    return ",".join(ranges)

def detect_feedback_entry_tamper(candidate_roots):
    warnings = []
    git_bin = shutil.which("git")
    if not git_bin:
        warnings.append("warning: 改変検知をスキップしました（git コマンド未検出）。")
        return [], warnings

    unique_roots = []
    for candidate in candidate_roots:
        if not isinstance(candidate, str):
            continue
        normalized = os.path.abspath(candidate)
        if not os.path.isdir(normalized):
            continue
        if normalized not in unique_roots:
            unique_roots.append(normalized)

    git_root = None
    for candidate_root in unique_roots:
        inside_result = subprocess.run(
            [git_bin, "-C", candidate_root, "rev-parse", "--is-inside-work-tree"],
            capture_output=True,
            text=True,
            check=False,
        )
        if inside_result.returncode == 0 and inside_result.stdout.strip() == "true":
            git_root = candidate_root
            break

    if not git_root:
        warnings.append("warning: 改変検知をスキップしました（git 管理外ディレクトリ）。")
        return [], warnings

    head_result = subprocess.run(
        [git_bin, "-C", git_root, "rev-parse", "--verify", "HEAD^{commit}"],
        capture_output=True,
        text=True,
        check=False,
    )
    if head_result.returncode != 0:
        warnings.append("warning: 改変検知をスキップしました（git リポジトリ未初期化または HEAD 未確定）。")
        return [], warnings

    required_field_patterns = build_required_field_patterns(REQUIRED_FEEDBACK_FIELDS)
    findings = []
    for relative_path in FEEDBACK_AUDIT_RELATIVE_PATHS:
        diff_result = subprocess.run(
            [git_bin, "-C", git_root, "diff", "--no-color", "--unified=0", "HEAD", "--", relative_path],
            capture_output=True,
            text=True,
            check=False,
        )
        if diff_result.returncode != 0:
            warnings.append(
                f"warning: 改変検知をスキップしました（git diff 失敗: {relative_path}）。"
            )
            continue
        if not diff_result.stdout:
            continue
        tampered_lines = extract_tampered_line_numbers(diff_result.stdout, required_field_patterns)
        if tampered_lines:
            findings.append(
                {
                    "path": relative_path,
                    "line_numbers": tampered_lines,
                    "line_ranges": format_line_ranges(tampered_lines),
                }
            )

    return findings, warnings

def atomic_write_text(path, text):
    tmp_path = None
    target_dir = os.path.dirname(path) or "."
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=target_dir, delete=False) as tmp:
            tmp_path = tmp.name
            tmp.write(text)
            tmp.flush()
            os.fsync(tmp.fileno())
        os.replace(tmp_path, path)
    except Exception as e:
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        print(f"error: atomic write failed for {path}: {e}", file=sys.stderr)
        sys.exit(1)

def atomic_write_json(path, payload):
    tmp_path = None
    target_dir = os.path.dirname(path) or "."
    try:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", dir=target_dir, delete=False) as tmp:
            tmp_path = tmp.name
            json.dump(payload, tmp, ensure_ascii=False, indent=2)
            tmp.flush()
            os.fsync(tmp.fileno())
        os.replace(tmp_path, path)
    except Exception as e:
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
        print(f"error: atomic write failed for {path}: {e}", file=sys.stderr)
        sys.exit(1)

worker_count = 3
max_rework_loops = 3
if os.path.exists(config_file):
    with open(config_file, "r", encoding="utf-8") as f:
        for line in f:
            stripped = line.strip()
            if stripped.startswith("codex_count:"):
                worker_count = parse_non_negative_int(stripped.split(":", 1)[1], 3)
            elif stripped.startswith("max_rework_loops:"):
                max_rework_loops = parse_non_negative_int(stripped.split(":", 1)[1], 3)

tasks = []
idle_workers = []
for i in range(1, worker_count + 1):
    worker_id = f"worker_{i:03d}"
    task_path = os.path.join(tasks_dir, f"{worker_id}.yaml")
    task = read_simple_kv(task_path, ["task_id", "parent_cmd_id", "title", "assigned_to", "assigned_at", "status"])
    task["worker_id"] = worker_id
    if not task["task_id"] or task["task_id"] == "null":
        idle_workers.append(worker_id)
    else:
        tasks.append(task)

# 現在の cmd_id を特定し、その cmd 配下 task が全完了か判定
completion_statuses = {"done", "completed"}
task_candidates = []
for t in tasks:
    status = (t.get("status") or "").lower()
    parent_cmd_id = t.get("parent_cmd_id")
    if status == "idle":
        continue
    if not parent_cmd_id or parent_cmd_id == "null":
        continue
    task_candidates.append({
        "parent_cmd_id": parent_cmd_id,
        "status": status,
        "assigned_at": t.get("assigned_at") or "",
    })

current_cmd_id = None
all_tasks_completed_for_current_cmd = False
if task_candidates:
    active_tasks = [t for t in task_candidates if t["status"] in ("pending", "in_progress")]
    if active_tasks:
        current_cmd_id = max(active_tasks, key=lambda t: t["assigned_at"])["parent_cmd_id"]
    else:
        current_cmd_id = max(task_candidates, key=lambda t: t["assigned_at"])["parent_cmd_id"]
    current_cmd_tasks = [t for t in task_candidates if t["parent_cmd_id"] == current_cmd_id]
    all_tasks_completed_for_current_cmd = bool(current_cmd_tasks) and all(
        t["status"] in completion_statuses for t in current_cmd_tasks
    )

feedback_tamper_findings, feedback_tamper_warnings = detect_feedback_entry_tamper((work_dir, repo_root))
for tamper_warning in feedback_tamper_warnings:
    print(tamper_warning, file=sys.stderr)
for tamper_finding in feedback_tamper_findings:
    print(
        f"warning: [ENTRY_TAMPERED] 改変検知 {tamper_finding['path']} lines {tamper_finding['line_ranges']}",
        file=sys.stderr,
    )
feedback_tampered_count = len(feedback_tamper_findings)
feedback_tamper_summary = "; ".join(
    f"{finding['path']}:{finding['line_ranges']}" for finding in feedback_tamper_findings
)

reports = []
feedback_summary = {"valid": 0, "invalid": 0}
report_keys = [
    "worker_id",
    "task_id",
    "parent_cmd_id",
    "finished_at",
    "status",
    "summary",
    "notes",
    "persona",
    "phase",
    "loop_count",
    "review_result",
    "review_target_task_id",
    "gate_id",
    "enabled_snapshot",
    "skill_candidate_found",
    "skill_candidate_name",
    "skill_candidate_description",
    "skill_candidate_reason",
]
for report_path in list_files(reports_dir, "_report.yaml"):
    report = read_simple_kv(report_path, report_keys)
    report_payload = load_report_payload(report_path)
    if isinstance(report_payload, dict):
        for key in report_keys:
            if key in report_payload and report_payload[key] is not None:
                report[key] = report_payload[key]
        checklist = report_payload.get("review_checklist")
        if isinstance(checklist, list):
            report["review_checklist_items"] = [item for item in checklist if isinstance(item, dict)]
        else:
            report["review_checklist_items"] = []
        raw_instructions = report_payload.get("rework_instructions")
        if isinstance(raw_instructions, list):
            report["rework_instructions_items"] = [item for item in (normalize_text(v) for v in raw_instructions) if item]
        else:
            report["rework_instructions_items"] = []
        quality_gate_payload = report_payload.get("quality_gate")
        if isinstance(quality_gate_payload, dict) and quality_gate_payload.get("enabled_snapshot") is not None:
            report["enabled_snapshot"] = quality_gate_payload.get("enabled_snapshot")
        report["has_quality_gate_fields"] = any(
            k in report_payload
            for k in ("phase", "loop_count", "review_result", "review_checklist", "rework_instructions", "review_target_task_id", "gate_id")
        )
    else:
        report["review_checklist_items"] = []
        report["rework_instructions_items"] = []
        report["has_quality_gate_fields"] = False

    report["feedback_target"] = resolve_target(report.get("parent_cmd_id"), report.get("task_id"))
    feedback_entries, feedback_valid_count, feedback_invalid_count, feedback_has_field = load_valid_feedback_entries(
        report_path,
        report,
        report_payload,
    )
    report["feedback_entries"] = feedback_entries
    report["feedback_valid_count"] = feedback_valid_count
    report["feedback_invalid_count"] = feedback_invalid_count
    report["feedback_has_field"] = feedback_has_field
    report["feedback_missing"] = (not feedback_has_field) or (
        feedback_valid_count == 0 and feedback_invalid_count == 0
    )
    feedback_summary["valid"] += feedback_valid_count
    feedback_summary["invalid"] += feedback_invalid_count

    if not report["review_checklist_items"]:
        report["review_checklist_items"] = parse_review_checklist_block(report_path)
    if not report["rework_instructions_items"]:
        report["rework_instructions_items"] = parse_yaml_list_block(report_path, "rework_instructions")

    report["phase"] = normalize_phase(report.get("phase"))
    report["loop_count"] = parse_non_negative_int(report.get("loop_count"), 0)
    report["review_result_raw"] = report.get("review_result")
    report["review_result"] = normalize_review_result(report.get("review_result"))
    report["enabled_snapshot"] = normalize_enabled_snapshot(report.get("enabled_snapshot"), True)
    report["is_rework_repeat"] = (
        report.get("phase") == "review"
        and report.get("review_result") == "rework"
        and report.get("loop_count", 0) >= 2
    )
    report["error_code"] = "NONE"
    if feedback_tampered_count > 0:
        report["error_code"] = "ENTRY_TAMPERED"
    elif report.get("feedback_invalid_count", 0) > 0:
        report["error_code"] = "FEEDBACK_INVALID"
    elif report.get("feedback_missing"):
        report["error_code"] = "FEEDBACK_MISSING"
    elif report.get("is_rework_repeat"):
        report["error_code"] = "REWORK_REPEAT"

    print(
        "collect_log:"
        f" cmd_id={sanitize_log_token(report.get('parent_cmd_id'), 'unknown')}"
        f" task_id={sanitize_log_token(report.get('task_id'), 'unknown')}"
        f" phase={sanitize_log_token(report.get('phase'), 'implement')}"
        f" loop_count={parse_non_negative_int(report.get('loop_count'), 0)}"
        f" error_code={report.get('error_code')}"
        f" feedback_valid={parse_non_negative_int(report.get('feedback_valid_count'), 0)}"
        f" feedback_invalid={parse_non_negative_int(report.get('feedback_invalid_count'), 0)}",
        file=sys.stderr,
    )

    if not report["has_quality_gate_fields"]:
        report["has_quality_gate_fields"] = bool(
            report["review_checklist_items"]
            or report["rework_instructions_items"]
            or report["review_result"] is not None
            or normalize_text(report.get("review_target_task_id"))
            or normalize_text(report.get("gate_id"))
            or report["loop_count"] > 0
            or report["phase"] == "review"
        )
    report["path"] = report_path
    reports.append(report)

attention = []
done = []
skill_candidates = []
quality_gate_summary = {"review_waiting": 0, "approve": 0, "rework": 0, "invalid": 0, "escalation": 0}
feedback_health_summary = {
    "missing": 0,
    "invalid": 0,
    "rework_repeat": 0,
    "entry_tampered_count": feedback_tampered_count,
}
review_checklist_counts = {}
implemented_gate_ids = set()
reviewed_gate_ids = set()
rework_repeat_gate_ids = set()
quality_gate_rework_lines = []
quality_gate_invalid_lines = []
quality_gate_escalation_lines = []
feedback_invalid_lines = []
feedback_tamper_attention_lines = []
completed_worker_ids = set()  # 完了した若衆のID（タスクファイルリセット用）
for r in reports:
    status = str(r.get("status") or "").lower()
    notes = r.get("notes")
    if status in ("blocked", "failed") or (notes and notes not in ("null", "")):
        attention.append(r)
    # 防御的コーディング: "done" と "completed" の両方を完了として扱う
    if status in ("done", "completed"):
        done.append(r)
        worker_id = r.get("worker_id")
        if worker_id:
            completed_worker_ids.add(worker_id)
    found = str(r.get("skill_candidate_found") or "").lower() == "true"
    if found and r.get("skill_candidate_name"):
        skill_candidates.append(r)
    invalid_feedback_count = int(r.get("feedback_invalid_count") or 0)
    if r.get("feedback_missing"):
        feedback_health_summary["missing"] += 1
    if invalid_feedback_count > 0:
        feedback_health_summary["invalid"] += 1
        feedback_invalid_lines.append(
            f"- [{r.get('feedback_target')}] ⚠️ feedback無効エントリ {invalid_feedback_count}件をスキップ "
            f"(worker: {r.get('worker_id') or '-'})"
        )

    gate_id = infer_gate_id(r)
    if (
        status in completion_statuses
        and r.get("phase") == "implement"
        and r.get("has_quality_gate_fields")
        and r.get("enabled_snapshot")
    ):
        implemented_gate_ids.add(gate_id)

    for checklist_item in r.get("review_checklist_items", []):
        if not isinstance(checklist_item, dict):
            continue
        item_id = normalize_text(checklist_item.get("item_id")) or "unknown"
        result = (normalize_text(checklist_item.get("result")) or "").lower()
        if result not in ("ok", "ng"):
            continue
        item_counter = review_checklist_counts.setdefault(item_id, {"ok": 0, "ng": 0})
        item_counter[result] += 1

    review_result = r.get("review_result")
    review_result_raw = r.get("review_result_raw")
    loop_count = r.get("loop_count", 0)
    if r.get("phase") == "review":
        if review_result == "approve":
            quality_gate_summary["approve"] += 1
            reviewed_gate_ids.add(gate_id)
        elif review_result == "rework":
            reviewed_gate_ids.add(gate_id)
            if r.get("is_rework_repeat"):
                rework_repeat_gate_ids.add(gate_id)
            if loop_count >= max_rework_loops:
                quality_gate_summary["escalation"] += 1
                quality_gate_escalation_lines.append(f"- [{gate_id}] エスカレーション: {loop_count}回差し戻し上限超過")
            else:
                quality_gate_summary["rework"] += 1
                quality_gate_rework_lines.append(
                    f"- [{gate_id}] rework (loop {loop_count}): {summarize_rework_instructions(r.get('rework_instructions_items') or [])}"
                )
        else:
            quality_gate_summary["invalid"] += 1
            quality_gate_invalid_lines.append(
                f"- [{gate_id}] ⚠️ 不正な review_result: '{format_review_result_for_display(review_result_raw)}' (worker: {r.get('worker_id') or '-'})"
            )

quality_gate_summary["review_waiting"] = len(implemented_gate_ids - reviewed_gate_ids)
feedback_health_summary["rework_repeat"] = len(rework_repeat_gate_ids)
if feedback_tampered_count > 0:
    target_pairs = []
    seen_target_pairs = set()
    for report in reports:
        cmd_id = normalize_text(report.get("parent_cmd_id")) or "unknown"
        task_id = normalize_text(report.get("task_id")) or "unknown"
        key = (cmd_id, task_id)
        if key in seen_target_pairs:
            continue
        seen_target_pairs.add(key)
        target_pairs.append(key)
    if not target_pairs:
        target_pairs.append((normalize_text(current_cmd_id) or "unknown", "unknown"))
    for cmd_id, task_id in target_pairs:
        feedback_tamper_attention_lines.append(
            f"- [{cmd_id}/{task_id}] ⚠️ ENTRY_TAMPERED: {feedback_tamper_summary}"
        )

now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M")
plan_root = os.path.join(work_dir, ".yamibaito", "plan")
latest_plan_dir = None
if os.path.isdir(plan_root):
    plan_dirs = sorted(
        [d for d in os.listdir(plan_root) if os.path.isdir(os.path.join(plan_root, d))],
        reverse=True,
    )
    if plan_dirs:
        latest_plan_dir = os.path.join(plan_root, plan_dirs[0])

lines = []
lines.append("# 📊 組の進捗")
lines.append(f"最終更新: {now}")
lines.append("")
if latest_plan_dir:
    prd_path = os.path.join(latest_plan_dir, "PRD.md")
    spec_path = os.path.join(latest_plan_dir, "SPEC.md")
    tasks_yaml_path = os.path.join(latest_plan_dir, "tasks.yaml")
    review_report_path = os.path.join(latest_plan_dir, "plan_review_report.md")

    lines.append("## 📋 Plan Outputs")
    lines.append(f"- 最新Plan: `{os.path.relpath(latest_plan_dir, work_dir)}`")
    for label, path in (("PRD.md", prd_path), ("SPEC.md", spec_path), ("tasks.yaml", tasks_yaml_path)):
        if os.path.exists(path):
            rel_path = os.path.relpath(path, work_dir)
            lines.append(f"- ✅ {label}: [{rel_path}]({rel_path})")
        else:
            lines.append(f"- ❌ {label}: なし")
    lines.append("")

    review_status = "未レビュー"
    fail_reasons = []
    if os.path.exists(review_report_path):
        try:
            with open(review_report_path, "r", encoding="utf-8") as f:
                review_content = f.read()
            if "Result: PASS" in review_content:
                review_status = "Pass ✅"
            elif "Result: FAIL" in review_content:
                review_status = "Fail ❌"
                in_reasons = False
                for line in review_content.splitlines():
                    stripped = line.strip()
                    if "Fail reasons:" in stripped:
                        in_reasons = True
                        continue
                    if in_reasons and stripped.startswith("- "):
                        fail_reasons.append(stripped)
                    elif in_reasons and stripped.startswith("## "):
                        break
        except OSError:
            pass

    lines.append("## 🏥 Plan Health")
    lines.append(f"- レビュー結果: {review_status}")
    if review_status == "Fail ❌":
        if fail_reasons:
            lines.extend(fail_reasons)
        else:
            lines.append("- Fail reasons: (抽出できませんでした)")
    lines.append("")

    questions = []
    if os.path.exists(prd_path):
        try:
            with open(prd_path, "r", encoding="utf-8") as f:
                prd_lines = f.readlines()
            in_oq_section = False
            for line in prd_lines:
                stripped = line.strip()
                if stripped.startswith("## Open Questions") or stripped.startswith("## 未決事項"):
                    in_oq_section = True
                    continue
                if in_oq_section and stripped.startswith("## "):
                    break
                if in_oq_section and stripped.startswith("- "):
                    questions.append(stripped)
        except OSError:
            pass

    lines.append("## ❓ Open Questions")
    lines.append(f"- {len(questions)}件の未決事項")
    if questions:
        lines.extend(questions)
    else:
        lines.append("- なし")
    lines.append("")

    lines.append("## 📊 Task Summary")
    tasks_list = None
    try:
        import yaml

        with open(tasks_yaml_path, "r", encoding="utf-8") as f:
            task_data = yaml.safe_load(f) or {}
        if isinstance(task_data, dict):
            raw_tasks = task_data.get("tasks", [])
            if isinstance(raw_tasks, list):
                tasks_list = raw_tasks
            else:
                tasks_list = []
        else:
            tasks_list = []
    except ImportError:
        tasks_list = None
    except Exception:
        tasks_list = None

    if tasks_list is None:
        lines.append("- YAML parse 不可")
    else:
        lines.append(f"- 総タスク数: {len(tasks_list)}件")
        owner_counts = {}
        unassigned = 0
        for task in tasks_list:
            owner = ""
            if isinstance(task, dict):
                raw_owner = task.get("owner")
                if raw_owner is None:
                    raw_owner = task.get("assigned_to")
                if raw_owner is not None:
                    owner = str(raw_owner).strip()
            if owner:
                owner_counts[owner] = owner_counts.get(owner, 0) + 1
            else:
                unassigned += 1
        if owner_counts:
            for owner, count in sorted(owner_counts.items()):
                lines.append(f"- owner `{owner}`: {count}件")
        else:
            lines.append("- owner別: なし")
        if unassigned:
            lines.append(f"- ⚠️ 未割当 {unassigned}件")
    lines.append("")

lines.append("## 品質ゲート")
lines.append("| 状態 | 件数 |")
lines.append("|---|---|")
lines.append(f"| レビュー待ち | {quality_gate_summary['review_waiting']} |")
lines.append(f"| approve | {quality_gate_summary['approve']} |")
lines.append(f"| rework | {quality_gate_summary['rework']} |")
lines.append(f"| invalid | {quality_gate_summary['invalid']} |")
lines.append(f"| エスカレーション | {quality_gate_summary['escalation']} |")
lines.append("")
lines.append("### feedback 健全性")
lines.append("| 指標 | 件数 |")
lines.append("|---|---:|")
lines.append(f"| 未追記 | {feedback_health_summary['missing']} |")
lines.append(f"| 形式不正 | {feedback_health_summary['invalid']} |")
lines.append(f"| rework再発 | {feedback_health_summary['rework_repeat']} |")
lines.append(f"| entry_tampered_count | {feedback_health_summary['entry_tampered_count']} |")
lines.append("")
lines.append("### feedback 集計")
lines.append("| 種別 | 件数 |")
lines.append("|---|---:|")
lines.append(f"| 有効 | {feedback_summary['valid']} |")
lines.append(f"| 無効（スキップ） | {feedback_summary['invalid']} |")
if review_checklist_counts:
    lines.append("")
    lines.append("### review_checklist 集計")
    lines.append("| 項目 | ok | ng |")
    lines.append("|---|---:|---:|")
    for item_id in sorted(review_checklist_counts):
        counts = review_checklist_counts[item_id]
        lines.append(f"| {item_id} | {counts['ok']} | {counts['ng']} |")
lines.append("")

lines.append("## 🚨 親分の裁き待ち（判断が必要）")
attention_lines = []
for r in attention:
    notes = r.get("notes")
    line = f"- {r.get('task_id')} ({r.get('status')}) {notes or ''}".strip()
    attention_lines.append(line)
attention_lines.extend(quality_gate_invalid_lines)
attention_lines.extend(quality_gate_rework_lines)
attention_lines.extend(quality_gate_escalation_lines)
attention_lines.extend(feedback_tamper_attention_lines)
attention_lines.extend(feedback_invalid_lines)
if attention_lines:
    lines.extend(attention_lines)
else:
    lines.append("なし")
lines.append("")
lines.append("## 🔄 シノギ中（進行中）")
lines.append("| 件 | 内容 | 優先 | 状態 | 担当 | 開始 |")
lines.append("|----|------|------|------|------|------|")
if tasks:
    for t in tasks:
        status = t.get("status") or "assigned"
        title = t.get("title") or "-"
        started = t.get("assigned_at") or "-"
        worker_display = get_worker_display_name(t.get("worker_id"))
        lines.append(f"| {t.get('task_id')} | {title} | - | {status} | {worker_display} | {started} |")
else:
    lines.append("| - | - | - | - | - | - |")
lines.append("")
lines.append("## ✅ ケリがついた（完了・本日）")
lines.append("| 時刻 | 件 | 担当 | 結果 |")
lines.append("|------|----|------|------|")
if done:
    for r in done:
        worker_display = get_worker_display_name(r.get("worker_id"))
        lines.append(f"| {r.get('finished_at') or '-'} | {r.get('task_id')} | {worker_display} | {r.get('summary') or '-'} |")
else:
    lines.append("| - | - | - | - |")
lines.append("")
lines.append("## 💡 仕組み化のタネ（任意）")
if skill_candidates:
    for r in skill_candidates:
        name = r.get("skill_candidate_name")
        desc = r.get("skill_candidate_description") or ""
        reason = r.get("skill_candidate_reason") or ""
        lines.append(f"- {name}: {desc} ({reason})")
else:
    lines.append("なし")
lines.append("")
lines.append("## ⏸️ 待機所（任意）")
if idle_workers:
    for w in idle_workers:
        lines.append(f"- {get_worker_display_name(w)}")
else:
    lines.append("なし")
lines.append("")
lines.append("## ❓ メモ（任意）")
lines.append("なし")
lines.append("")

atomic_write_text(dashboard_file, "\n".join(lines))

# 完了した若衆のタスクファイルをリセット（シノギ中から消すため）
IDLE_TASK_TEMPLATE = """schema_version: 1
task:
  task_id: null
  parent_cmd_id: null
  assigned_to: "{worker_id}"
  assigned_at: ""
  status: idle

  title: ""
  description: ""
  repo_root: "."
  persona: ""

  constraints:
    allowed_paths: []
    forbidden_paths: []
    deliverables: []
    shared_files_policy: warn
    tests_policy: none

  codex:
    mode: exec_stdin
    sandbox: workspace-write
    approval: on-request
    model: default
    web_search: false

  prompt: |
    あなたはこのYAMLに書かれているタスクを実行する。
    まずこのファイルを読み、taskの内容と制約を理解すること。

    ルール:
    - 共有ファイルは原則避ける。必要なら触ってよいが、必ずレポートで明記。
    - テストは原則実行しない（必要なら提案だけ）。
    - 指示されていない範囲のリファクタや整形はしない。
    - persona が指定されていれば、その専門家として作業する。

    作業が終わったら、以下のレポート形式で
    `{queue_rel}/reports/{worker_id}_report.yaml` を更新すること。
    summary は1行で簡潔に書くこと。
    persona を使った場合は report.persona に記載すること。
"""

for worker_id in completed_worker_ids:
    task_path = os.path.join(tasks_dir, f"{worker_id}.yaml")
    if os.path.exists(task_path):
        atomic_write_text(task_path, IDLE_TASK_TEMPLATE.format(worker_id=worker_id, queue_rel=queue_rel))

index_payload = {"processed_reports": []}
for r in reports:
    try:
        stat = os.stat(r["path"])
        index_payload["processed_reports"].append({
            "path": r["path"],
            "mtime": stat.st_mtime,
        })
    except FileNotFoundError:
        pass

atomic_write_json(index_file, index_payload)

# dashboard 更新とは分離し、全完了時のみ親分へ報告
if current_cmd_id and all_tasks_completed_for_current_cmd:
    session = panes_data.get("session")
    oyabun = panes_data.get("oyabun")
    if session and oyabun:
        notify = (
            f"collect complete: {current_cmd_id} の全taskが done/completed。"
            f" {work_dir}/dashboard.md を更新しました。"
        )
        try:
            subprocess.run(["tmux", "send-keys", "-t", f"{session}:{oyabun}", notify], check=False)
            subprocess.run(["tmux", "send-keys", "-t", f"{session}:{oyabun}", "Enter"], check=False)
        except (FileNotFoundError, OSError) as e:
            print(f"warning: failed to send tmux notification: {e}", file=sys.stderr)
PY
}

collect_succeeded=0
collect_attempt=0
while [ "$collect_attempt" -le "$COLLECT_RETRY_MAX" ]; do
  if run_with_timeout "$COLLECT_TIMEOUT" run_collect_once; then
    collect_succeeded=1
    break
  fi

  collect_status=$?
  emit_recovery_warning \
    "COLLECT" \
    "collect failed (attempt $((collect_attempt + 1))/$((COLLECT_RETRY_MAX + 1)), rc=$collect_status)"
  if [ "$collect_attempt" -lt "$COLLECT_RETRY_MAX" ]; then
    sleep "$RETRY_INTERVAL_SECONDS"
  fi
  collect_attempt=$((collect_attempt + 1))
done

if [ "$collect_succeeded" -ne 1 ]; then
  echo "error: [COLLECT] retries exhausted; continue without blocking other workers." >&2
fi

flush_recovery_warnings_to_dashboard "$warning_dashboard_file"

if [ "$collect_succeeded" -eq 1 ]; then
  echo "yb collect: dashboard updated at $work_dir"
else
  echo "yb collect: collect warnings recorded at $work_dir"
fi
