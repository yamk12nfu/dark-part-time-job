#!/bin/bash
set -euo pipefail

ORCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

repo_root="."
session_id=""
planner_mode=0
architect_done_mode=0
cmd_id=""
dry_run=0
mode_only_arg=""
cmd_id_value_missing=0
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
    --planner)
      planner_mode=1
      shift
      ;;
    --architect-done)
      architect_done_mode=1
      shift
      ;;
    --cmd-id)
      if [ -z "$mode_only_arg" ]; then
        mode_only_arg="--cmd-id"
      fi
      if [ $# -lt 2 ]; then
        cmd_id_value_missing=1
        shift
      else
        cmd_id="$2"
        shift 2
      fi
      ;;
    --dry-run)
      dry_run=1
      if [ -z "$mode_only_arg" ]; then
        mode_only_arg="--dry-run"
      fi
      shift
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ "$planner_mode" -eq 1 ] && [ "$architect_done_mode" -eq 1 ]; then
  echo "--planner and --architect-done are mutually exclusive" >&2
  exit 1
fi

if [ "$planner_mode" -ne 1 ] && [ "$architect_done_mode" -ne 1 ] && [ -n "$mode_only_arg" ]; then
  echo "Unknown arg: $mode_only_arg" >&2
  exit 1
fi

if [ "$planner_mode" -eq 0 ] && [ "$architect_done_mode" -eq 1 ] && [ "$dry_run" -eq 1 ]; then
  echo "Unknown arg: --dry-run" >&2
  exit 1
fi

if { [ "$planner_mode" -eq 1 ] || [ "$architect_done_mode" -eq 1 ]; } && [ "$cmd_id_value_missing" -eq 1 ]; then
  echo "Missing value for --cmd-id" >&2
  exit 1
fi

repo_root="$(cd "$repo_root" && pwd)"
session_id="$(echo "$session_id" | sed 's/[^A-Za-z0-9_-]/_/g')"
session_suffix=""
if [ -n "$session_id" ]; then
  session_suffix="_${session_id}"
fi
panes_file="$repo_root/.yamibaito/panes${session_suffix}.json"
dispatch_mode="default"
smoke_test_mode="${YB_DISPATCH_SMOKE_TEST:-0}"

if [ "$planner_mode" -eq 1 ]; then
  dispatch_mode="planner"
  if [ -z "$cmd_id" ]; then
    echo "Missing --cmd-id" >&2
    exit 1
  fi

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

  planner_cmd=(
    "$ORCH_ROOT/scripts/yb_planner.sh"
    --repo "$repo_root"
    --session "$session_id"
    --cmd-id "$cmd_id"
  )
  if [ "$dry_run" -eq 1 ]; then
    planner_cmd+=(--dry-run)
  fi
  if ! "${planner_cmd[@]}"; then
    exit 1
  fi

  task_expand_cmd=(
    python3 "$ORCH_ROOT/scripts/yb_task_expand.py"
    --tasks-file "$queue_dir/plan/$cmd_id/tasks.yaml"
    --queue-dir "$queue_dir"
    --repo-root "$repo_root"
    --session "$session_id"
    --cmd-id "$cmd_id"
  )
  if [ "$dry_run" -eq 1 ]; then
    task_expand_cmd+=(--dry-run)
  fi
  if ! "${task_expand_cmd[@]}"; then
    exit 1
  fi

  if [ "$dry_run" -eq 1 ]; then
    exit 0
  fi
fi

if [ "$architect_done_mode" -eq 1 ]; then
  dispatch_mode="architect_done"
  if [ -z "$cmd_id" ]; then
    echo "Missing --cmd-id" >&2
    exit 1
  fi
fi

if [ "$smoke_test_mode" != "1" ] && [ ! -f "$panes_file" ]; then
  echo "Missing panes map (run yb start): $panes_file" >&2
  exit 1
fi

REPO_ROOT="$repo_root" PANES_FILE="$panes_file" ORCH_ROOT="$ORCH_ROOT" SESSION_ID="$session_id" DISPATCH_MODE="$dispatch_mode" CMD_ID="$cmd_id" SMOKE_TEST_MODE="$smoke_test_mode" python3 - <<'PY'
import json
import os
import shlex
import subprocess
import sys

