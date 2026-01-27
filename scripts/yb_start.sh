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

for _ in $(seq 2 "$pane_total"); do
  tmux split-window -t "$session_name":0
done
tmux select-layout -t "$session_name":0 tiled

pane_map="$repo_root/.yamibaito/panes.json"
cat > "$pane_map" <<EOF
{
  "session": "${session_name}",
  "repo_root": "${repo_root}",
  "waka": "0.0",
  "oyabun": "0.1",
  "workers": {
EOF

for i in $(seq 1 "$worker_count"); do
  worker_id=$(printf "worker_%03d" "$i")
  pane_index=$((1 + i))
  sep=","
  if [ "$i" -eq "$worker_count" ]; then
    sep=""
  fi
  echo "    \"${worker_id}\": \"0.${pane_index}\"${sep}" >> "$pane_map"
done
cat >> "$pane_map" <<'EOF'
  }
}
EOF

tmux select-pane -t "$session_name":0.0 -T "waka"
tmux select-pane -t "$session_name":0.1 -T "oyabun"
tmux select-pane -t "$session_name":0.0 -P 'bg=#1b2f2a'
tmux select-pane -t "$session_name":0.1 -P 'bg=#2f1b1b'

for i in $(seq 1 "$worker_count"); do
  pane_index=$((1 + i))
  worker_id=$(printf "worker_%03d" "$i")
  tmux select-pane -t "$session_name":0.$pane_index -T "$worker_id"
done

for i in $(seq 0 $((pane_total - 1))); do
  tmux send-keys -t "$session_name":0.$i "cd \"$repo_root\" && clear" C-m
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
