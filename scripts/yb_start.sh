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
repo_name="$(basename "$repo_root" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_name="yamibaito_${repo_name}"

config_file="$repo_root/.yamibaito/config.yaml"
if [ ! -f "$config_file" ]; then
  echo "Missing config: $config_file (run yb init)" >&2
  exit 1
fi

worker_count=$(grep -E "^\\s*codex_count:" "$config_file" | awk '{print $2}')
if [ -z "$worker_count" ]; then
  worker_count=3
fi

if tmux has-session -t "$session_name" 2>/dev/null; then
  echo "tmux session already exists: $session_name" >&2
  echo "Attach with: tmux attach -t $session_name" >&2
  exit 1
fi

pane_total=$((2 + worker_count))

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

pane_map="$repo_root/.yamibaito/panes.json"

SESSION_NAME="$session_name" REPO_ROOT="$repo_root" WORKER_COUNT="$worker_count" PANE_MAP="$pane_map" python3 - <<'PY'
import json
import os
import subprocess

session = os.environ["SESSION_NAME"]
repo_root = os.environ["REPO_ROOT"]
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
    "session": session,
    "repo_root": repo_root,
    "oyabun": f"0.{oyabun}",
    "waka": f"0.{waka}",
    "workers": workers,
    "worker_names": worker_name_map,
}

with open(pane_map, "w", encoding="utf-8") as f:
    json.dump(mapping, f, ensure_ascii=False, indent=2)

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

for pane in $(tmux list-panes -t "$session_name":0 -F "#{pane_index}"); do
  tmux send-keys -t "$session_name":0."$pane" "export PATH=\"$ORCH_ROOT/bin:\$PATH\" && cd \"$repo_root\" && clear" C-m
done

oyabun_pane=$(REPO_ROOT="$repo_root" python3 - <<'PY'
import json
import os
path = os.path.join(os.environ["REPO_ROOT"], ".yamibaito", "panes.json")
with open(path, "r", encoding="utf-8") as f:
    print(json.load(f)["oyabun"])
PY
)
waka_pane=$(REPO_ROOT="$repo_root" python3 - <<'PY'
import json
import os
path = os.path.join(os.environ["REPO_ROOT"], ".yamibaito", "panes.json")
with open(path, "r", encoding="utf-8") as f:
    print(json.load(f)["waka"])
PY
)

oyabun_prompt="$repo_root/.yamibaito/prompts/oyabun.md"
waka_prompt="$repo_root/.yamibaito/prompts/waka.md"

tmux send-keys -t "$session_name:$oyabun_pane" "claude --dangerously-skip-permissions" C-m
sleep 2
tmux send-keys -t "$session_name:$waka_pane" "claude --dangerously-skip-permissions" C-m

sleep 5
tmux send-keys -t "$session_name:$oyabun_pane" "Please read file: \"$oyabun_prompt\" and follow it. You are the oyabun." C-m
sleep 2
tmux send-keys -t "$session_name:$waka_pane" "Please read file: \"$waka_prompt\" and follow it. You are the waka." C-m

echo "yb start: tmux session created: $session_name"
echo "Attach with: tmux attach -t $session_name"

# Auto-attach when not already inside tmux
if [ -z "${TMUX:-}" ]; then
  tmux attach -t "$session_name"
fi