repo_root = os.environ["REPO_ROOT"]
panes_file = os.environ["PANES_FILE"]
orch_root = os.environ["ORCH_ROOT"]
session_id = os.environ.get("SESSION_ID", "")
dispatch_mode = os.environ.get("DISPATCH_MODE", "default")
cmd_id = os.environ.get("CMD_ID", "")
smoke_test_mode = os.environ.get("SMOKE_TEST_MODE", "0") == "1"
session_suffix = f"_{session_id}" if session_id else ""

def strip_inline_comment(text):
    out = []
    in_single = False
    in_double = False
    escaped = False
    for ch in text:
        if in_double:
            out.append(ch)
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_double = False
            continue
        if in_single:
            out.append(ch)
            if ch == "'":
                in_single = False
            continue
        if ch == "#":
            break
        out.append(ch)
        if ch == '"':
            in_double = True
        elif ch == "'":
            in_single = True
    return "".join(out).strip()

def parse_scalar(raw):
    cleaned = strip_inline_comment(raw).strip()
    if not cleaned:
        return ""
    if len(cleaned) >= 2 and cleaned[0] == cleaned[-1] and cleaned[0] in {"'", '"'}:
        cleaned = cleaned[1:-1]
    return cleaned.strip()

def parse_bool(raw):
    return parse_scalar(raw).lower() == "true"

def parse_design_guidance(raw, present_when_empty=False):
    lowered = parse_scalar(raw).lower()
    if not lowered:
        return present_when_empty
    return lowered not in {"null", "~", "pending", "false", "none"}

def parse_architect_metadata_from_description(description_lines):
    needs_architect = None
    design_guidance = None
    for raw_line in description_lines:
        line = raw_line.strip()
        if not line:
            continue
        if line == "--- ARCHITECT DESIGN GUIDANCE ---":
            design_guidance = True
            continue
        if line.startswith("- "):
            line = line[2:].strip()
        if ":" not in line:
            continue
        key, raw_value = line.split(":", 1)
        key = key.strip()
        raw_value = raw_value.strip()
        if key == "needs_architect":
            needs_architect = parse_bool(raw_value)
        elif key == "design_guidance":
            design_guidance = parse_design_guidance(raw_value, present_when_empty=True)
    return needs_architect, design_guidance

