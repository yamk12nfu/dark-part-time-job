"""Utilities for parsing, validating, and hashing orchestrator JSON signals."""

from __future__ import annotations

import hashlib
import json
from typing import Any, Dict, List, Optional, Tuple

_COMMON_REQUIRED_KEYS = ("mission", "task_id", "role")
_ALLOWED_MISSIONS = {"completed", "error"}
_ALLOWED_ROLES = {"planner", "architect", "implementer", "reviewer", "quality-gate"}
_ALLOWED_REVIEW_DECISIONS = {"approve", "rework"}


def _to_text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def _has_value(value: Any) -> bool:
    text = _to_text(value)
    if not text:
        return False
    return text.lower() != "null"


def _parse_int(value: Any) -> Optional[int]:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int):
        return value
    try:
        return int(str(value).strip())
    except (TypeError, ValueError):
        return None


def _collect_json_object_ranges(text: str) -> List[Tuple[int, int]]:
    ranges: List[Tuple[int, int]] = []
    stack: List[int] = []
    in_string = False
    escaped = False

    for idx, ch in enumerate(text):
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue

        if ch == '"':
            in_string = True
            escaped = False
            continue

        if ch == "{":
            stack.append(idx)
            continue

        if ch == "}" and stack:
            ranges.append((stack.pop(), idx))

    return ranges


def _extract_json_object_from_text(text: str) -> Optional[dict]:
    if not text:
        return None

    ranges = _collect_json_object_ranges(text)
    if not ranges:
        return None

    start_idx, end_idx = ranges[-1]
    candidate = text[start_idx : end_idx + 1]
    try:
        parsed = json.loads(candidate)
    except json.JSONDecodeError:
        return None

    if isinstance(parsed, dict):
        return parsed

    return None


def extract_last_json_object(text: str) -> Optional[dict]:
    """Extract the latest JSON object from the trailing pane text."""
    if not isinstance(text, str) or not text.strip():
        return None

    lines = text.splitlines()
    if not lines:
        return _extract_json_object_from_text(text)

    if len(lines) >= 5:
        tail_count = min(20, len(lines))
    else:
        tail_count = len(lines)

    tail_text = "\n".join(lines[-tail_count:])
    return _extract_json_object_from_text(tail_text)


def _require_status(signal_dict: Dict[str, Any], expected: str, role: str, mission: str, errors: List[str]) -> None:
    actual = _to_text(signal_dict.get("status"))
    if actual != expected:
        errors.append(
            f"{role} mission={mission} requires status='{expected}' (got '{actual or '<missing>'}')"
        )


def _require_reason(signal_dict: Dict[str, Any], role: str, mission: str, errors: List[str]) -> None:
    if not _has_value(signal_dict.get("reason")):
        errors.append(f"{role} mission={mission} requires non-empty reason")


def _validate_planner(signal_dict: Dict[str, Any], mission: str, errors: List[str]) -> None:
    if mission == "completed":
        _require_status(signal_dict, "tasks_ready", "planner", mission, errors)
        task_count = _parse_int(signal_dict.get("task_count"))
        if task_count is None or task_count < 1:
            errors.append("planner mission=completed requires task_count >= 1")
        return

    _require_status(signal_dict, "planning_blocker", "planner", mission, errors)
    _require_reason(signal_dict, "planner", mission, errors)


def _validate_architect(signal_dict: Dict[str, Any], mission: str, errors: List[str]) -> None:
    if mission == "completed":
        _require_status(signal_dict, "design_ready", "architect", mission, errors)
        return

    _require_status(signal_dict, "design_questions", "architect", mission, errors)
    _require_reason(signal_dict, "architect", mission, errors)


def _validate_implementer(signal_dict: Dict[str, Any], mission: str, errors: List[str]) -> None:
    if mission == "completed":
        _require_status(signal_dict, "done", "implementer", mission, errors)
        if not (_has_value(signal_dict.get("worker_id")) or _has_value(signal_dict.get("pane_id"))):
            errors.append("implementer mission=completed requires worker_id or pane_id")
        return

    _require_status(signal_dict, "needs_architect", "implementer", mission, errors)
    _require_reason(signal_dict, "implementer", mission, errors)


