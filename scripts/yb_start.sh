#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ORCH_ROOT/scripts/yb_prompt_lib.sh"
source "$ORCH_ROOT/scripts/lib/agent_config_shell.sh"

repo_root="."
session_id=""
from_ref=""
no_worktree=false
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
    --from)
      from_ref="$2"
      shift 2
      ;;
    --no-worktree)
      no_worktree=true
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

repo_root="$(cd "$repo_root" && pwd)"
repo_name="$(basename "$repo_root" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_id="$(echo "$session_id" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_suffix=""
if [ -n "$session_id" ]; then
  session_suffix="_${session_id}"
fi
session_name="yamibaito_${repo_name}${session_suffix}"

config_file="$repo_root/.yamibaito/config.yaml"
if [ ! -f "$config_file" ]; then
  echo "Missing config: $config_file (run yb init)" >&2
  exit 1
fi

worker_count=$(agent_get_worker_count "$config_file")
if [ -z "$worker_count" ]; then
  worker_count=3
fi

# orchestrator 設定（未設定時: legacy / 5）
orch_mode=$(awk '
  /^[[:space:]]*orchestrator:[[:space:]]*$/ { in_orchestrator=1; next }
  in_orchestrator && /^[^[:space:]]/ { in_orchestrator=0 }
  in_orchestrator && /^[[:space:]]*mode:[[:space:]]*/ { print $2; exit }
' "$config_file" | tr -d '"' | tr -d "'" || true)
orch_poll_interval_sec=$(awk '
  /^[[:space:]]*orchestrator:[[:space:]]*$/ { in_orchestrator=1; next }
  in_orchestrator && /^[^[:space:]]/ { in_orchestrator=0 }
  in_orchestrator && /^[[:space:]]*poll_interval_sec:[[:space:]]*/ { print $2; exit }
' "$config_file" | tr -d '"' | tr -d "'" || true)
orch_mode="${orch_mode:-legacy}"
case "$orch_mode" in
  legacy|hybrid|v2) ;;
  *) orch_mode="legacy" ;;
esac
orch_poll_interval_sec="${orch_poll_interval_sec:-5}"
if ! [[ "$orch_poll_interval_sec" =~ ^[0-9]+$ ]]; then
  orch_poll_interval_sec=5
fi

# CLI binary preflight check
for _check_role in oyabun waka worker; do
  _cli_bin=$(agent_get_cli_binary "$config_file" "$_check_role")
  if [ -n "$_cli_bin" ] && ! command -v "$_cli_bin" &>/dev/null; then
    echo "ERROR: '$_cli_bin' が見つかりません。agents.$_check_role.cli で指定されたCLIをインストールしてください。" >&2
    exit 1
  fi
done

# === worktree 設定の読み取り ===
wt_enabled=$(grep -E "^\s*enabled:" "$config_file" | head -1 | awk '{print $2}' || true)
wt_default_base=$(grep -E "^\s*default_base:" "$config_file" | head -1 | awk '{print $2}' | tr -d '"' || true)
wt_branch_prefix=$(grep -E "^\s*branch_prefix:" "$config_file" | head -1 | awk '{print $2}' | tr -d '"' || true)
wt_enabled="${wt_enabled:-true}"
wt_branch_prefix="${wt_branch_prefix:-yamibaito}"

# === worktree 作成 ===
worktree_root=""
worktree_branch=""
work_dir="$repo_root"

if [ -n "$session_id" ] && [ "$no_worktree" = "false" ] && [ "$wt_enabled" = "true" ]; then
  # gtr 存在チェック
  if ! command -v git-gtr &>/dev/null; then
    echo "gtr が見つかりません。インストールしてください:" >&2
    echo "  git clone https://github.com/coderabbitai/git-worktree-runner.git" >&2
    echo "  cd git-worktree-runner && ./install.sh" >&2
    exit 1
  fi

  # base ブランチの決定
  if [ -n "$from_ref" ]; then
    base="$from_ref"
  elif [ -n "$wt_default_base" ]; then
    base="$wt_default_base"
  else
    base="$(git -C "$repo_root" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')"
    base="${base:-$(git -C "$repo_root" branch --show-current)}"
  fi

  worktree_branch="${wt_branch_prefix}/${session_id}"

  # 既存 worktree チェック（T9 統合: 再利用ロジック）
  if git -C "$repo_root" gtr list --porcelain 2>/dev/null | awk -F'\t' '{print $2}' | grep -qx "$worktree_branch"; then
    echo "既存 worktree を再利用: $worktree_branch"
    worktree_root="$(cd "$(git -C "$repo_root" gtr go "$worktree_branch")" && pwd)"
  else
    echo "worktree を作成: $worktree_branch (base: $base)"
    git -C "$repo_root" gtr new "$worktree_branch" --from "$base" --yes
    worktree_root="$(cd "$(git -C "$repo_root" gtr go "$worktree_branch")" && pwd)"
  fi

  work_dir="$worktree_root"
fi

if [ -n "$worktree_root" ]; then
  yamibaito_dir="$worktree_root/.yamibaito"

  # 旧方式の丸ごと symlink が残っていれば削除
  if [ -L "$yamibaito_dir" ]; then
    rm "$yamibaito_dir"
    echo "Removed legacy .yamibaito symlink"
  fi

  # 実ディレクトリを作成
  mkdir -p "$yamibaito_dir"

  # 個別 symlink を作成（config.yaml, prompts/, skills/, plan/, feedback/）
  for item in config.yaml prompts skills plan feedback; do
    target="$repo_root/.yamibaito/$item"
    link="$yamibaito_dir/$item"
    # 壊れた symlink が残っていれば除去
    if [ -L "$link" ] && [ ! -e "$link" ]; then
      rm "$link"
    fi
    if [ -e "$target" ] && [ ! -e "$link" ]; then
      ln -s "$target" "$link"
      echo "Linked .yamibaito/$item -> $target"
    fi
  done
fi

queue_dir="$work_dir/.yamibaito/queue${session_suffix}"
tasks_dir="$queue_dir/tasks"
reports_dir="$queue_dir/reports"
if [ -n "$session_id" ]; then
  mkdir -p "$tasks_dir" "$reports_dir"

  if [ ! -f "$queue_dir/director_to_planner.yaml" ]; then
    cp "$ORCH_ROOT/templates/queue/director_to_planner.yaml" "$queue_dir/director_to_planner.yaml"
  fi

  if [ ! -f "$reports_dir/_index.json" ]; then
    cat > "$reports_dir/_index.json" <<'EOF'
{"processed_reports":[]}
EOF
  fi

  for i in $(seq 1 "$worker_count"); do
    worker_id=$(printf "worker_%03d" "$i")
    task_file="$tasks_dir/${worker_id}.yaml"
    report_file="$reports_dir/${worker_id}_report.yaml"
    if [ ! -f "$task_file" ]; then
      cp "$ORCH_ROOT/templates/queue/tasks/worker_task.yaml" "$task_file"
      sed -i "" "s/{{WORKER_ID}}/${worker_id}/g" "$task_file"
      sed -i "" "s#\\.yamibaito/queue/#.yamibaito/queue${session_suffix}/#g" "$task_file"
    fi
    if [ ! -f "$report_file" ]; then
      cp "$ORCH_ROOT/templates/queue/reports/worker_report.yaml" "$report_file"
      sed -i "" "s/{{WORKER_ID}}/${worker_id}/g" "$report_file"
    fi
  done
fi

oyabun_prompt="$(resolve_prompt_path "$repo_root" "oyabun.md")" || { echo "ERROR: oyabun.md not found in $repo_root/.yamibaito/prompts/" >&2; exit 1; }
waka_prompt="$(resolve_prompt_path "$repo_root" "waka.md")" || { echo "ERROR: waka.md not found in $repo_root/.yamibaito/prompts/" >&2; exit 1; }

if tmux has-session -t "$session_name" 2>/dev/null; then
  echo "tmux session already exists: $session_name" >&2
  echo "Attach with: tmux attach -t $session_name" >&2
  exit 1
fi

tmux new-session -d -s "$session_name" -n main

# Layout:
# - left 50%: top 60% oyabun, bottom 40% waka
# - right 50%: workers stacked
tmux split-window -h -p 50 -t "$session_name":0

# Build right column workers by repeatedly splitting.
for i in $(seq 2 "$worker_count"); do
  tmux split-window -v -t "$session_name":0.1
done

# Split left column for oyabun (top) and waka (bottom).
tmux split-window -v -p 40 -t "$session_name":0.0

# 右側の若衆ペインを等分割にリサイズ
# 右カラムの総高さを取得し、worker_count で割って各ペインに適用
if [ "$worker_count" -gt 1 ]; then
  # 右側ペインの情報を収集
  right_pane_indices=()
  total_height=0
  while IFS=: read -r idx left height; do
    if [ "$left" -gt 0 ]; then
      right_pane_indices+=("$idx")
      total_height=$((total_height + height))
    fi
  done < <(tmux list-panes -t "$session_name":0 -F '#{pane_index}:#{pane_left}:#{pane_height}')
  
  if [ ${#right_pane_indices[@]} -gt 0 ]; then
    target_height=$((total_height / ${#right_pane_indices[@]}))
    # 最後のペイン以外をリサイズ（最後は残りを自動で埋める）
    count=${#right_pane_indices[@]}
    for ((j=0; j<count-1; j++)); do
      tmux resize-pane -t "$session_name":0."${right_pane_indices[$j]}" -y "$target_height" 2>/dev/null || true
    done
  fi
fi

pane_map="$repo_root/.yamibaito/panes${session_suffix}.json"

SESSION_NAME="$session_name" REPO_ROOT="$repo_root" WORKER_COUNT="$worker_count" PANE_MAP="$pane_map" WORKTREE_ROOT="$worktree_root" WORK_DIR="$work_dir" WORKTREE_BRANCH="$worktree_branch" QUEUE_DIR="$queue_dir" ORCH_ROOT="$ORCH_ROOT" python3 - <<'PY'
import os
import sys
import subprocess

ORCH_ROOT = os.environ.get("ORCH_ROOT", "")
if ORCH_ROOT:
    sys.path.insert(0, os.path.join(ORCH_ROOT, "scripts"))
try:
    from lib.panes import dump_panes_v2
except ModuleNotFoundError as _exc:
    print(f"error: {_exc} — ORCH_ROOT={ORCH_ROOT!r}/scripts/lib/panes.py を確認してください", file=sys.stderr)
    sys.exit(1)

session = os.environ["SESSION_NAME"]
repo_root = os.environ["REPO_ROOT"]
worktree_root = os.environ.get("WORKTREE_ROOT", "")
work_dir_val = os.environ.get("WORK_DIR", repo_root)
worktree_branch = os.environ.get("WORKTREE_BRANCH", "")
queue_dir_val = os.environ.get("QUEUE_DIR", "")
worker_count = int(os.environ["WORKER_COUNT"])
pane_map = os.environ["PANE_MAP"]
worker_names = [
    "銀次",
    "龍",
    "影",
    "蓮",
    "玄",
    "隼",
    "烈",
    "咲",
    "凪",
    "朔",
]

raw = subprocess.check_output(
    ["tmux", "list-panes", "-t", f"{session}:0", "-F", "#{pane_index} #{pane_left} #{pane_top} #{pane_height} #{pane_width}"],
    text=True,
)
panes = []
for line in raw.strip().splitlines():
    idx, left, top, height, width = line.split()
    panes.append({
        "index": int(idx),
        "left": int(left),
        "top": int(top),
        "height": int(height),
        "width": int(width),
    })

left_panes = [p for p in panes if p["left"] == 0]
right_panes = [p for p in panes if p["left"] != 0]

left_panes.sort(key=lambda p: p["top"])
right_panes.sort(key=lambda p: p["top"])

oyabun = left_panes[0]["index"] if left_panes else 0
waka = left_panes[1]["index"] if len(left_panes) > 1 else 0

workers = {}
worker_name_map = {}  # worker_001 -> "銀次" のマッピング
for i in range(worker_count):
    if i < len(right_panes):
        wid = f"worker_{i+1:03d}"
        workers[wid] = f"0.{right_panes[i]['index']}"
        if i < len(worker_names):
            worker_name_map[wid] = worker_names[i]

mapping = {
    "schema_version": 2,
    "session": session,
    "repo_root": repo_root,
    "worktree": {
        "enabled": bool(worktree_root or worktree_branch),
        "root": worktree_root,
        "branch": worktree_branch,
    },
    "work_dir": work_dir_val,
    "queue_dir": queue_dir_val,
    "oyabun": f"0.{oyabun}",
    "waka": f"0.{waka}",
    "workers": workers,
    "worker_names": worker_name_map,
}

dump_panes_v2(pane_map, mapping)

subprocess.run(["tmux", "select-pane", "-t", f"{session}:0.{oyabun}", "-T", "oyabun"], check=False)
subprocess.run(["tmux", "select-pane", "-t", f"{session}:0.{waka}", "-T", "waka"], check=False)
subprocess.run(["tmux", "select-pane", "-t", f"{session}:0.{oyabun}", "-P", "bg=#2f1b1b"], check=False)
subprocess.run(["tmux", "select-pane", "-t", f"{session}:0.{waka}", "-P", "bg=#1b2f2a"], check=False)

for name, pane in workers.items():
    try:
        idx = int(name.split("_")[1]) - 1
    except (IndexError, ValueError):
        idx = -1
    label = worker_names[idx] if 0 <= idx < len(worker_names) else name
    subprocess.run(["tmux", "select-pane", "-t", f"{session}:{pane}", "-T", label], check=False)
PY

# panes.json を worktree にも symlink（若衆が参照できるように）
if [ -n "$worktree_root" ]; then
  panes_link="$worktree_root/.yamibaito/panes${session_suffix}.json"
  # 壊れた symlink が残っていれば除去
  if [ -L "$panes_link" ] && [ ! -e "$panes_link" ]; then
    rm "$panes_link"
  fi
  if [ ! -e "$panes_link" ]; then
    ln -s "$pane_map" "$panes_link"
    echo "Linked panes${session_suffix}.json -> $pane_map"
  fi
fi

printf -v _q_boot_bin '%q' "$ORCH_ROOT/bin"
printf -v _q_boot_session_id '%q' "$session_id"
printf -v _q_boot_pane_map '%q' "$pane_map"
printf -v _q_boot_queue_dir '%q' "$queue_dir"
printf -v _q_boot_work_dir '%q' "$work_dir"
printf -v _q_boot_worktree_branch '%q' "$worktree_branch"
printf -v _q_boot_repo_root '%q' "$repo_root"
_bootstrap_cmd="export PATH=$_q_boot_bin:\$PATH && export YB_SESSION_ID=$_q_boot_session_id && export YB_PANES_PATH=$_q_boot_pane_map && export YB_QUEUE_DIR=$_q_boot_queue_dir && export YB_WORK_DIR=$_q_boot_work_dir && export YB_WORKTREE_BRANCH=$_q_boot_worktree_branch && export YB_REPO_ROOT=$_q_boot_repo_root && cd $_q_boot_work_dir && clear"
for pane in $(tmux list-panes -t "$session_name":0 -F "#{pane_index}"); do
  tmux send-keys -t "$session_name":0."$pane" "$_bootstrap_cmd" C-m
done

if [ "$orch_mode" = "hybrid" ] || [ "$orch_mode" = "v2" ]; then
  orch_split_target=$(PANE_MAP="$pane_map" python3 - <<'PY'
import json
import os

path = os.environ["PANE_MAP"]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
workers = data.get("workers") or {}
print(workers.get("worker_001") or data.get("waka") or data.get("oyabun") or "0.0")
PY
)
  orchestrator_pane=$(tmux split-window -v -P -F "#{window_index}.#{pane_index}" -t "$session_name:$orch_split_target" -c "$work_dir")
  tmux select-pane -t "$session_name:$orchestrator_pane" -T "orchestrator" 2>/dev/null || true

  python3 -c '
import json
import sys

path = sys.argv[1]
pane = sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)
data["orchestrator"] = pane
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
' "$pane_map" "$orchestrator_pane"

  _orch_state_dir="$work_dir/.yamibaito/runtime"
  _orch_state_file="$_orch_state_dir/orchestrator-state.json"
  mkdir -p "$_orch_state_dir"
  rm -f "$_orch_state_file"

  printf -v _q_orch_bin '%q' "$ORCH_ROOT/bin"
  printf -v _q_orch_session_id '%q' "$session_id"
  printf -v _q_orch_pane_map '%q' "$pane_map"
  printf -v _q_orch_queue_dir '%q' "$queue_dir"
  printf -v _q_orch_work_dir '%q' "$work_dir"
  printf -v _q_orch_repo_root '%q' "$repo_root"
  printf -v _q_orch_mode '%q' "$orch_mode"
  printf -v _q_orch_poll_interval '%q' "$orch_poll_interval_sec"
  printf -v _q_orch_state_dir '%q' "$_orch_state_dir"
  printf -v _q_orch_script '%q' "$work_dir/scripts/yb_orchestrator.py"
  _orch_cmd="export PATH=$_q_orch_bin:\$PATH && export YB_SESSION_ID=$_q_orch_session_id && export YB_PANES_PATH=$_q_orch_pane_map && export YB_QUEUE_DIR=$_q_orch_queue_dir && export YB_WORK_DIR=$_q_orch_work_dir && export YB_REPO_ROOT=$_q_orch_repo_root && cd $_q_orch_work_dir && python3 $_q_orch_script --repo $_q_orch_work_dir --session $_q_orch_session_id --mode $_q_orch_mode --poll-interval $_q_orch_poll_interval --state-dir $_q_orch_state_dir"
  tmux send-keys -t "$session_name:$orchestrator_pane" "$_orch_cmd"
  tmux send-keys -t "$session_name:$orchestrator_pane" C-m

  _orch_ready=false
  for _ in $(seq 1 10); do
    if [ -f "$_orch_state_file" ]; then
      _orch_ready=true
      break
    fi
    sleep 1
  done
  if [ "$_orch_ready" != "true" ]; then
    echo "WARNING: orchestrator readiness timeout (10s): $_orch_state_file" >&2
  fi
fi

oyabun_pane=$(REPO_ROOT="$repo_root" PANE_MAP="$pane_map" python3 - <<'PY'
import json
import os
path = os.environ["PANE_MAP"]
with open(path, "r", encoding="utf-8") as f:
    print(json.load(f)["oyabun"])
PY
)
waka_pane=$(REPO_ROOT="$repo_root" PANE_MAP="$pane_map" python3 - <<'PY'
import json
import os
path = os.environ["PANE_MAP"]
with open(path, "r", encoding="utf-8") as f:
    print(json.load(f)["waka"])
PY
)

_oyabun_cmd=$(agent_get_command "$config_file" "oyabun")
_waka_cmd=$(agent_get_command "$config_file" "waka")
tmux send-keys -t "$session_name:$oyabun_pane" "$_oyabun_cmd" C-m
sleep 2
tmux send-keys -t "$session_name:$waka_pane" "$_waka_cmd" C-m

sleep 5
_oyabun_mode=$(agent_get_mode "$config_file" "oyabun")
_waka_mode=$(agent_get_mode "$config_file" "waka")
if [ "$_oyabun_mode" = "interactive" ]; then
  _oyabun_msg=$(agent_get_initial_message "$config_file" "oyabun" "$oyabun_prompt" "oyabun")
  tmux send-keys -t "$session_name:$oyabun_pane" "$_oyabun_msg" C-m
fi
sleep 2
if [ "$_waka_mode" = "interactive" ]; then
  _waka_msg=$(agent_get_initial_message "$config_file" "waka" "$waka_prompt" "waka")
  tmux send-keys -t "$session_name:$waka_pane" "$_waka_msg" C-m
fi

echo "yb start: tmux session created: $session_name"
echo "Attach with: tmux attach -t $session_name"

# Auto-attach when not already inside tmux
if [ -z "${TMUX:-}" ]; then
  tmux attach -t "$session_name"
fi
