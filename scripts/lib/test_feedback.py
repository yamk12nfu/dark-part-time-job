"""Minimal verification tests for feedback helpers.

Run:
    python3 -m unittest scripts.lib.test_feedback
"""

import os
import sys
import unittest

SCRIPTS_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if SCRIPTS_DIR not in sys.path:
    sys.path.insert(0, SCRIPTS_DIR)

from lib.feedback import (
    REQUIRED_FEEDBACK_FIELDS,
    resolve_target,
    validate_feedback_entry,
    validate_feedback_entry_or_raise,
)


def _build_entry(**overrides):
    entry = {
        "datetime": "2026-02-19T00:00:00",
        "role": "worker",
        "target": "cmd_0040",
        "issue": "issue",
        "root_cause": "cause",
        "action": "action",
        "expected_metric": "metric",
        "evidence": "evidence",
    }
    entry.update(overrides)
    return entry


class ValidateFeedbackEntryTests(unittest.TestCase):
    def test_validate_feedback_entry_all_fields_present(self):
        result = validate_feedback_entry(_build_entry())
        self.assertEqual(result, (True, []))

    def test_validate_feedback_entry_one_missing_field(self):
        is_valid, missing = validate_feedback_entry(_build_entry(action=""))
        self.assertFalse(is_valid)
        self.assertEqual(missing, ["action"])

    def test_validate_feedback_entry_null_or_empty_values(self):
        is_valid, missing = validate_feedback_entry(
            _build_entry(issue=None, root_cause="  ", evidence="null")
        )
        self.assertFalse(is_valid)
        self.assertEqual(missing, ["issue", "root_cause", "evidence"])

    def test_validate_feedback_entry_or_raise_raises_for_missing(self):
        with self.assertRaises(ValueError):
            validate_feedback_entry_or_raise(_build_entry(role=""))

    def test_non_dict_entry_marks_all_fields_missing(self):
        is_valid, missing = validate_feedback_entry("not-a-dict")
        self.assertFalse(is_valid)
        self.assertEqual(missing, list(REQUIRED_FEEDBACK_FIELDS))


class ResolveTargetTests(unittest.TestCase):
    def test_parent_cmd_id_has_priority(self):
        self.assertEqual(resolve_target("cmd_parent", "task_1"), "cmd_parent")

    def test_unknown_when_parent_and_task_missing(self):
        self.assertEqual(resolve_target(None, None), "unknown")


if __name__ == "__main__":
    unittest.main()
