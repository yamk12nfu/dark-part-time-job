"""Append-only JSONL event logger for orchestrator runtime events."""

from __future__ import annotations

import errno
import json
import os
import sys
import time
from datetime import datetime
from typing import Any, Dict, Optional

_APPEND_RETRY_COUNT = 3
_APPEND_RETRY_DELAY_SEC = 0.05


class _PartialWriteError(OSError):
    """Raised when append fails after writing only part of a payload."""


def _warn(message: str) -> None:
    print(f"warning: event_logger: {message}", file=sys.stderr)


def _remove_none(obj: Any) -> Any:
    if isinstance(obj, dict):
        return {key: _remove_none(value) for key, value in obj.items() if value is not None}
    if isinstance(obj, list):
        return [_remove_none(value) for value in obj if value is not None]
    return obj


def _contains_parent_reference(path: str) -> bool:
    normalized = path.replace("\\", "/")
    return any(part == ".." for part in normalized.split("/"))


def _assert_no_symlink_components(path: str) -> None:
    abs_path = os.path.abspath(path)
    drive, tail = os.path.splitdrive(abs_path)
    parts = [part for part in tail.split(os.sep) if part]

    current = drive + os.sep if drive else os.sep
    for part in parts:
        current = os.path.join(current, part)
        if os.path.lexists(current) and os.path.islink(current):
            raise ValueError(f"symlink path component is not allowed: {current}")


def _normalize_and_validate_events_path(events_path: str) -> str:
    if not isinstance(events_path, str) or not events_path.strip():
        raise ValueError("events_path must be a non-empty string")
    if _contains_parent_reference(events_path):
        raise ValueError("parent directory traversal is not allowed in events_path")

    normalized_path = os.path.abspath(os.path.normpath(events_path))
    parent_dir = os.path.dirname(normalized_path)
    if not parent_dir:
        raise ValueError("events_path must include a parent directory")

    _assert_no_symlink_components(parent_dir)
    os.makedirs(parent_dir, exist_ok=True)
    _assert_no_symlink_components(parent_dir)

    if os.path.lexists(normalized_path) and os.path.islink(normalized_path):
        raise ValueError(f"events_path must not be a symlink: {normalized_path}")

    return normalized_path


def _open_trusted_parent_dir_fd(parent_dir: str) -> int:
    if not hasattr(os, "O_DIRECTORY"):
        raise OSError("O_DIRECTORY is required for secure parent directory handling")
    if not hasattr(os, "O_NOFOLLOW"):
        raise OSError("O_NOFOLLOW is required for secure parent directory handling")

    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    return os.open(parent_dir, flags)


