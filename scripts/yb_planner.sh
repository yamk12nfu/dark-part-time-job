#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo_root=""
repo_flag_set=0
session_id=""
cmd_id=""
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      if [ $# -lt 2 ]; then
        echo "Missing value for --repo" >&2
        exit 1
      fi
      repo_root="$2"
      repo_flag_set=1
      shift 2
      ;;
    --session)
      if [ $# -lt 2 ]; then
        echo "Missing value for --session" >&2
        exit 1
      fi
      session_id="$2"
      shift 2
      ;;
    --cmd-id)
      if [ $# -lt 2 ]; then
        echo "Missing value for --cmd-id" >&2
        exit 1
      fi
      cmd_id="$2"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ "$repo_flag_set" -ne 1 ]; then
  echo "Missing --repo" >&2
  exit 1
fi

if [ -z "$cmd_id" ]; then
  echo "Missing --cmd-id" >&2
  exit 1
fi

if [ ! -d "$repo_root" ]; then
  echo "Invalid --repo (directory not found): $repo_root" >&2
  exit 1
fi

repo_root="$(cd "$repo_root" && pwd)"
session_id="$(echo "$session_id" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_suffix=""
if [ -n "$session_id" ]; then
  session_suffix="_${session_id}"
fi

panes_file="$repo_root/.yamibaito/panes${session_suffix}.json"
work_dir="$repo_root"
if [ -f "$panes_file" ]; then
  resolved_work_dir="$(_PANES_FILE="$panes_file" _REPO_ROOT="$repo_root" python3 - <<'PY'
import json
import os

panes_file = os.environ["_PANES_FILE"]
repo_root = os.environ["_REPO_ROOT"]

try:
    with open(panes_file, "r", encoding="utf-8") as f:
        panes = json.load(f)
    if isinstance(panes, dict):
        candidate = panes.get("work_dir", "")
        if isinstance(candidate, str) and candidate and os.path.isdir(candidate):
            print(candidate)
            raise SystemExit(0)
except Exception:
    pass

print(repo_root)
PY
)"
  work_dir="$resolved_work_dir"
fi

queue_dir="$work_dir/.yamibaito/queue${session_suffix}"
if [ ! -d "$queue_dir" ]; then
  queue_dir="$repo_root/.yamibaito/queue${session_suffix}"
fi

REPO_ROOT="$repo_root" \
WORK_DIR="$work_dir" \
QUEUE_DIR="$queue_dir" \
CMD_ID="$cmd_id" \
DRY_RUN="$dry_run" \
ORCH_ROOT="$ORCH_ROOT" \
python3 - <<'PY'
import os
import re
import shutil
import subprocess
import sys


def eprint(message):
    print(message, file=sys.stderr)


def parse_scalar(raw):
    text = raw.strip()
    if not text:
        return ""

    result = []
    in_single = False
    in_double = False
    escaped = False
    for ch in text:
        if ch == "\\" and in_double and not escaped:
            escaped = True
            result.append(ch)
            continue
        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single and not escaped:
            in_double = not in_double
        if ch == "#" and not in_single and not in_double:
            break
        result.append(ch)
        escaped = False

    value = "".join(result).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        value = value[1:-1]
    return value.strip()


def extract_cmd_entry(raw_text, target_cmd_id):
    lines = raw_text.splitlines()
    in_queue = False
    queue_indent = 0
    idx = 0

    while idx < len(lines):
        line = lines[idx]
        stripped = line.strip()
        indent = len(line) - len(line.lstrip(" "))

        if not in_queue:
            if stripped.startswith("queue:") and line.lstrip().startswith("queue:"):
                in_queue = True
                queue_indent = indent
            idx += 1
            continue

        if stripped and not stripped.startswith("#") and indent <= queue_indent:
            break

        item_prefix = " " * (queue_indent + 2) + "- "
        if line.startswith(item_prefix):
            start = idx
            idx += 1
            while idx < len(lines):
                next_line = lines[idx]
                next_stripped = next_line.strip()
                next_indent = len(next_line) - len(next_line.lstrip(" "))
                if next_stripped and not next_stripped.startswith("#") and next_indent <= queue_indent:
                    break
                if next_line.startswith(item_prefix):
                    break
                idx += 1

            chunk_lines = lines[start:idx]
            cmd_value = ""
            for chunk_line in chunk_lines:
                matched = re.match(r"^\s*(?:-\s*)?cmd_id:\s*(.+?)\s*$", chunk_line)
                if matched:
                    cmd_value = parse_scalar(matched.group(1))
                    break

            if cmd_value == target_cmd_id:
                return "\n".join(chunk_lines).rstrip() + "\n"
            continue

        idx += 1

    return None


repo_root = os.environ["REPO_ROOT"]
work_dir = os.environ["WORK_DIR"]
queue_dir = os.environ["QUEUE_DIR"]
cmd_id = os.environ["CMD_ID"]
dry_run = os.environ.get("DRY_RUN", "0") == "1"
orch_root = os.environ["ORCH_ROOT"]

