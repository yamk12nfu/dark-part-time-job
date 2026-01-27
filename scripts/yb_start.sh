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

# Build right column workers by repeatedly splitting the top-right pane.
for i in $(seq 2 "$worker_count"); do
  tmux split-window -v -t "$session_name":0.1
done

# Split left column for oyabun (top) and waka (bottom).
tmux split-window -v -p 40 -t "$session_name":0.0

pane_map="$repo_root/.yamibaito/panes.json"

SESSION_NAME="$session_name" REPO_ROOT="$repo_root" WORKER_COUNT="$worker_count" PANE_MAP="$pane_map" python3 - <<'PY'
import json
import os
import subprocess

session = os.environ["SESSION_NAME"]
repo_root = os.environ["REPO_ROOT"]
worker_count = int(os.environ["WORKER_COUNT"])
pane_map = os.environ["PANE_MAP"]

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
for i in range(worker_count):
    if i < len(right_panes):
        workers[f"worker_{i+1:03d}"] = f"0.{right_panes[i]['index']}"

mapping = {
    "session": session,
    "repo_root": repo_root,
    "oyabun": f"0.{oyabun}",
    "waka": f"0.{waka}",
    "workers": workers,
}

with open(pane_map, "w", encoding="utf-8") as f:
    json.dump(mapping, f, ensure_ascii=False, indent=2)

subprocess.run(["tmux", "select-pane", "-t", f"{session}:0.{oyabun}", "-T", "oyabun"], check=False)
subprocess.run(["tmux", "select-pane", "-t", f"{session}:0.{waka}", "-T", "waka"], check=False)
subprocess.run(["tmux", "select-pane", "-t", f"{session}:0.{oyabun}", "-P", "bg=#2f1b1b"], check=False)
subprocess.run(["tmux", "select-pane", "-t", f"{session}:0.{waka}", "-P", "bg=#1b2f2a"], check=False)

for name, pane in workers.items():
    subprocess.run(["tmux", "select-pane", "-t", f"{session}:{pane}", "-T", name], check=False)
PY

for pane in $(tmux list-panes -t "$session_name":0 -F "#{pane_index}"); do
  tmux send-keys -t "$session_name":0."$pane" "cd \"$repo_root\" && clear" C-m
done

tmux send-keys -t "$session_name":0.1 "claude --dangerously-skip-permissions" C-m
sleep 1
tmux send-keys -t "$session_name":0.0 "claude --dangerously-skip-permissions" C-m

sleep 2
tmux send-keys -t "$session_name":0.1 "Read .yamibaito/prompts/oyabun.md and follow it. You are the oyabun." C-m
sleep 1
tmux send-keys -t "$session_name":0.0 "Read .yamibaito/prompts/waka.md and follow it. You are the waka." C-m

echo "yb start: tmux session created: $session_name"
echo "Attach with: tmux attach -t $session_name"