def read_worker_task_fields(task_path):
    if not os.path.exists(task_path):
        return None, None, False, False
    task_id = None
    status = None
    needs_architect = None
    design_guidance = None
    in_task = False
    in_description = False
    description_indent = 0
    description_lines = []
    with open(task_path, "r", encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            stripped = line.strip()
            indent = len(line) - len(line.lstrip(" "))

            if in_description:
                if not stripped:
                    description_lines.append("")
                    continue
                if indent >= description_indent:
                    description_lines.append(line[description_indent:])
                    continue
                in_description = False

            if not stripped or stripped.startswith("#"):
                continue

            if not in_task:
                if indent == 0 and stripped == "task:":
                    in_task = True
                continue

            if indent == 0 and stripped.endswith(":"):
                break
            if indent != 2:
                continue
            if ":" not in stripped:
                continue

            key, raw_value = stripped.split(":", 1)
            key = key.strip()
            raw_value = raw_value.strip()
            value = parse_scalar(raw_value)
            if key == "task_id" and not task_id:
                task_id = value
            elif key == "status" and not status:
                status = value
            elif key == "needs_architect":
                needs_architect = parse_bool(raw_value)
            elif key == "design_guidance":
                design_guidance = parse_design_guidance(raw_value, present_when_empty=(raw_value == ""))
            elif key == "description":
                is_multiline = raw_value.startswith("|") or raw_value.startswith(">") or value in {"|", ">"}
                if raw_value == "" or is_multiline:
                    in_description = True
                    description_indent = indent + 2

    desc_needs_architect, desc_design_guidance = parse_architect_metadata_from_description(description_lines)
    if needs_architect is None:
        needs_architect = desc_needs_architect
    if design_guidance is None:
        design_guidance = desc_design_guidance
    return task_id, status, bool(needs_architect), bool(design_guidance)

def apply_plan_field(task, key, raw_value):
    if key == "id":
        task["id"] = parse_scalar(raw_value)
    elif key == "owner":
        task["owner"] = parse_scalar(raw_value)
    elif key == "needs_architect":
        task["needs_architect"] = parse_bool(raw_value)

def read_plan_task_map(tasks_path):
    if not os.path.exists(tasks_path):
        raise FileNotFoundError(tasks_path)

    task_map = {}
    in_tasks = False
    current = None

    def flush_current():
        if not isinstance(current, dict):
            return
        owner = current.get("owner")
        if owner:
            task_map[owner] = {
                "id": current.get("id", ""),
                "needs_architect": bool(current.get("needs_architect", False)),
            }

    with open(tasks_path, "r", encoding="utf-8") as f:
        for raw_line in f:
            line = raw_line.rstrip("\n")
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            indent = len(line) - len(line.lstrip(" "))

            if not in_tasks:
                if indent == 0 and stripped.startswith("tasks:"):
                    in_tasks = True
                continue

            if indent == 0 and not stripped.startswith("- "):
                break

            if indent == 2 and stripped.startswith("- "):
                flush_current()
                current = {"id": "", "owner": "", "needs_architect": False}
                inline = stripped[2:].strip()
                if inline and ":" in inline:
                    key, raw_value = inline.split(":", 1)
                    apply_plan_field(current, key.strip(), raw_value.strip())
                continue

            if indent == 4 and isinstance(current, dict) and ":" in stripped:
                key, raw_value = stripped.split(":", 1)
                apply_plan_field(current, key.strip(), raw_value.strip())

    flush_current()
    return task_map

def resolve_worker_needs_architect(worker_id, worker_needs_architect, plan_task_map):
    plan_task = plan_task_map.get(worker_id)
    if isinstance(plan_task, dict):
        return bool(plan_task.get("needs_architect", False))
    return worker_needs_architect

def planner_route(has_architect_pane, needs_architect):
    if has_architect_pane and needs_architect:
        return "architect"
    return "implementer"

def should_dispatch_architect_done(needs_architect, design_guidance):
    return needs_architect and design_guidance

def should_abort_architect_launch(has_architect_pane, architect_targets, architect_agent):
    return has_architect_pane and bool(architect_targets) and not architect_agent

def send_to_pane(target, command):
    subprocess.run(["tmux", "send-keys", "-t", target, command], check=False)
    subprocess.run(["tmux", "send-keys", "-t", target, "Enter"], check=False)

def dispatch_implementer(worker_id, pane):
    cmd = f'cd "{work_dir}" && "{orch_root}/scripts/yb_run_worker.sh" --repo "{repo_root}" --worker "{worker_id}"'
    if session_id:
        cmd += f' --session "{session_id}"'
    send_to_pane(f"{session}:{pane}", cmd)

def resolve_architect_agent():
    sys.path.insert(0, os.path.join(orch_root, "scripts", "lib"))
    try:
        from agent_config import build_initial_message, build_launch_command, load_agent_config
    except Exception as exc:
        print(f"Failed to import agent_config for architect routing: {exc}", file=sys.stderr)
        return None

    config_path = os.path.join(repo_root, ".yamibaito", "config.yaml")
    try:
        agent_cfg = load_agent_config(config_path, "architect")
        launch_command = build_launch_command(agent_cfg)
    except Exception as exc:
        print(f"Failed to resolve architect command: {exc}", file=sys.stderr)
        return None

    if not launch_command:
        print("Failed to resolve architect command: empty command", file=sys.stderr)
        return None

    mode = str(agent_cfg.get("mode", "interactive")).strip().lower() or "interactive"
    initial_message = ""
    if mode == "interactive":
        prompt_path = os.path.join(repo_root, "prompts", "v2", "architect.md")
        try:
            initial_message = build_initial_message(
                agent_cfg,
                prompt_path=prompt_path,
                role="architect",
            )
        except Exception as exc:
            print(f"Failed to resolve architect initial message: {exc}", file=sys.stderr)
            return None

    return {
        "command": launch_command,
        "mode": mode,
        "initial_message": initial_message,
    }

def dispatch_architect(architect_agent, worker_id, task_id, task_path):
    target = f"{session}:{architect_pane}"
    env_bits = [
        f"YB_TARGET_WORKER={shlex.quote(worker_id)}",
        f"YB_TARGET_TASK={shlex.quote(task_id)}",
        f"YB_TARGET_TASK_FILE={shlex.quote(task_path)}",
    ]
    launch_cmd = shlex.join(architect_agent["command"])

    if architect_agent.get("mode") == "batch_stdin":
        cmd = (
            f"cd {shlex.quote(work_dir)} && cat {shlex.quote(task_path)} | "
            f"env {' '.join(env_bits)} {launch_cmd}"
        )
        send_to_pane(target, cmd)
        return

    cmd = f"cd {shlex.quote(work_dir)} && {' '.join(env_bits)} {launch_cmd}"
    send_to_pane(target, cmd)

    initial_message = str(architect_agent.get("initial_message", "")).strip()
    if initial_message:
        send_to_pane(target, initial_message)

    task_message = (
        f'Please read task file: "{task_path}" and execute architect role for '
        f'task_id "{task_id}" (worker "{worker_id}").'
    )
    send_to_pane(target, task_message)

def collect_active_worker_tasks(workers, queue_dir, plan_task_map):
    active_worker_tasks = []
    for worker_id, pane in workers.items():
        task_path = os.path.join(queue_dir, "tasks", f"{worker_id}.yaml")
        task_id, status, needs_architect, design_guidance = read_worker_task_fields(task_path)
        if not task_id or task_id == "null":
            continue
        if status not in ("assigned", "in_progress"):
            continue
        resolved_needs_architect = resolve_worker_needs_architect(worker_id, needs_architect, plan_task_map)
        active_worker_tasks.append(
            (worker_id, pane, task_id, task_path, resolved_needs_architect, design_guidance)
        )
    return active_worker_tasks

def dispatch_planner_workers(
    active_worker_tasks,
    has_architect_pane,
    resolve_architect_agent_fn=resolve_architect_agent,
    dispatch_architect_fn=dispatch_architect,
    dispatch_implementer_fn=dispatch_implementer,
):
    architect_targets = []
    implementer_targets = []
    for worker_id, pane, task_id, task_path, resolved_needs_architect, _ in active_worker_tasks:
        route = planner_route(has_architect_pane, resolved_needs_architect)
        if route == "architect":
            architect_targets.append((worker_id, task_id, task_path))
            continue
        implementer_targets.append((worker_id, pane))

    architect_agent = None
    if has_architect_pane and architect_targets:
        architect_agent = resolve_architect_agent_fn()
        if should_abort_architect_launch(has_architect_pane, architect_targets, architect_agent):
            return False

    for worker_id, task_id, task_path in architect_targets:
        dispatch_architect_fn(architect_agent, worker_id, task_id, task_path)
    for worker_id, pane in implementer_targets:
        dispatch_implementer_fn(worker_id, pane)

    return True

def run_smoke_tests():
    import tempfile
    import unittest

    class DispatchSmokeTests(unittest.TestCase):
        def test_planner_dispatch_with_architect_pane(self):
            self.assertEqual(planner_route(True, True), "architect")

        def test_planner_dispatch_without_architect_pane(self):
            self.assertEqual(planner_route(False, True), "implementer")

        def test_architect_done_with_embedded_design_guidance(self):
            body = "\n".join(
                [
                    "schema_version: 1",
                    "task:",
                    '  task_id: "cmd_0001_task_001"',
                    "  status: assigned",
                    "  description: |",
                    "    ## Architect",
                    "    - needs_architect: true",
                    "    - design_guidance: embedded",
                    "    --- ARCHITECT DESIGN GUIDANCE ---",
                    "    decision: keep-plan-as-source",
                    "",
                ]
            )
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as tmp:
                tmp.write(body)
                tmp_path = tmp.name
            try:
                _, _, needs_architect, design_guidance = read_worker_task_fields(tmp_path)
            finally:
                os.remove(tmp_path)
            self.assertTrue(should_dispatch_architect_done(needs_architect, design_guidance))

        def test_architect_done_with_top_level_design_guidance(self):
            body = "\n".join(
                [
                    "schema_version: 1",
                    "task:",
                    '  task_id: "cmd_0001_task_001"',
                    "  status: assigned",
                    "  needs_architect: true",
                    "  design_guidance: complete",
                    "",
                ]
            )
            with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as tmp:
                tmp.write(body)
                tmp_path = tmp.name
            try:
                _, _, needs_architect, design_guidance = read_worker_task_fields(tmp_path)
            finally:
                os.remove(tmp_path)
            self.assertTrue(should_dispatch_architect_done(needs_architect, design_guidance))

        def test_architect_launch_failure_is_fatal(self):
            targets = [("worker_001", "cmd_0001_task_001", "/tmp/worker_001.yaml")]
            self.assertTrue(should_abort_architect_launch(True, targets, None))
            self.assertFalse(should_abort_architect_launch(False, targets, None))

        def test_planner_mixed_task_aborts_without_tmux_side_effects_on_architect_resolution_failure(self):
            with tempfile.TemporaryDirectory() as tmpdir:
                tasks_dir = os.path.join(tmpdir, "tasks")
                os.makedirs(tasks_dir, exist_ok=True)

                with open(os.path.join(tasks_dir, "worker_001.yaml"), "w", encoding="utf-8") as f:
                    f.write(
                        "\n".join(
                            [
                                "schema_version: 1",
                                "task:",
                                '  task_id: "cmd_0001_task_001"',
                                "  status: assigned",
                                "  needs_architect: true",
                                "",
                            ]
                        )
                    )
                with open(os.path.join(tasks_dir, "worker_002.yaml"), "w", encoding="utf-8") as f:
                    f.write(
                        "\n".join(
                            [
                                "schema_version: 1",
                                "task:",
                                '  task_id: "cmd_0001_task_002"',
                                "  status: assigned",
                                "  needs_architect: false",
                                "",
                            ]
                        )
                    )

                workers_map = {
                    "worker_001": "pane_architect_target",
                    "worker_002": "pane_implementer_target",
                }
                active_worker_tasks = collect_active_worker_tasks(workers_map, tmpdir, {})
                calls = []

                def fake_resolve_architect_agent():
                    return None

                def fake_dispatch_architect(*_args):
                    calls.append("architect")

                def fake_dispatch_implementer(*_args):
                    calls.append("implementer")

                ok = dispatch_planner_workers(
                    active_worker_tasks,
                    True,
                    resolve_architect_agent_fn=fake_resolve_architect_agent,
                    dispatch_architect_fn=fake_dispatch_architect,
                    dispatch_implementer_fn=fake_dispatch_implementer,
                )

            self.assertFalse(ok)
            self.assertEqual(calls, [])

    suite = unittest.defaultTestLoader.loadTestsFromTestCase(DispatchSmokeTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1

if smoke_test_mode:
    sys.exit(run_smoke_tests())

try:
    with open(panes_file, "r", encoding="utf-8") as f:
        panes_data = json.load(f)
    if not isinstance(panes_data, dict):
        raise TypeError("panes map must be a JSON object")
    session = panes_data["session"]
    workers = panes_data["workers"]
    if not isinstance(session, str) or not session:
        raise TypeError("session must be a non-empty string")
    if not isinstance(workers, dict):
        raise TypeError("workers must be a JSON object")
except (json.JSONDecodeError, OSError, KeyError, TypeError) as exc:
    print(f"Invalid panes map: {panes_file}: {exc}", file=sys.stderr)
    sys.exit(1)

work_dir = panes_data.get("work_dir", repo_root)
if not isinstance(work_dir, str) or not work_dir or not os.path.isdir(work_dir):
    work_dir = repo_root
architect_pane = panes_data.get("architect", "")
if not isinstance(architect_pane, str):
    architect_pane = ""

# Build queue_dir from work_dir first, then fall back to repo_root for compatibility.
queue_dir = os.path.join(work_dir, ".yamibaito", f"queue{session_suffix}")
if not os.path.isdir(queue_dir):
    queue_dir = os.path.join(repo_root, ".yamibaito", f"queue{session_suffix}")

plan_task_map = {}
if dispatch_mode in {"planner", "architect_done"}:
    if not cmd_id:
        print("Missing --cmd-id", file=sys.stderr)
        sys.exit(1)
    plan_tasks_path = os.path.join(queue_dir, "plan", cmd_id, "tasks.yaml")
    try:
        plan_task_map = read_plan_task_map(plan_tasks_path)
    except OSError as exc:
        mode_label = "--planner" if dispatch_mode == "planner" else "--architect-done"
        print(f"Failed to read planner tasks for {mode_label}: {plan_tasks_path}: {exc}", file=sys.stderr)
        sys.exit(1)

active_worker_tasks = collect_active_worker_tasks(workers, queue_dir, plan_task_map)

if dispatch_mode == "planner":
    if not dispatch_planner_workers(active_worker_tasks, bool(architect_pane)):
        print("architect pane is configured but architect command resolution failed", file=sys.stderr)
        sys.exit(1)
elif dispatch_mode == "architect_done":
    for worker_id, pane, task_id, _, resolved_needs_architect, design_guidance in active_worker_tasks:
        if not resolved_needs_architect:
            continue
        if not should_dispatch_architect_done(resolved_needs_architect, design_guidance):
            print(
                f"architect-done: skip worker '{worker_id}' ({task_id}) because design_guidance is missing",
                file=sys.stderr,
            )
            continue
        dispatch_implementer(worker_id, pane)
else:
    for worker_id, pane, _, _, _, _ in active_worker_tasks:
        dispatch_implementer(worker_id, pane)
PY
