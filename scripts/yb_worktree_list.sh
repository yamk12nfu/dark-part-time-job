#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

if ! command -v git-gtr &>/dev/null; then
  echo "gtr が見つかりません。" >&2
  exit 1
fi

REPO_ROOT="$repo_root" ORCH_ROOT="$ORCH_ROOT" python3 - <<'PY'
import glob, os, subprocess, sys

_orch = os.environ.get("ORCH_ROOT", "")
if _orch:
    sys.path.insert(0, os.path.join(_orch, "scripts"))
try:
    from lib.panes import load_panes
except ModuleNotFoundError as _exc:
    print(f"error: {_exc} — ORCH_ROOT={_orch!r}/scripts/lib/panes.py を確認してください", file=sys.stderr)
    sys.exit(1)

repo_root = os.environ["REPO_ROOT"]
yamibaito_dir = os.path.join(repo_root, ".yamibaito")

# panes*.json からセッション情報を収集
sessions = {}
for panes_path in glob.glob(os.path.join(yamibaito_dir, "panes*.json")):
    try:
        data = load_panes(panes_path)
        worktree = data.get("worktree", {})
        enabled = worktree.get("enabled", False)
        root = worktree.get("root", "")
        branch = worktree.get("branch", "")
        if enabled:
            if not branch:
                continue
            session_key = f"branch:{branch}"
            display_branch = branch
        else:
            session_name = data.get("session", "")
            session_key = f"session:{session_name or os.path.basename(panes_path)}"
            display_branch = "-"
        sessions[session_key] = {
            "session": data.get("session", ""),
            "branch": display_branch,
            "worktree_root": root,
            "work_dir": data.get("work_dir", ""),
        }
    except (OSError, KeyError, TypeError):
        pass

# gtr list を取得
try:
    raw = subprocess.check_output(
        ["git", "-C", repo_root, "gtr", "list", "--porcelain"],
        text=True, stderr=subprocess.DEVNULL,
    ).strip()
except (subprocess.CalledProcessError, FileNotFoundError):
    raw = ""

gtr_branches = set()
gtr_paths = {}
if raw:
    for line in raw.splitlines():
        line = line.strip()
        if line:
            parts = line.split("\t")
            if len(parts) >= 2:
                wt_path = parts[0].strip() or "-"
                branch = parts[1].strip()
            else:
                wt_path = "-"
                branch = line
            if branch:
                gtr_branches.add(branch)
                gtr_paths[branch] = wt_path

# テーブル表示
print(f"{'SESSION':<30} {'BRANCH':<30} {'WORKTREE PATH':<50} {'STATUS'}")
print("-" * 120)

# panes に記録されているセッション
printed = set()
for info in sessions.values():
    session_name = info["session"]
    branch = info["branch"]
    wt_path = info.get("worktree_root") or info.get("work_dir") or "-"
    # tmux セッションの存在確認
    try:
        subprocess.check_output(
            ["tmux", "has-session", "-t", session_name],
            stderr=subprocess.DEVNULL,
        )
        status = "active"
    except (subprocess.CalledProcessError, FileNotFoundError):
        status = "stopped"
    print(f"{session_name:<30} {branch:<30} {wt_path:<50} {status}")
    if branch != "-":
        printed.add(branch)

# gtr にあるが panes に記録されていない worktree
for branch in sorted(gtr_branches):
    if branch not in printed:
        wt_path = gtr_paths.get(branch, "-")
        if wt_path == "-":
            try:
                wt_path = subprocess.check_output(
                    ["git", "-C", repo_root, "gtr", "go", branch],
                    text=True, stderr=subprocess.DEVNULL,
                ).strip()
            except (subprocess.CalledProcessError, FileNotFoundError):
                wt_path = "-"
        print(f"{'(unknown)':<30} {branch:<30} {wt_path:<50} {'orphaned'}")
PY
