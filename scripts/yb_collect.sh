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

REPO_ROOT="$repo_root" SESSION_SUFFIX="$session_suffix" python3 - <<'PY'
import os, json, datetime

repo_root = os.environ["REPO_ROOT"]
session_suffix = os.environ.get("SESSION_SUFFIX", "")
config_file = os.path.join(repo_root, ".yamibaito/config.yaml")
queue_dir = os.path.join(repo_root, f".yamibaito/queue{session_suffix}")
tasks_dir = os.path.join(queue_dir, "tasks")
reports_dir = os.path.join(queue_dir, "reports")
dashboard_file = os.path.join(repo_root, "dashboard.md")
index_file = os.path.join(reports_dir, "_index.json")
panes_file = os.path.join(repo_root, f".yamibaito/panes{session_suffix}.json")
queue_rel = os.path.relpath(queue_dir, repo_root)

# 若衆の名前マッピングを読み込む（worker_001 -> "銀次" など）
worker_names = {}
if os.path.exists(panes_file):
    try:
        with open(panes_file, "r", encoding="utf-8") as f:
            panes_data = json.load(f)
            worker_names = panes_data.get("worker_names", {})
    except (json.JSONDecodeError, KeyError):
        pass

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

lines = []
lines.append("# 📊 組の進捗")
lines.append(f"最終更新: {now}")
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
PY

echo "yb collect: dashboard updated at $repo_root"
