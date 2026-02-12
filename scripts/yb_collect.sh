#!/bin/bash
set -euo pipefail

repo_root="."
session_id=""
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

REPO_ROOT="$repo_root" SESSION_SUFFIX="$session_suffix" python3 - <<'PY'
import os, json, datetime, subprocess, sys

repo_root = os.environ["REPO_ROOT"]
session_suffix = os.environ.get("SESSION_SUFFIX", "")
config_file = os.path.join(repo_root, ".yamibaito/config.yaml")
queue_dir = os.path.join(repo_root, f".yamibaito/queue{session_suffix}")
tasks_dir = os.path.join(queue_dir, "tasks")
reports_dir = os.path.join(queue_dir, "reports")
index_file = os.path.join(reports_dir, "_index.json")
panes_file = os.path.join(repo_root, f".yamibaito/panes{session_suffix}.json")
queue_rel = os.path.relpath(queue_dir, repo_root)

# 若衆の名前マッピングを読み込む（worker_001 -> "銀次" など）
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

def list_files(dir_path, suffix):
    if not os.path.isdir(dir_path):
        return []
    return [os.path.join(dir_path, f) for f in os.listdir(dir_path) if f.endswith(suffix)]

worker_count = 3
if os.path.exists(config_file):
    with open(config_file, "r", encoding="utf-8") as f:
        for line in f:
            if line.strip().startswith("codex_count:"):
                worker_count = int(line.split(":", 1)[1].strip())
                break

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
for report_path in list_files(reports_dir, "_report.yaml"):
    report = read_simple_kv(report_path, [
        "worker_id",
        "task_id",
        "parent_cmd_id",
        "finished_at",
        "status",
        "summary",
        "notes",
        "persona",
        "skill_candidate_found",
        "skill_candidate_name",
        "skill_candidate_description",
        "skill_candidate_reason",
    ])
    report["path"] = report_path
    reports.append(report)

attention = []
done = []
skill_candidates = []
completed_worker_ids = set()  # 完了した若衆のID（タスクファイルリセット用）
for r in reports:
    status = (r.get("status") or "").lower()
    notes = r.get("notes")
    if status in ("blocked", "failed") or (notes and notes not in ("null", "")):
        attention.append(r)
    # 防御的コーディング: "done" と "completed" の両方を完了として扱う
    if status in ("done", "completed"):
        done.append(r)
        worker_id = r.get("worker_id")
        if worker_id:
            completed_worker_ids.add(worker_id)
    found = (r.get("skill_candidate_found") or "").lower() == "true"
    if found and r.get("skill_candidate_name"):
        skill_candidates.append(r)

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

lines.append("## 🚨 親分の裁き待ち（判断が必要）")
if attention:
    for r in attention:
        notes = r.get("notes")
        line = f"- {r.get('task_id')} ({r.get('status')}) {notes or ''}".strip()
        lines.append(line)
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

with open(dashboard_file, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))

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
        with open(task_path, "w", encoding="utf-8") as f:
            f.write(IDLE_TASK_TEMPLATE.format(worker_id=worker_id, queue_rel=queue_rel))

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

with open(index_file, "w", encoding="utf-8") as f:
    json.dump(index_payload, f, ensure_ascii=False, indent=2)

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
