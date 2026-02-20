"""Regression tests for collect-time feedback anomaly classification.

Run:
    python3 -m unittest scripts.lib.test_collect_feedback
"""

from __future__ import annotations

import re
import shutil
import subprocess
import tempfile
import unittest

from pathlib import Path


SCRIPTS_DIR = Path(__file__).resolve().parents[1]
COLLECT_SCRIPT = SCRIPTS_DIR / "yb_collect.sh"
SESSION_ID = "feedback-loop"


def _valid_feedback_block(indent: str = "  ") -> str:
    return (
        f"{indent}feedback:\n"
        f"{indent}  - datetime: \"2026-02-20T05:00:00\"\n"
        f"{indent}    role: \"worker\"\n"
        f"{indent}    target: \"cmd_0040\"\n"
        f"{indent}    issue: \"issue\"\n"
        f"{indent}    root_cause: \"cause\"\n"
        f"{indent}    action: \"action\"\n"
        f"{indent}    expected_metric: \"metric\"\n"
        f"{indent}    evidence: \"evidence\"\n"
    )


def _build_report_yaml(task_id: str, extra_lines: list[str], feedback_block: str = "") -> str:
    lines = [
        "schema_version: 1",
        "report:",
        "  worker_id: \"worker_001\"",
        f"  task_id: \"{task_id}\"",
        "  parent_cmd_id: \"cmd_0040\"",
        "  finished_at: \"2026-02-20T05:00:00\"",
        "  status: completed",
        "  summary: \"collect regression test\"",
        "  phase: implement",
        "  loop_count: 0",
        "  review_result: null",
        f"  gate_id: \"{task_id}\"",
    ]
    lines.extend(extra_lines)
    if feedback_block:
        lines.append(feedback_block.rstrip("\n"))
    return "\n".join(lines) + "\n"


class CollectFeedbackRegressionTests(unittest.TestCase):
    def setUp(self):
        self.repo_dir = Path(tempfile.mkdtemp(prefix="yb_collect_case_"))
        self.queue_dir = self.repo_dir / ".yamibaito" / f"queue_{SESSION_ID}"
        (self.queue_dir / "reports").mkdir(parents=True, exist_ok=True)
        (self.queue_dir / "tasks").mkdir(parents=True, exist_ok=True)

    def tearDown(self):
        shutil.rmtree(self.repo_dir, ignore_errors=True)

    def _run_collect_for_report(self, report_name: str, report_yaml: str):
        report_path = self.queue_dir / "reports" / report_name
        report_path.write_text(report_yaml, encoding="utf-8")
        proc = subprocess.run(
            ["bash", str(COLLECT_SCRIPT), "--repo", str(self.repo_dir), "--session", SESSION_ID],
            capture_output=True,
            text=True,
            check=False,
            cwd=str(self.repo_dir),
        )
        self.assertEqual(
            proc.returncode,
            0,
            msg=f"collect failed:\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        dashboard = (self.repo_dir / "dashboard.md").read_text(encoding="utf-8")
        return proc.stderr, dashboard

    def _assert_error_code(self, stderr: str, task_id: str, expected: str):
        pattern = rf"collect_log: .*task_id={re.escape(task_id)} .*error_code=([A-Z_]+)"
        match = re.search(pattern, stderr)
        self.assertIsNotNone(match, msg=f"collect_log not found for task_id={task_id}\nstderr:\n{stderr}")
        self.assertEqual(match.group(1), expected)

    def _assert_dashboard_feedback_counts(self, dashboard: str, *, missing: int, invalid: int, rework_repeat: int):
        missing_match = re.search(r"\| 未追記 \| (\d+) \|", dashboard)
        invalid_match = re.search(r"\| 形式不正 \| (\d+) \|", dashboard)
        repeat_match = re.search(r"\| rework再発 \| (\d+) \|", dashboard)
        self.assertIsNotNone(missing_match, msg=f"missing count row not found:\n{dashboard}")
        self.assertIsNotNone(invalid_match, msg=f"invalid count row not found:\n{dashboard}")
        self.assertIsNotNone(repeat_match, msg=f"rework repeat row not found:\n{dashboard}")
        self.assertEqual(int(missing_match.group(1)), missing)
        self.assertEqual(int(invalid_match.group(1)), invalid)
        self.assertEqual(int(repeat_match.group(1)), rework_repeat)

    def test_feedback_field_missing_is_classified_as_feedback_missing(self):
        task_id = "T-C1"
        report_yaml = _build_report_yaml(task_id, extra_lines=[], feedback_block="")

        stderr, dashboard = self._run_collect_for_report("worker_001_report.yaml", report_yaml)

        self._assert_error_code(stderr, task_id, "FEEDBACK_MISSING")
        self._assert_dashboard_feedback_counts(dashboard, missing=1, invalid=0, rework_repeat=0)

    def test_empty_feedback_array_is_classified_as_feedback_missing(self):
        task_id = "T-C2"
        report_yaml = _build_report_yaml(task_id, extra_lines=["  feedback: []"], feedback_block="")

        stderr, dashboard = self._run_collect_for_report("worker_001_report.yaml", report_yaml)

        self._assert_error_code(stderr, task_id, "FEEDBACK_MISSING")
        self._assert_dashboard_feedback_counts(dashboard, missing=1, invalid=0, rework_repeat=0)

    def test_invalid_feedback_entry_is_classified_as_feedback_invalid(self):
        task_id = "T-C3"
        invalid_feedback = (
            "  feedback:\n"
            "    - datetime: \"2026-02-20T05:00:00\"\n"
            "      role: \"worker\"\n"
            "      target: \"cmd_0040\"\n"
            "      issue: \"issue\"\n"
            "      root_cause: \"cause\"\n"
            "      action: \"\"\n"
            "      expected_metric: \"metric\"\n"
            "      evidence: \"evidence\"\n"
        )
        report_yaml = _build_report_yaml(task_id, extra_lines=[], feedback_block=invalid_feedback)

        stderr, dashboard = self._run_collect_for_report("worker_001_report.yaml", report_yaml)

        self._assert_error_code(stderr, task_id, "FEEDBACK_INVALID")
        self._assert_dashboard_feedback_counts(dashboard, missing=0, invalid=1, rework_repeat=0)

    def test_review_rework_loop_two_or_more_is_classified_as_rework_repeat(self):
        task_id = "T-C4"
        report_yaml = _build_report_yaml(
            task_id,
            extra_lines=[
                "  phase: review",
                "  loop_count: 2",
                "  review_result: rework",
                "  review_target_task_id: \"T-C4\"",
                "  gate_id: \"T-C4\"",
            ],
            feedback_block=_valid_feedback_block(),
        )

        stderr, dashboard = self._run_collect_for_report("worker_001_report.yaml", report_yaml)

        self._assert_error_code(stderr, task_id, "REWORK_REPEAT")
        self._assert_dashboard_feedback_counts(dashboard, missing=0, invalid=0, rework_repeat=1)


if __name__ == "__main__":
    unittest.main()