class EventLogger:
    def __init__(self, events_path: str):
        self.events_path = _normalize_and_validate_events_path(events_path)
        self._trusted_parent_dir = os.path.dirname(self.events_path)
        self._events_filename = os.path.basename(self.events_path)
        if not self._events_filename:
            raise ValueError("events_path must include a file name")
        self._trusted_parent_fd = _open_trusted_parent_dir_fd(self._trusted_parent_dir)

    def _validate_runtime_path(self) -> None:
        normalized_path = os.path.abspath(os.path.normpath(self.events_path))
        if normalized_path != self.events_path:
            raise ValueError("events_path changed outside trusted normalization")
        if os.path.dirname(normalized_path) != self._trusted_parent_dir:
            raise ValueError("events_path escaped trusted parent directory")
        if self._trusted_parent_fd < 0:
            raise ValueError("trusted parent directory descriptor is closed")

    def _append_atomic(self, payload: bytes) -> None:
        flags = os.O_APPEND | os.O_CREAT | os.O_WRONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW

        fd = os.open(self._events_filename, flags, 0o644, dir_fd=self._trusted_parent_fd)
        try:
            total_written = 0
            while total_written < len(payload):
                try:
                    written = os.write(fd, payload[total_written:])
                except OSError as exc:
                    if exc.errno == errno.EINTR:
                        continue
                    if total_written > 0:
                        raise _PartialWriteError(
                            f"append interrupted after {total_written} of {len(payload)} bytes: {exc}"
                        ) from exc
                    raise
                if written <= 0:
                    zero_progress_error = OSError(f"short write with no progress: wrote {written} bytes")
                    if total_written > 0:
                        raise _PartialWriteError(
                            f"append interrupted after {total_written} of {len(payload)} bytes: "
                            f"{zero_progress_error}"
                        ) from zero_progress_error
                    raise zero_progress_error
                total_written += written
        finally:
            os.close(fd)

    def _append_with_retry(self, payload: bytes) -> None:
        last_error: Optional[OSError] = None

        for attempt in range(1, _APPEND_RETRY_COUNT + 1):
            try:
                self._validate_runtime_path()
                self._append_atomic(payload)
                return
            except _PartialWriteError as exc:
                _warn(
                    f"append failed after partial write for '{self.events_path}' "
                    f"(fail-closed, no retry): {exc}"
                )
                raise
            except OSError as exc:
                last_error = exc
                if attempt < _APPEND_RETRY_COUNT:
                    _warn(
                        f"append attempt {attempt}/{_APPEND_RETRY_COUNT} failed for "
                        f"'{self.events_path}': {exc}; retrying"
                    )
                    time.sleep(_APPEND_RETRY_DELAY_SEC * attempt)
                else:
                    _warn(
                        f"append failed after {attempt} attempts for '{self.events_path}' "
                        f"(fail-closed): {exc}"
                    )

        if last_error is not None:
            raise last_error

    def close(self) -> None:
        if self._trusted_parent_fd >= 0:
            os.close(self._trusted_parent_fd)
            self._trusted_parent_fd = -1

    def __del__(self) -> None:
        try:
            self.close()
        except Exception:
            pass

    def log(
        self,
        event_type: str,
        *,
        cmd_id: Optional[str] = None,
        task_id: Optional[str] = None,
        role: Optional[str] = None,
        pane_id: Optional[str] = None,
        details: Optional[Dict[str, Any]] = None,
    ) -> None:
        payload: Dict[str, Any] = {
            "timestamp": datetime.now().isoformat(),
            "event_type": event_type,
            "cmd_id": cmd_id,
            "task_id": task_id,
            "role": role,
            "pane_id": pane_id,
        }

        if details is not None:
            cleaned_details = _remove_none(details)
            if cleaned_details:
                payload["details"] = cleaned_details

        event_payload = _remove_none(payload)

        try:
            event_json = json.dumps(event_payload, ensure_ascii=False, separators=(",", ":"))
        except (TypeError, ValueError) as exc:
            _warn(f"dropping unserializable event '{event_type}': {exc}")
            return

        try:
            self._append_with_retry((event_json + "\n").encode("utf-8"))
        except Exception as exc:
            _warn(f"failed to append event to '{self.events_path}': {exc}")
            raise

    def log_transition(
        self,
        task_id: str,
        from_phase: str,
        to_phase: str,
        role: str,
        trigger_signal: Optional[Dict[str, Any]] = None,
    ) -> None:
        self.log(
            "transition",
            task_id=task_id,
            role=role,
            details={
                "from_phase": from_phase,
                "to_phase": to_phase,
                "trigger_signal": trigger_signal,
            },
        )

    def log_dispatch(
        self,
        task_id: str,
        role: str,
        pane_id: str,
        command: Optional[str] = None,
    ) -> None:
        self.log(
            "dispatch",
            task_id=task_id,
            role=role,
            pane_id=pane_id,
            details={
                "command": command,
            },
        )

    def log_signal_received(self, task_id: str, role: str, sig_hash: str, accepted: bool) -> None:
        self.log(
            "signal_received",
            task_id=task_id,
            role=role,
            details={
                "sig_hash": sig_hash,
                "accepted": accepted,
            },
        )

    def log_error(self, task_id: str, error_type: str, message: str, role: Optional[str] = None) -> None:
        self.log(
            "error",
            task_id=task_id,
            role=role,
            details={
                "error_type": error_type,
                "message": message,
            },
        )

    def log_escalation(self, task_id: str, reason: str, target: str = "oyabun") -> None:
        self.log(
            "escalation",
            task_id=task_id,
            details={
                "reason": reason,
                "target": target,
            },
        )


__all__ = ["EventLogger"]
