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

work_dir="$repo_root"
panes_file="$repo_root/.yamibaito/panes${session_suffix}.json"
if [ -f "$panes_file" ]; then
  resolved_work_dir="$(PANES_FILE="$panes_file" REPO_ROOT="$repo_root" python3 - <<'PY'
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
)"
  if [ -n "$resolved_work_dir" ]; then
    work_dir="$resolved_work_dir"
  fi
fi

REPO_ROOT="$repo_root" SESSION_SUFFIX="$session_suffix" LOCK_TIMEOUT="$lock_timeout" python3 - <<'PY'
import atexit, datetime, errno, fcntl, json, os, re, signal, subprocess, sys, tempfile
try:
    import yaml
except ImportError:
    yaml = None

repo_root = os.environ["REPO_ROOT"]
session_suffix = os.environ.get("SESSION_SUFFIX", "")
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

def normalize_phase(value):
    phase = normalize_text(value)
    if not phase:
        return "implement"
    return phase.lower()

def normalize_review_result(value):
    result = normalize_text(value)
    if not result:
        return None
    lowered = result.lower()
    return lowered if lowered in ("approve", "rework") else None

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

reports = []
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

    if not report["review_checklist_items"]:
        report["review_checklist_items"] = parse_review_checklist_block(report_path)
    if not report["rework_instructions_items"]:
        report["rework_instructions_items"] = parse_yaml_list_block(report_path, "rework_instructions")

    report["phase"] = normalize_phase(report.get("phase"))
    report["loop_count"] = parse_non_negative_int(report.get("loop_count"), 0)
    report["review_result_raw"] = report.get("review_result")
    report["review_result"] = normalize_review_result(report.get("review_result"))
    report["enabled_snapshot"] = normalize_enabled_snapshot(report.get("enabled_snapshot"), True)
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
review_checklist_counts = {}
implemented_gate_ids = set()
reviewed_gate_ids = set()
quality_gate_rework_lines = []
quality_gate_invalid_lines = []
quality_gate_escalation_lines = []
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

echo "yb collect: dashboard updated at $work_dir"
