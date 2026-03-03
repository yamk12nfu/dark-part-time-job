#!/usr/bin/env python3
"""CLI wrapper for scripts/lib/agent_config.py."""

from __future__ import annotations

import argparse
import shlex

try:
    from scripts.lib.agent_config import (
        load_agent_config,
        get_worker_count,
        build_launch_command,
        build_initial_message,
        get_cli_binary,
    )
except ImportError:
    from agent_config import (
        load_agent_config,
        get_worker_count,
        build_launch_command,
        build_initial_message,
        get_cli_binary,
    )


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Resolve agent config fields.")
    parser.add_argument("--config", required=True, help="Path to config.yaml")
    parser.add_argument("--role", help="Agent role (oyabun/waka/worker/plan/plan_review)")
    parser.add_argument(
        "--field",
        required=True,
        choices=("command", "mode", "initial_message", "worker_count", "cli_binary"),
        help="Field to output",
    )
    parser.add_argument("--prompt-path", help="Prompt file path")
    parser.add_argument("--role-label", help="Role label for initial_message {role}")
    parser.add_argument("--sandbox", help="Sandbox value for command template")
    parser.add_argument("--output-path", help="Output path for command template")
    return parser


def _require_role(parser: argparse.ArgumentParser, role: str | None) -> str:
    if role:
        return role
    parser.error("--role is required for this field")
    return ""


def main() -> int:
    parser = _build_parser()
    args = parser.parse_args()

    if args.field == "worker_count":
        print(get_worker_count(args.config))
        return 0

    role = _require_role(parser, args.role)
    agent_cfg = load_agent_config(args.config, role)

    if args.field == "command":
        cmd_list = build_launch_command(
            agent_cfg,
            prompt_path=args.prompt_path or "",
            role=args.role_label or role,
            sandbox=args.sandbox or agent_cfg.get("sandbox"),
            output_path=args.output_path or "",
        )
        print(shlex.join(cmd_list))
        return 0

    if args.field == "mode":
        print(agent_cfg.get("mode", ""))
        return 0

    if args.field == "initial_message":
        if not args.prompt_path:
            parser.error("--prompt-path is required for --field initial_message")
        role_label = args.role_label or role
        print(
            build_initial_message(
                agent_cfg,
                prompt_path=args.prompt_path,
                role=role_label,
            )
        )
        return 0

    if args.field == "cli_binary":
        print(get_cli_binary(agent_cfg))
        return 0

    parser.error(f"unsupported field: {args.field}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
