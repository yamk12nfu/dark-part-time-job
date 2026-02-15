"""Common loader/writer for panes*.json schema v1/v2.

Usage from scripts under ORCH_ROOT:
    import os, sys
    ORCH_ROOT = os.environ["ORCH_ROOT"]
    sys.path.insert(0, os.path.join(ORCH_ROOT, "scripts"))
    from lib.panes import load_panes, dump_panes_v2
"""

from __future__ import annotations

import copy
import json
import os
import sys
from typing import Any, Dict

DEFAULT_PANES_V2: Dict[str, Any] = {
    "schema_version": 2,
    "session": "",
    "repo_root": "",
    "worktree": {"enabled": False, "root": "", "branch": ""},
    "work_dir": "",
    "queue_dir": "",
    "oyabun": "",
    "waka": "",
    "workers": {},
    "worker_names": {},
}


def _warn(message: str) -> None:
    print(f"warning: {message}", file=sys.stderr)


def _default_panes_v2() -> Dict[str, Any]:
    return copy.deepcopy(DEFAULT_PANES_V2)


def _to_text(value: Any) -> str:
    return value if isinstance(value, str) else ""


def normalize_panes(data: dict) -> dict:
    """Normalize legacy panes data into schema v2."""
    if not isinstance(data, dict):
        return _default_panes_v2()

    normalized: Dict[str, Any] = dict(data)

    root_raw = normalized.get("worktree_root")
    branch_raw = normalized.get("worktree_branch")

    root = root_raw if isinstance(root_raw, str) else ""
    branch = branch_raw if isinstance(branch_raw, str) else ""
    enabled = bool(root or branch)

    normalized.pop("worktree_root", None)
    normalized.pop("worktree_branch", None)

    normalized["schema_version"] = 2
    normalized["worktree"] = {
        "enabled": enabled,
        "root": root,
        "branch": branch,
    }

    return normalized


def load_panes(path: str) -> dict:
    """Load panes JSON with v1/v2 compatibility and safe fallback."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except json.JSONDecodeError as exc:
        _warn(f"failed to decode panes JSON ({path}): {exc}")
        return _default_panes_v2()
    except OSError as exc:
        _warn(f"failed to read panes JSON ({path}): {exc}")
        return _default_panes_v2()

    if not isinstance(data, dict):
        _warn(f"panes JSON is not an object ({path}); using defaults")
        return _default_panes_v2()

    schema_version = data.get("schema_version")
    if schema_version == 2:
        wt = data.get("worktree")
        if not isinstance(wt, dict):
            data["worktree"] = {"enabled": False, "root": "", "branch": ""}
        else:
            wt.setdefault("enabled", False)
            wt.setdefault("root", "")
            wt.setdefault("branch", "")
            if not isinstance(wt["enabled"], bool):
                wt["enabled"] = False
            if not isinstance(wt["root"], str):
                wt["root"] = ""
            if not isinstance(wt["branch"], str):
                wt["branch"] = ""
        return data
    if schema_version in (None, 1):
        return normalize_panes(data)

    _warn(f"unknown schema_version={schema_version!r} in {path}; returning as-is")
    return data


def dump_panes_v2(path: str, data: dict) -> None:
    """Write panes JSON in schema v2 with temporary flat-key compatibility."""
    base: Dict[str, Any] = dict(data) if isinstance(data, dict) else {}

    if isinstance(base.get("worktree"), dict):
        worktree_in = base.get("worktree", {})
        enabled = bool(worktree_in.get("enabled", False))
        root = _to_text(worktree_in.get("root"))
        branch = _to_text(worktree_in.get("branch"))
        if not enabled:
            root = ""
            branch = ""
        worktree = {"enabled": enabled, "root": root, "branch": branch}
        base["schema_version"] = 2
        base["worktree"] = worktree
    else:
        base = normalize_panes(base)
        worktree = base["worktree"]

    if worktree.get("enabled"):
        base["worktree_root"] = _to_text(worktree.get("root"))
        base["worktree_branch"] = _to_text(worktree.get("branch"))
    else:
        base["worktree_root"] = ""
        base["worktree_branch"] = ""

    base["schema_version"] = 2

    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)

    with open(path, "w", encoding="utf-8") as f:
        json.dump(base, f, ensure_ascii=False, indent=2)
        f.write("\n")


__all__ = ["load_panes", "normalize_panes", "dump_panes_v2", "DEFAULT_PANES_V2"]