if not re.fullmatch(r"[A-Za-z0-9_-]+", cmd_id):
    eprint(
        f"Invalid --cmd-id: {cmd_id!r}. Allowed pattern: ^[A-Za-z0-9_-]+$"
    )
    sys.exit(1)

plan_root = os.path.realpath(os.path.join(queue_dir, "plan"))
output_dir = os.path.realpath(os.path.join(plan_root, cmd_id))
tasks_output_path = os.path.realpath(os.path.join(output_dir, "tasks.yaml"))

try:
    output_under_plan = os.path.commonpath([plan_root, output_dir]) == plan_root
    tasks_under_plan = os.path.commonpath([plan_root, tasks_output_path]) == plan_root
except ValueError:
    output_under_plan = False
    tasks_under_plan = False

if not output_under_plan or not tasks_under_plan:
    eprint(
        "Resolved tasks output path escapes queue plan directory: "
        f"plan_root={plan_root}, output_dir={output_dir}, tasks_output_path={tasks_output_path}"
    )
    sys.exit(1)

if dry_run:
    os.makedirs(output_dir, exist_ok=True)
    sample_tasks = os.path.join(repo_root, "templates", "plan", "sample_tasks.yaml")
    if not os.path.isfile(sample_tasks):
        eprint(f"Missing sample tasks template: {sample_tasks}")
        sys.exit(1)
    try:
        shutil.copyfile(sample_tasks, tasks_output_path)
    except OSError as exc:
        eprint(f"Failed to copy sample tasks.yaml: {exc}")
        sys.exit(1)
    print(f"dry-run: copied sample tasks.yaml to {tasks_output_path}")
    sys.exit(0)

queue_file = os.path.join(queue_dir, "director_to_planner.yaml")
if not os.path.isfile(queue_file):
    eprint(f"Missing director_to_planner.yaml: {queue_file}")
    sys.exit(1)

try:
    with open(queue_file, "r", encoding="utf-8") as f:
        queue_text = f.read()
except OSError as exc:
    eprint(f"Failed to read queue file: {queue_file}: {exc}")
    sys.exit(1)

cmd_yaml_item = extract_cmd_entry(queue_text, cmd_id)
if not cmd_yaml_item:
    eprint(f"cmd_id not found in queue: {cmd_id}")
    sys.exit(1)

os.makedirs(output_dir, exist_ok=True)

planner_prompt_path = os.path.join(repo_root, "prompts", "v2", "planner.md")
try:
    with open(planner_prompt_path, "r", encoding="utf-8") as f:
        planner_prompt = f.read()
except OSError as exc:
    eprint(f"Failed to read planner prompt: {planner_prompt_path}: {exc}")
    sys.exit(1)

sys.path.insert(0, os.path.join(orch_root, "scripts", "lib"))
try:
    from agent_config import CLI_PRESETS, build_launch_command, load_agent_config
except Exception as exc:  # pragma: no cover - defensive
    eprint(f"Failed to import agent_config: {exc}")
    sys.exit(1)

config_path = os.path.join(repo_root, ".yamibaito", "config.yaml")
agent_cfg = load_agent_config(config_path, "plan")
cli = str(agent_cfg.get("cli", "")).strip()
batch_cmd = str(CLI_PRESETS.get(cli, {}).get("batch_command", "")).strip()

launch_cfg = dict(agent_cfg)
if batch_cmd:
    launch_cfg["command"] = batch_cmd

cmd = build_launch_command(launch_cfg)
if not cmd:
    eprint("Failed to build planner launch command")
    sys.exit(1)

if cmd and cmd[-1] == "-":
    cmd = cmd[:-1]

if "-p" not in cmd:
    cmd.append("-p")

model_flag = str(agent_cfg.get("model_flag", "--model")).strip() or "--model"
if "-p" in cmd and model_flag in cmd:
    prompt_flag_idx = cmd.index("-p")
    model_flag_idx = cmd.index(model_flag)
    if model_flag_idx > prompt_flag_idx and model_flag_idx + 1 < len(cmd):
        model_tokens = cmd[model_flag_idx : model_flag_idx + 2]
        del cmd[model_flag_idx : model_flag_idx + 2]
        prompt_flag_idx = cmd.index("-p")
        cmd[prompt_flag_idx:prompt_flag_idx] = model_tokens

planner_input = (
    f"{planner_prompt.rstrip()}\n\n"
    "## Runtime Input\n\n"
    "Target cmd YAML:\n\n"
    "```yaml\n"
    "queue:\n"
    f"{cmd_yaml_item.rstrip()}\n"
    "```\n\n"
    f"tasks.yaml output path: {tasks_output_path}\n"
    "Write tasks.yaml to the output path above, then print exactly one completion JSON according to the Output Contract.\n"
)
cmd.append(planner_input)

try:
    proc = subprocess.Popen(
        cmd,
        stdout=sys.stdout,
        stderr=sys.stderr,
        cwd=work_dir,
        text=True,
    )
except OSError as exc:
    eprint(f"Failed to launch planner process: {exc}")
    sys.exit(1)

sys.exit(proc.wait())
PY