def _validate_reviewer(signal_dict: Dict[str, Any], mission: str, errors: List[str]) -> None:
    if mission == "completed":
        _require_status(signal_dict, "done", "reviewer", mission, errors)
        findings = signal_dict.get("findings")
        if not isinstance(findings, list):
            errors.append("reviewer mission=completed requires findings as list")

        recommendation = _to_text(signal_dict.get("recommendation"))
        if recommendation not in _ALLOWED_REVIEW_DECISIONS:
            errors.append("reviewer mission=completed requires recommendation in {'approve','rework'}")
        return

    _require_status(signal_dict, "review_input_error", "reviewer", mission, errors)
    _require_reason(signal_dict, "reviewer", mission, errors)


def _validate_quality_gate(signal_dict: Dict[str, Any], mission: str, errors: List[str]) -> None:
    if mission == "completed":
        result = _to_text(signal_dict.get("result"))
        if result not in _ALLOWED_REVIEW_DECISIONS:
            errors.append("quality-gate mission=completed requires result in {'approve','rework'}")
        _require_reason(signal_dict, "quality-gate", mission, errors)
        return

    _require_status(signal_dict, "gate_blocked", "quality-gate", mission, errors)
    _require_reason(signal_dict, "quality-gate", mission, errors)


def validate_signal(signal_dict: dict, role: str) -> Tuple[bool, List[str]]:
    """Validate signal dictionary by role and mission rules."""
    if not isinstance(signal_dict, dict):
        return False, ["signal must be a dict"]

    errors: List[str] = []

    for key in _COMMON_REQUIRED_KEYS:
        if not _has_value(signal_dict.get(key)):
            errors.append(f"missing required key: {key}")

    mission = _to_text(signal_dict.get("mission"))
    if mission not in _ALLOWED_MISSIONS:
        errors.append("mission must be 'completed' or 'error'")

    expected_role = _to_text(role)
    signal_role = _to_text(signal_dict.get("role"))

    if expected_role and signal_role and expected_role != signal_role:
        errors.append(f"role mismatch: expected '{expected_role}', got '{signal_role}'")

    active_role = expected_role or signal_role
    if active_role not in _ALLOWED_ROLES:
        errors.append(f"unsupported role: '{active_role or '<missing>'}'")
        return False, errors

    if mission not in _ALLOWED_MISSIONS:
        return False, errors

    validators = {
        "planner": _validate_planner,
        "architect": _validate_architect,
        "implementer": _validate_implementer,
        "reviewer": _validate_reviewer,
        "quality-gate": _validate_quality_gate,
    }
    validators[active_role](signal_dict, mission, errors)

    return len(errors) == 0, errors


def normalize_timestamp(signal_dict: dict) -> dict:
    """Return a copied signal dict with normalized ts_ms."""
    normalized: Dict[str, Any] = dict(signal_dict) if isinstance(signal_dict, dict) else {}

    ts_ms = _parse_int(normalized.get("ts_ms"))
    if ts_ms is not None:
        normalized["ts_ms"] = ts_ms
        return normalized

    ts = _parse_int(normalized.get("ts"))
    if ts is not None:
        normalized["ts_ms"] = ts * 1000
        return normalized

    normalized["ts_ms"] = 0
    return normalized


def compute_sig_hash(signal_dict: dict, raw_json: str = "") -> str:
    """Compute signal hash from key fields and raw JSON text."""
    source: Dict[str, Any] = dict(signal_dict) if isinstance(signal_dict, dict) else {}
    ts_ms = _parse_int(source.get("ts_ms"))
    if ts_ms is None:
        ts_ms = 0

    json_text = raw_json if isinstance(raw_json, str) and raw_json != "" else json.dumps(
        source, sort_keys=True, separators=(",", ":")
    )
    payload = (
        _to_text(source.get("task_id"))
        + _to_text(source.get("pane_id"))
        + _to_text(source.get("role"))
        + str(ts_ms)
        + json_text
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


__all__ = [
    "extract_last_json_object",
    "validate_signal",
    "normalize_timestamp",
    "compute_sig_hash",
]
