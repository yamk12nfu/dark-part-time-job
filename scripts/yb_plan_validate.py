#!/usr/bin/env python3
"""Static validator for yb plan-review inputs."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Set, Tuple

try:
    import yaml
except ImportError:
    yaml = None

H2_RE = re.compile(r"^\s*##\s+(.+?)\s*$")
SUB_HEADING_RE = re.compile(r"^\s*#{3,6}\s+(.+?)\s*$")


def normalize_heading(text: str) -> str:
    text = text.strip()
    text = re.sub(r"\s+#+$", "", text)
    text = text.replace("：", ":")
    text = text.replace("（", "(").replace("）", ")")
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"\s*/\s*", "/", text)
    return text.lower().strip()


def heading_matches(title: str, aliases: Sequence[str]) -> bool:
    normalized = normalize_heading(title)
    for alias in aliases:
        alias_norm = normalize_heading(alias)
        if (
            normalized == alias_norm
            or normalized.startswith(alias_norm + ":")
            or normalized.startswith(alias_norm + " ")
            or normalized.startswith(alias_norm + " -")
            or normalized.startswith(alias_norm + " /")
            or normalized.startswith(alias_norm + "(")
        ):
            return True
    return False


def parse_level2_sections(content: str) -> List[Dict[str, object]]:
    sections: List[Dict[str, object]] = []
    current: Optional[Dict[str, object]] = None

    for line in content.splitlines():
        heading_match = H2_RE.match(line)
        if heading_match:
            if current is not None:
                sections.append(current)
            current = {
                "title": heading_match.group(1).strip(),
                "body": [],
            }
            continue

        if current is not None:
            body = current["body"]
            assert isinstance(body, list)
            body.append(line)

    if current is not None:
        sections.append(current)
    return sections


def find_sections(sections: Sequence[Dict[str, object]], aliases: Sequence[str]) -> List[Dict[str, object]]:
    matched: List[Dict[str, object]] = []
    for section in sections:
        title = section.get("title")
        if isinstance(title, str) and heading_matches(title, aliases):
            matched.append(section)
    return matched


def section_has_content(section: Dict[str, object]) -> bool:
    body = section.get("body")
    if not isinstance(body, list):
        return False
    for raw_line in body:
        if not isinstance(raw_line, str):
            continue
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("#"):
            continue
        return True
    return False


def section_subheadings(section: Dict[str, object]) -> List[str]:
    headings: List[str] = []
    body = section.get("body")
    if not isinstance(body, list):
        return headings

    for raw_line in body:
        if not isinstance(raw_line, str):
            continue
        match = SUB_HEADING_RE.match(raw_line)
        if match:
            headings.append(match.group(1).strip())
    return headings


def read_text_file(path: Path) -> Tuple[bool, str]:
    if not path.is_file():
        return False, f"{path.name}: ファイルが存在しません"

    try:
        return True, path.read_text(encoding="utf-8")
    except Exception as exc:  # pragma: no cover - defensive
        return False, f"{path.name}: 読み込み失敗: {exc}"


def validate_prd(prd_file: Path) -> Tuple[bool, str]:
    ok, content_or_error = read_text_file(prd_file)
    if not ok:
        return False, content_or_error

    sections = parse_level2_sections(content_or_error)

    required = [
        ("目的/背景", ["目的/背景", "目的", "背景", "purpose", "background"]),
        ("スコープ", ["スコープ", "scope"]),
        ("機能要件/FR", ["機能要件(fr)", "機能要件", "fr", "functional requirements"]),
        ("非機能要件/NFR", ["非機能要件(nfr)", "非機能要件", "nfr", "non-functional requirements"]),
        ("受け入れ条件/AC", ["受け入れ条件(acceptance criteria)", "受け入れ条件", "acceptance criteria", "ac"]),
        ("Open Questions/未決事項", ["open questions(未決事項)", "open questions", "未決事項"]),
    ]

    missing_sections: List[str] = []
    empty_sections: List[str] = []

    for label, aliases in required:
        matched_sections = find_sections(sections, aliases)
        if not matched_sections:
            missing_sections.append(label)
            continue
        if not any(section_has_content(section) for section in matched_sections):
            empty_sections.append(label)

    scope_sections = find_sections(sections, ["スコープ"])
    missing_scope_subsections: List[str] = []
    if scope_sections:
        subheadings: List[str] = []
        for scope_section in scope_sections:
            subheadings.extend(section_subheadings(scope_section))

        if not any(heading_matches(heading, ["In scope"]) for heading in subheadings):
            missing_scope_subsections.append("In scope")
        if not any(heading_matches(heading, ["Out of scope"]) for heading in subheadings):
            missing_scope_subsections.append("Out of scope")

    details: List[str] = []
    if missing_sections:
        details.append("必須セクション欠落: " + ", ".join(missing_sections))
    if empty_sections:
        details.append("本文不足: " + ", ".join(empty_sections))
    if missing_scope_subsections:
        details.append("スコープ配下サブセクション欠落: " + ", ".join(missing_scope_subsections))

    if details:
        return False, "PRD.md: " + " / ".join(details)

    return True, "PRD.md: 必須セクション OK"


def validate_spec(spec_file: Path) -> Tuple[bool, str]:
    ok, content_or_error = read_text_file(spec_file)
    if not ok:
        return False, content_or_error

    sections = parse_level2_sections(content_or_error)

    required = [
        ("アーキテクチャ/変更点", ["アーキテクチャ/変更点", "アーキテクチャ", "変更点", "architecture"]),
        ("インターフェース", ["インターフェース", "interface"]),
        ("タスク分解/実装タスク", ["実装タスク分解(若衆に渡す粒度)", "実装タスク分解", "タスク分解", "実装タスク", "task breakdown"]),
        ("テスト", ["テスト計画", "テスト", "test"]),
        ("ロールアウト/互換性", ["ロールアウト/互換性", "ロールアウト", "互換性", "rollout"]),
        ("リスク", ["リスクと対策", "リスク", "risk"]),
    ]

    missing_sections: List[str] = []
    for label, aliases in required:
        if not find_sections(sections, aliases):
            missing_sections.append(label)

    if missing_sections:
        return False, "SPEC.md: 必須セクション欠落: " + ", ".join(missing_sections)

    return True, "SPEC.md: 必須セクション OK"


def _task_label(task: object, index: int) -> str:
    if isinstance(task, dict):
        task_id = task.get("id")
        if isinstance(task_id, str) and task_id.strip():
            return f"task {task_id.strip()}"
    return f"task #{index + 1}"


def validate_tasks_structure(tasks_file: Path) -> Tuple[str, str, List[str], Optional[List[object]]]:
    if not tasks_file.is_file():
        return "FAIL", "tasks.yaml: ファイルが存在しません", ["tasks.yaml: ファイルが存在しません"], None

    try:
        raw_text = tasks_file.read_text(encoding="utf-8")
    except Exception as exc:  # pragma: no cover - defensive
        reason = f"tasks.yaml: 読み込み失敗: {exc}"
        return "FAIL", reason, [reason], None

    if not raw_text.strip():
        reason = "tasks.yaml: 空ファイルです"
        return "FAIL", reason, [reason], None

    if yaml is None:
        return "WARN", "tasks.yaml: PyYAML未インストール: 詳細チェックをスキップ", [], None

    try:
        loaded = yaml.safe_load(raw_text)
    except Exception as exc:
        reason = f"tasks.yaml: YAML parse 失敗: {exc}"
        return "FAIL", reason, [reason], None

    if not isinstance(loaded, dict):
        reason = "tasks.yaml: ルートはマップ形式である必要があります"
        return "FAIL", reason, [reason], None

    root_required = ["version", "epic", "objective", "requirements"]
    missing_root = [key for key in root_required if key not in loaded]
    if missing_root:
        reason = f"tasks.yaml: ルート必須キー欠落: {', '.join(missing_root)}"
        return "FAIL", reason, [reason], None

    tasks = loaded.get("tasks")
    if not isinstance(tasks, list):
        reason = "tasks.yaml: `tasks` キーが存在し、リストである必要があります"
        return "FAIL", reason, [reason], None

    reasons: List[str] = []
    requirements = loaded.get("requirements")
    if not isinstance(requirements, list):
        reason = "tasks.yaml: `requirements` キーが存在し、リストである必要があります"
        return "FAIL", reason, [reason], None

    req_required_keys = ["id", "title", "acceptance"]
    for index, requirement in enumerate(requirements):
        req_label = requirement.get("id", f"#{index + 1}") if isinstance(requirement, dict) else f"#{index + 1}"
        if not isinstance(requirement, dict):
            reasons.append(f"tasks.yaml: requirement {req_label} がマップ形式ではありません")
            continue
        for key in req_required_keys:
            if key not in requirement:
                reasons.append(f"tasks.yaml: requirement {req_label} に {key} がない")

    required_keys = ["id", "owner", "depends_on", "requirement_ids", "definition_of_done", "deliverables"]

    for index, task in enumerate(tasks):
        label = _task_label(task, index)
        if not isinstance(task, dict):
            reasons.append(f"tasks.yaml: {label} がマップ形式ではありません")
            continue

        for key in required_keys:
            if key not in task:
                reasons.append(f"tasks.yaml: {label} に {key} がない")

        if "owner" in task:
            owner = task.get("owner")
            if not isinstance(owner, str) or not owner.strip():
                reasons.append(f"tasks.yaml: {label} の owner が空文字列です")

        if "depends_on" in task and not isinstance(task.get("depends_on"), list):
            reasons.append(f"tasks.yaml: {label} の depends_on はリストである必要があります")

        if "definition_of_done" in task:
            definition_of_done = task.get("definition_of_done")
            if not isinstance(definition_of_done, list):
                reasons.append(f"tasks.yaml: {label} の definition_of_done はリストである必要があります")
            elif len(definition_of_done) == 0:
                reasons.append(f"tasks.yaml: {label} の definition_of_done が空です")

        if "deliverables" in task:
            deliverables = task.get("deliverables")
            if not isinstance(deliverables, list):
                reasons.append(f"tasks.yaml: {label} の deliverables はリストである必要があります")

        if "requirement_ids" in task:
            requirement_ids = task.get("requirement_ids")
            if not isinstance(requirement_ids, list):
                reasons.append(f"tasks.yaml: {label} の requirement_ids はリストである必要があります")
            elif len(requirement_ids) == 0:
                reasons.append(f"tasks.yaml: {label} の requirement_ids が空です")

    if reasons:
        return "FAIL", reasons[0], reasons, tasks

    return "PASS", f"tasks.yaml: 構造 OK ({len(tasks)} tasks)", [], tasks


def detect_cycle(task_list: Sequence[object]) -> Optional[List[str]]:
    graph: Dict[str, List[str]] = {}
    duplicate_ids: Set[str] = set()

    for task in task_list:
        if not isinstance(task, dict):
            continue
        task_id = task.get("id")
        if not isinstance(task_id, str) or not task_id.strip():
            continue

        normalized_id = task_id.strip()
        if normalized_id in graph:
            duplicate_ids.add(normalized_id)
        depends_on = task.get("depends_on")
        if isinstance(depends_on, list):
            deps = [dep.strip() for dep in depends_on if isinstance(dep, str) and dep.strip()]
        else:
            deps = []
        graph[normalized_id] = deps

    if duplicate_ids:
        duplicates = sorted(duplicate_ids)
        return ["duplicate-id"] + duplicates

    visited: Set[str] = set()
    in_stack: Set[str] = set()
    path: List[str] = []

    def dfs(node: str) -> Optional[List[str]]:
        visited.add(node)
        in_stack.add(node)
        path.append(node)

        for dep in graph.get(node, []):
            if dep not in graph:
                continue
            if dep not in visited:
                found = dfs(dep)
                if found:
                    return found
            elif dep in in_stack:
                cycle_start = path.index(dep)
                return path[cycle_start:] + [dep]

        path.pop()
        in_stack.remove(node)
        return None

    for node in graph:
        if node in visited:
            continue
        found_cycle = dfs(node)
        if found_cycle:
            return found_cycle

    return None


def validate_dag(tasks: Optional[List[object]], structure_status: str) -> Tuple[str, str, List[str]]:
    if yaml is None:
        return "WARN", "tasks.yaml: DAGチェックをスキップ (PyYAML未インストール)", []

    if tasks is None:
        reason = "tasks.yaml: DAGチェックを実行できません (tasks未取得)"
        if structure_status == "FAIL":
            return "FAIL", reason, [reason]
        return "WARN", reason, []

    cycle = detect_cycle(tasks)
    if not cycle:
        return "PASS", "tasks.yaml: DAG OK (no cycles)", []

    if cycle and cycle[0] == "duplicate-id":
        dupes = ", ".join(cycle[1:])
        reason = f"tasks.yaml: 重複した task id があります: {dupes}"
        return "FAIL", reason, [reason]

    cycle_repr = " -> ".join(cycle)
    reason = f"tasks.yaml: 依存関係に循環があります: {cycle_repr}"
    return "FAIL", reason, [reason]


def validate_unknown_deps(tasks: Optional[List[object]]) -> List[str]:
    if not isinstance(tasks, list):
        return []

    all_task_ids: Set[str] = set()
    for task in tasks:
        if not isinstance(task, dict):
            continue
        task_id = task.get("id")
        if isinstance(task_id, str) and task_id.strip():
            all_task_ids.add(task_id.strip())

    warnings: List[str] = []
    for index, task in enumerate(tasks):
        if not isinstance(task, dict):
            continue
        label = _task_label(task, index)
        depends_on = task.get("depends_on")
        if not isinstance(depends_on, list):
            continue
        for dep in depends_on:
            if isinstance(dep, str) and dep.strip() and dep.strip() not in all_task_ids:
                warnings.append(f"tasks.yaml: {label} の depends_on に未知のID '{dep.strip()}' があります")

    return warnings


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate PRD/SPEC/tasks for yb plan-review")
    parser.add_argument("--plan-dir", required=True, help="Path to plan directory")
    args = parser.parse_args()

    plan_dir = Path(args.plan_dir).expanduser().resolve()

    prd_file = plan_dir / "PRD.md"
    spec_file = plan_dir / "SPEC.md"
    tasks_file = plan_dir / "tasks.yaml"

    lines: List[Tuple[str, str]] = []
    fail_reasons: List[str] = []

    prd_ok, prd_msg = validate_prd(prd_file)
    lines.append(("PASS" if prd_ok else "FAIL", prd_msg))
    if not prd_ok:
        fail_reasons.append(prd_msg)

    spec_ok, spec_msg = validate_spec(spec_file)
    lines.append(("PASS" if spec_ok else "FAIL", spec_msg))
    if not spec_ok:
        fail_reasons.append(spec_msg)

    tasks_status, tasks_msg, tasks_failures, parsed_tasks = validate_tasks_structure(tasks_file)
    lines.append((tasks_status, tasks_msg))
    if tasks_status == "FAIL":
        fail_reasons.extend(tasks_failures)

    unknown_dep_warnings = validate_unknown_deps(parsed_tasks)
    for warning in unknown_dep_warnings:
        lines.append(("WARN", warning))

    dag_status, dag_msg, dag_failures = validate_dag(parsed_tasks, tasks_status)
    lines.append((dag_status, dag_msg))
    if dag_status == "FAIL":
        fail_reasons.extend(dag_failures)

    print("=== Plan Static Validation ===")
    for status, message in lines:
        print(f"[{status}] {message}")

    has_fail = len(fail_reasons) > 0
    print(f"--- Result: {'FAIL' if has_fail else 'PASS'} ---")

    if has_fail:
        # Keep order while de-duplicating repeated messages.
        deduped: List[str] = []
        seen: Set[str] = set()
        for reason in fail_reasons:
            if reason not in seen:
                seen.add(reason)
                deduped.append(reason)

        print("Fail reasons:")
        for reason in deduped:
            print(f"- {reason}")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
