#!/bin/bash
set -euo pipefail

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

REPO_ROOT="$repo_root" python3 - <<'PY'
import os, json, datetime

repo_root = os.environ["REPO_ROOT"]
config_file = os.path.join(repo_root, ".yamibaito/config.yaml")
tasks_dir = os.path.join(repo_root, ".yamibaito/queue/tasks")
reports_dir = os.path.join(repo_root, ".yamibaito/queue/reports")
dashboard_file = os.path.join(repo_root, "dashboard.md")
index_file = os.path.join(reports_dir, "_index.json")

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
for r in reports:
    status = (r.get("status") or "").lower()
    notes = r.get("notes")
    if status in ("blocked", "failed") or (notes and notes not in ("null", "")):
        attention.append(r)
    if status == "done":
        done.append(r)
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
        lines.append(f"| {t.get('task_id')} | {title} | - | {status} | {t.get('worker_id')} | {started} |")
else:
    lines.append("| - | - | - | - | - | - |")
lines.append("")
lines.append("## ✅ ケリがついた（完了・本日）")
lines.append("| 時刻 | 件 | 結果 |")
lines.append("|------|----|------|")
if done:
    for r in done:
        lines.append(f"| {r.get('finished_at') or '-'} | {r.get('task_id')} | {r.get('summary') or '-'} |")
else:
    lines.append("| - | - | - |")
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
        lines.append(f"- {w}")
else:
    lines.append("なし")
lines.append("")
lines.append("## ❓ メモ（任意）")
lines.append("なし")
lines.append("")

with open(dashboard_file, "w", encoding="utf-8") as f:
    f.write("\n".join(lines))

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
