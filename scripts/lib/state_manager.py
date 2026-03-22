"""State persistence and mutation helpers for orchestrator runtime."""

from __future__ import annotations

import copy
import json
import os
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, Optional

try:
    import fcntl
except ImportError:  # pragma: no cover - non-POSIX fallback
    fcntl = None


@dataclass(frozen=True)
class LockAcquireResult:
    acquired: bool
    reason: str
    lock_path: str
    waited_sec: float = 0.0
    stale_recovered: bool = False

    def __bool__(self) -> bool:
        return self.acquired


class StateManager:
    """Manage orchestrator-state.json load/save and in-memory mutations."""

    STATE_FILENAME = "orchestrator-state.json"
    LOCKS_DIRNAME = "orchestrator-locks"
    DEFAULT_LOCK_TIMEOUT_SEC = 0.0
    DEFAULT_STALE_LOCK_TIMEOUT_SEC = 300.0
    DEFAULT_LOCK_POLL_INTERVAL_SEC = 0.1

    def __init__(self, state_dir: str, max_signals: int = 2000):
        self.state_dir = state_dir
        self.state_path = os.path.join(state_dir, self.STATE_FILENAME)
        self.locks_dir = os.path.join(state_dir, self.LOCKS_DIRNAME)
        self.max_signals = max(1, int(max_signals))
        self._state: Dict[str, Any] = self.get_default_state()
        self._held_lock_tokens: Dict[str, str] = {}

        os.makedirs(self.state_dir, exist_ok=True)
        os.makedirs(self.locks_dir, exist_ok=True)
        self.load()

    @classmethod
    def get_default_state(cls) -> Dict[str, Any]:
        return {
            "schema_version": 1,
            "mode": "hybrid",
            "poll_interval_sec": 5,
            "lastTimestampByTaskPane": {},
            "processedSignals": [],
            "taskState": {},
            "locks": {
                "dispatch": False,
                "collect": False,
            },
            "version": "v2-alpha",
        }

    def _normalize_state(self, data: Any) -> Dict[str, Any]:
        if not isinstance(data, dict):
            return self.get_default_state()

        normalized = self.get_default_state()
        normalized.update(data)

        if not isinstance(normalized.get("lastTimestampByTaskPane"), dict):
            normalized["lastTimestampByTaskPane"] = {}
        if not isinstance(normalized.get("processedSignals"), list):
            normalized["processedSignals"] = []
        if not isinstance(normalized.get("taskState"), dict):
            normalized["taskState"] = {}

        locks = normalized.get("locks")
        if not isinstance(locks, dict):
            locks = {}
        merged_locks = {"dispatch": False, "collect": False}
        for key, value in locks.items():
            merged_locks[str(key)] = bool(value)
        normalized["locks"] = merged_locks

        return normalized

    def _get_locks_table(self) -> Dict[str, bool]:
        locks = self._state.get("locks")
        if not isinstance(locks, dict):
            locks = {}
            self._state["locks"] = locks
        return locks

    def _lock_path(self, lock_name: str) -> str:
        return os.path.join(self.locks_dir, f"{lock_name}.lock")

    def _set_lock_state(self, lock_name: str, is_locked: bool) -> None:
        locks = self._get_locks_table()
        locks[lock_name] = bool(is_locked)

    def _sync_lock_states_from_runtime(self) -> None:
        os.makedirs(self.locks_dir, exist_ok=True)
        locks = self._get_locks_table()
        keys = [str(key) for key in locks.keys()]
        for key in keys:
            locks[key] = os.path.exists(self._lock_path(key))

    def _coerce_non_negative_float(self, value: Any, default: float) -> float:
        try:
            parsed = float(value)
        except (TypeError, ValueError):
            return max(0.0, default)
        return parsed if parsed >= 0.0 else 0.0

    @staticmethod
    def _write_all(fd: int, payload: bytes) -> None:
        view = memoryview(payload)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise OSError("short write while creating lock file")
            view = view[written:]

    def _create_lock_file(self, lock_path: str, payload: Dict[str, Any]) -> None:
        lock_fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        payload_bytes = (json.dumps(payload, ensure_ascii=False) + "\n").encode("utf-8")
        try:
            self._write_all(lock_fd, payload_bytes)
            os.fsync(lock_fd)
        except Exception:
            try:
                os.close(lock_fd)
            except OSError:
                pass
            try:
                os.unlink(lock_path)
            except FileNotFoundError:
                pass
            except OSError:
                pass
            raise
        else:
            try:
                os.close(lock_fd)
            except OSError:
                pass

    @staticmethod
    def _parse_lock_payload(lock_path: str) -> Optional[Dict[str, Any]]:
        try:
            with open(lock_path, "r", encoding="utf-8") as f:
                payload = json.load(f)
        except (OSError, json.JSONDecodeError):
            return None
        if not isinstance(payload, dict):
            return None
        return payload

    @staticmethod
    def _lock_age_sec(lock_path: str, payload: Optional[Dict[str, Any]]) -> Optional[float]:
        if isinstance(payload, dict):
            epoch = payload.get("acquired_at_epoch")
            if isinstance(epoch, (int, float)):
                return max(0.0, time.time() - float(epoch))
        try:
            return max(0.0, time.time() - os.path.getmtime(lock_path))
        except OSError:
            return None

    @staticmethod
    def _pid_is_alive(pid: int) -> bool:
        if pid <= 0:
            return False
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        except OSError:
            return False
        return True

    @staticmethod
    def _try_acquire_cleanup_guard(lock_fd: int) -> bool:
        if fcntl is None:
            return True
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        except OSError:
            return False
        return True

    def _is_stale_lock(
        self,
        lock_path: str,
        payload: Optional[Dict[str, Any]],
        *,
        stale_timeout_sec: float,
    ) -> bool:
        owner_pid: Optional[int] = None
        if isinstance(payload, dict):
            owner_pid_raw = payload.get("owner_pid")
            if isinstance(owner_pid_raw, int):
                owner_pid = owner_pid_raw

        if owner_pid is not None and owner_pid > 0 and not self._pid_is_alive(owner_pid):
            return True

        if stale_timeout_sec <= 0.0:
            return False

        age = self._lock_age_sec(lock_path, payload)
        if age is None or age < stale_timeout_sec or age < 1.0:
            return False

        if owner_pid is None or owner_pid <= 0:
            return True
        return not self._pid_is_alive(owner_pid)

    def _cleanup_stale_lock(self, lock_path: str, *, stale_timeout_sec: float) -> bool:
        try:
            lock_fd = os.open(lock_path, os.O_RDONLY)
        except FileNotFoundError:
            return True
        except OSError:
            return False

        try:
            if not self._try_acquire_cleanup_guard(lock_fd):
                return False

            try:
                stale_inode = os.fstat(lock_fd).st_ino
            except OSError:
                return False

            payload = self._parse_lock_payload(lock_path)
            if not self._is_stale_lock(lock_path, payload, stale_timeout_sec=stale_timeout_sec):
                return False

            stale_token = payload.get("token") if isinstance(payload, dict) else None
            current_payload = self._parse_lock_payload(lock_path)
            current_token = (
                current_payload.get("token") if isinstance(current_payload, dict) else None
            )

            try:
                current_inode = os.stat(lock_path).st_ino
            except FileNotFoundError:
                return True
            except OSError:
                return False

            if current_inode != stale_inode:
                return False
            if stale_token is not None and current_token != stale_token:
                return False

            try:
                os.unlink(lock_path)
            except FileNotFoundError:
                return True
            except OSError:
                return False
            return True
        finally:
            try:
                os.close(lock_fd)
            except OSError:
                pass

    def load(self) -> Dict[str, Any]:
        if os.path.exists(self.state_path):
            try:
                with open(self.state_path, "r", encoding="utf-8") as f:
                    loaded = json.load(f)
            except (OSError, json.JSONDecodeError):
                loaded = self.get_default_state()
        else:
            loaded = self.get_default_state()

        self._state = self._normalize_state(loaded)
        self._sync_lock_states_from_runtime()
        return self._state

    def save(self) -> None:
        os.makedirs(self.state_dir, exist_ok=True)
        os.makedirs(self.locks_dir, exist_ok=True)
        self._sync_lock_states_from_runtime()
        tmp_path = ""
        replaced = False

        try:
            import tempfile

            with tempfile.NamedTemporaryFile(
                "w",
                encoding="utf-8",
                dir=self.state_dir,
                prefix=".state-",
                suffix=".tmp",
                delete=False,
            ) as f:
                tmp_path = f.name
                json.dump(self._state, f, indent=2, ensure_ascii=False)
                f.write("\n")
                f.flush()
                os.fsync(f.fileno())

            os.replace(tmp_path, self.state_path)
            replaced = True

            state_parent_dir = os.path.dirname(self.state_path) or self.state_dir
            dir_flags = os.O_RDONLY
            if hasattr(os, "O_DIRECTORY"):
                dir_flags |= os.O_DIRECTORY
            dir_fd = os.open(state_parent_dir, dir_flags)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
        except Exception:
            if tmp_path and not replaced:
                try:
                    os.unlink(tmp_path)
                except FileNotFoundError:
                    pass
                except OSError:
                    pass
            raise

    def is_duplicate_signal(self, sig_hash: str) -> bool:
        processed = self._state.get("processedSignals")
        if not isinstance(processed, list):
            return False
        return sig_hash in processed

    def add_processed_signal(self, sig_hash: str) -> None:
        processed = self._state.get("processedSignals")
        if not isinstance(processed, list):
            processed = []
            self._state["processedSignals"] = processed

        processed.append(sig_hash)
        overflow = len(processed) - self.max_signals
        if overflow > 0:
            del processed[:overflow]

    def check_timestamp_guard(self, task_pane_key: str, ts_ms: int) -> bool:
        table = self._state.get("lastTimestampByTaskPane")
        if not isinstance(table, dict):
            table = {}
            self._state["lastTimestampByTaskPane"] = table

        existing = table.get(task_pane_key)
        if isinstance(existing, int) and ts_ms <= existing:
            return False
        return True

    def update_timestamp(self, task_pane_key: str, ts_ms: int) -> None:
        table = self._state.get("lastTimestampByTaskPane")
        if not isinstance(table, dict):
            table = {}
            self._state["lastTimestampByTaskPane"] = table
        table[task_pane_key] = ts_ms

    def get_task_state(self, task_id: str) -> Optional[Dict[str, Any]]:
        task_state = self._state.get("taskState")
        if not isinstance(task_state, dict):
            return None

        entry = task_state.get(task_id)
        if not isinstance(entry, dict):
            return None

        return entry

    def update_task_state(
        self,
        task_id: str,
        *,
        phase: str,
        loop_count: int,
        assigned_worker: str,
        **extra: Any,
    ) -> None:
        task_state = self._state.get("taskState")
        if not isinstance(task_state, dict):
            task_state = {}
            self._state["taskState"] = task_state

        current = task_state.get(task_id)
        next_state: Dict[str, Any] = copy.deepcopy(current) if isinstance(current, dict) else {}
        next_state.update(
            {
                "phase": phase,
                "loop_count": loop_count,
                "assigned_worker": assigned_worker,
                "updated_at": datetime.now().isoformat(),
            }
        )
        if extra:
            next_state.update(extra)

        task_state[task_id] = next_state

    def remove_task_state(self, task_id: str) -> None:
        task_state = self._state.get("taskState")
        if not isinstance(task_state, dict):
            return
        task_state.pop(task_id, None)

    def acquire_lock(
        self,
        lock_name: str,
        *,
        timeout_sec: float = DEFAULT_LOCK_TIMEOUT_SEC,
        stale_timeout_sec: float = DEFAULT_STALE_LOCK_TIMEOUT_SEC,
        poll_interval_sec: float = DEFAULT_LOCK_POLL_INTERVAL_SEC,
    ) -> LockAcquireResult:
        lock_name = str(lock_name)
        os.makedirs(self.locks_dir, exist_ok=True)
        lock_path = self._lock_path(lock_name)

        if lock_name in self._held_lock_tokens:
            return LockAcquireResult(
                acquired=False,
                reason="already_held",
                lock_path=lock_path,
                waited_sec=0.0,
                stale_recovered=False,
            )

        timeout_sec = self._coerce_non_negative_float(timeout_sec, self.DEFAULT_LOCK_TIMEOUT_SEC)
        stale_timeout_sec = self._coerce_non_negative_float(
            stale_timeout_sec,
            self.DEFAULT_STALE_LOCK_TIMEOUT_SEC,
        )
        poll_interval_sec = max(
            0.01,
            self._coerce_non_negative_float(poll_interval_sec, self.DEFAULT_LOCK_POLL_INTERVAL_SEC),
        )

        start = time.monotonic()
        deadline = start + timeout_sec
        stale_recovered = False

        while True:
            token = uuid.uuid4().hex
            payload = {
                "schema_version": 1,
                "lock_name": lock_name,
                "owner_pid": os.getpid(),
                "token": token,
                "acquired_at": datetime.now(timezone.utc).isoformat(),
                "acquired_at_epoch": time.time(),
            }

            try:
                self._create_lock_file(lock_path, payload)
                self._held_lock_tokens[lock_name] = token
                self._set_lock_state(lock_name, True)
                reason = "acquired_after_stale_recovery" if stale_recovered else "acquired"
                return LockAcquireResult(
                    acquired=True,
                    reason=reason,
                    lock_path=lock_path,
                    waited_sec=time.monotonic() - start,
                    stale_recovered=stale_recovered,
                )
            except FileExistsError:
                if self._cleanup_stale_lock(lock_path, stale_timeout_sec=stale_timeout_sec):
                    stale_recovered = True
                    continue

                now = time.monotonic()
                if now >= deadline:
                    self._set_lock_state(lock_name, os.path.exists(lock_path))
                    reason = "timeout" if timeout_sec > 0.0 else "busy"
                    return LockAcquireResult(
                        acquired=False,
                        reason=reason,
                        lock_path=lock_path,
                        waited_sec=now - start,
                        stale_recovered=stale_recovered,
                    )
                time.sleep(poll_interval_sec)

    def release_lock(self, lock_name: str) -> None:
        lock_name = str(lock_name)
        lock_path = self._lock_path(lock_name)
        token = self._held_lock_tokens.pop(lock_name, None)

        if token is not None:
            payload = self._parse_lock_payload(lock_path)
            payload_token = payload.get("token") if isinstance(payload, dict) else None
            payload_pid = payload.get("owner_pid") if isinstance(payload, dict) else None

            if payload_token == token and payload_pid == os.getpid():
                try:
                    os.unlink(lock_path)
                except FileNotFoundError:
                    pass
                except OSError:
                    pass

        self._set_lock_state(lock_name, os.path.exists(lock_path))

    @property
    def state(self) -> Dict[str, Any]:
        return self._state


__all__ = ["LockAcquireResult", "StateManager"]
