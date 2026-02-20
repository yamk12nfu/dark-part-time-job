"""Helpers for feedback entry validation and cmd-target normalization.

Import pattern (recommended):
    import os, sys
    scripts_dir = os.environ["SCRIPTS_DIR"]
    sys.path.insert(0, scripts_dir)
    from lib.feedback import (
        resolve_target,
        validate_feedback_entry,
        validate_feedback_entry_or_raise,
    )
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional, Tuple

REQUIRED_FEEDBACK_FIELDS = (
    "datetime",
    "role",
    "target",
    "issue",
    "root_cause",
    "action",
    "expected_metric",
    "evidence",
)


def _normalize_text(value: Any) -> str:
    if value is None:
        return ""
    normalized = str(value).strip()
    if normalized.lower() == "null":
        return ""
    return normalized


def _normalize_target_value(value: Optional[str]) -> str:
    normalized = _normalize_text(value)
    if not normalized or normalized.lower() == "null":
        return ""
    return normalized


def validate_feedback_entry(entry: Dict[str, Any]) -> Tuple[bool, List[str]]:
    """Validate required feedback fields and return missing field names."""
    if not isinstance(entry, dict):
        return False, list(REQUIRED_FEEDBACK_FIELDS)

    missing_fields: List[str] = []
    for field_name in REQUIRED_FEEDBACK_FIELDS:
        value = entry.get(field_name)
        if not _normalize_text(value):
            missing_fields.append(field_name)

    return len(missing_fields) == 0, missing_fields


def validate_feedback_entry_or_raise(entry: Dict[str, Any]) -> Dict[str, Any]:
    """Raise ValueError when required fields are missing (append-time guard)."""
    is_valid, missing_fields = validate_feedback_entry(entry)
    if is_valid:
        return entry

    missing_summary = ", ".join(missing_fields) if missing_fields else "invalid_entry"
    raise ValueError(f"feedback entry missing required fields: {missing_summary}")


def resolve_target(parent_cmd_id: Optional[str], task_id: Optional[str]) -> str:
    """Resolve target with parent_cmd_id priority, then task_id, else unknown."""
    parent = _normalize_target_value(parent_cmd_id)
    if parent:
        return parent

    task = _normalize_target_value(task_id)
    if task:
        return task

    return "unknown"


__all__ = [
    "validate_feedback_entry",
    "validate_feedback_entry_or_raise",
    "resolve_target",
    "REQUIRED_FEEDBACK_FIELDS",
]
