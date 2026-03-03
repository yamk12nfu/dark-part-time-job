"""Unit tests for scripts/lib/agent_config.py.

Run:
    python3 scripts/lib/test_agent_config.py
"""

import os
import sys
import tempfile
import textwrap
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from agent_config import (
    CLI_PRESETS,
    LEGACY_DEFAULTS,
    build_initial_message,
    build_launch_command,
    get_cli_binary,
    get_worker_count,
    load_agent_config,
)


class TestAgentConfig(unittest.TestCase):
    def _write_temp_config(self, content: str) -> str:
        tmp = tempfile.NamedTemporaryFile(
            mode="w",
            suffix=".yaml",
            prefix="agent_cfg_",
            delete=False,
            encoding="utf-8",
        )
        try:
            tmp.write(textwrap.dedent(content).lstrip("\n"))
            tmp.flush()
        finally:
            tmp.close()

        self.addCleanup(lambda p=tmp.name: os.path.exists(p) and os.remove(p))
        return tmp.name

    def test_preset_resolution(self):
        self.assertIn("claude", CLI_PRESETS)
        self.assertIn("gemini", CLI_PRESETS)
        self.assertIn("codex", CLI_PRESETS)

        path_a = self._write_temp_config(
            """
            agents:
              oyabun:
                cli: claude
              worker:
                cli: codex
            """
        )
        claude_cfg = load_agent_config(path_a, "oyabun")
        codex_cfg = load_agent_config(path_a, "worker")

        self.assertEqual(claude_cfg.get("command"), "claude --dangerously-skip-permissions")
        self.assertEqual(claude_cfg.get("mode"), "interactive")
        self.assertIn("codex", codex_cfg.get("command", ""))
        self.assertEqual(codex_cfg.get("mode"), "batch_stdin")

        path_b = self._write_temp_config(
            """
            agents:
              oyabun:
                cli: gemini
            """
        )
        gemini_cfg = load_agent_config(path_b, "oyabun")
        self.assertIn("gemini", gemini_cfg.get("command", ""))
        self.assertEqual(gemini_cfg.get("mode"), "interactive")

    def test_legacy_fallback(self):
        path = self._write_temp_config(
            """
            workers:
              codex_count: 5
            codex:
              sandbox: workspace-write
              model: default
            """
        )
        oyabun_cfg = load_agent_config(path, "oyabun")
        worker_cfg = load_agent_config(path, "worker")

        self.assertIn("claude", oyabun_cfg.get("command", ""))
        self.assertIn("codex", worker_cfg.get("command", ""))

    def test_partial_spec_fallback(self):
        self.assertIn("oyabun", LEGACY_DEFAULTS)
        self.assertIn("worker", LEGACY_DEFAULTS)

        path = self._write_temp_config(
            """
            agents:
              oyabun:
                cli: gemini
            """
        )

        oyabun_cfg = load_agent_config(path, "oyabun")
        waka_cfg = load_agent_config(path, "waka")
        worker_cfg = load_agent_config(path, "worker")
        plan_cfg = load_agent_config(path, "plan")
        plan_review_cfg = load_agent_config(path, "plan_review")

        self.assertIn("gemini", oyabun_cfg.get("command", ""))
        self.assertIn("claude", waka_cfg.get("command", ""))
        self.assertIn("codex", worker_cfg.get("command", ""))
        self.assertIn("claude", plan_cfg.get("command", ""))
        self.assertIn("codex", plan_review_cfg.get("command", ""))

    def test_worker_count(self):
        path_with_count = self._write_temp_config(
            """
            workers:
              count: 7
              codex_count: 5
            """
        )
        self.assertEqual(get_worker_count(path_with_count), 7)

        path_with_legacy = self._write_temp_config(
            """
            workers:
              codex_count: 5
            """
        )
        self.assertEqual(get_worker_count(path_with_legacy), 5)

        path_default = self._write_temp_config(
            """
            codex:
              model: high
            """
        )
        self.assertEqual(get_worker_count(path_default), 3)

    def test_invalid_cli_fallback(self):
        path = self._write_temp_config(
            """
            agents:
              oyabun:
                cli: unknown_cli
              worker:
                cli: unknown_cli
            """
        )
        oyabun_cfg = load_agent_config(path, "oyabun")
        worker_cfg = load_agent_config(path, "worker")

        self.assertEqual(oyabun_cfg.get("cli"), "claude")
        self.assertIn("claude", oyabun_cfg.get("command", ""))
        self.assertEqual(worker_cfg.get("cli"), "codex")
        self.assertIn("codex", worker_cfg.get("command", ""))
        self.assertEqual(worker_cfg.get("mode"), "batch_stdin")

    def test_invalid_worker_count_values(self):
        path_invalid_count = self._write_temp_config(
            """
            workers:
              count: "abc"
              codex_count: 5
            """
        )
        self.assertEqual(get_worker_count(path_invalid_count), 3)

        path_invalid_codex_count = self._write_temp_config(
            """
            workers:
              codex_count: true
            """
        )
        self.assertEqual(get_worker_count(path_invalid_codex_count), 3)

    def test_invalid_agents_section_type_fallback(self):
        path = self._write_temp_config(
            """
            agents: "invalid"
            """
        )
        oyabun_cfg = load_agent_config(path, "oyabun")
        worker_cfg = load_agent_config(path, "worker")

        self.assertIn("claude", oyabun_cfg.get("command", ""))
        self.assertIn("codex", worker_cfg.get("command", ""))

    def test_invalid_workers_section_type(self):
        path = self._write_temp_config(
            """
            workers: "invalid"
            """
        )
        self.assertEqual(get_worker_count(path), 3)

    def test_template_expansion(self):
        path = self._write_temp_config(
            """
            agents:
              worker:
                cli: codex
            """
        )
        cfg = load_agent_config(path, "worker")

        cmd = build_launch_command(cfg, sandbox="workspace-write")
        cmd_str = " ".join(cmd)
        self.assertIn("workspace-write", cmd_str)
        self.assertNotIn("{sandbox}", cmd_str)

        msg = build_initial_message(cfg, prompt_path="/tmp/test.md", role="oyabun")
        self.assertIn("/tmp/test.md", msg)
        self.assertIn("oyabun", msg)

    def test_custom_cli(self):
        path = self._write_temp_config(
            """
            agents:
              oyabun:
                cli: custom
                command: "my-cli --auto"
                mode: interactive
                initial_message: "Hello {role}"
            """
        )
        cfg = load_agent_config(path, "oyabun")

        self.assertEqual(cfg.get("command"), "my-cli --auto")
        self.assertEqual(cfg.get("mode"), "interactive")
        self.assertEqual(build_initial_message(cfg, role="oyabun"), "Hello oyabun")

    def test_get_cli_binary(self):
        self.assertEqual(
            get_cli_binary({"command": "claude --dangerously-skip-permissions"}),
            "claude",
        )
        self.assertEqual(
            get_cli_binary({"command": "codex exec --sandbox workspace-write -"}),
            "codex",
        )
        self.assertEqual(get_cli_binary({"command": "my-cli --auto"}), "my-cli")

    def test_copilot_preset_interactive(self):
        path = self._write_temp_config(
            """
            agents:
              oyabun:
                cli: copilot
            """
        )
        cfg = load_agent_config(path, "oyabun")

        self.assertEqual(cfg.get("command"), "copilot --autopilot")
        self.assertEqual(cfg.get("mode"), "interactive")

    def test_copilot_preset_batch_worker(self):
        path = self._write_temp_config(
            """
            agents:
              worker:
                cli: copilot
            """
        )
        cfg = load_agent_config(path, "worker")

        self.assertEqual(cfg.get("command"), "copilot")
        self.assertEqual(build_launch_command(cfg), ["copilot"])

    def test_get_cli_binary_copilot(self):
        path = self._write_temp_config(
            """
            agents:
              oyabun:
                cli: copilot
            """
        )
        cfg = load_agent_config(path, "oyabun")

        self.assertEqual(get_cli_binary(cfg), "copilot")

    def test_codex_fallback(self):
        path = self._write_temp_config(
            """
            agents:
              worker:
                cli: codex
            codex:
              sandbox: workspace-write
              model: high
            """
        )
        worker_cfg = load_agent_config(path, "worker")
        self.assertEqual(worker_cfg.get("sandbox"), "workspace-write")

    def test_oyabun_codex_returns_interactive_command(self):
        path = self._write_temp_config(
            """
            agents:
              oyabun:
                cli: codex
            """
        )
        oyabun_cfg = load_agent_config(path, "oyabun")

        self.assertEqual(oyabun_cfg.get("mode"), "interactive")
        self.assertEqual(oyabun_cfg.get("command"), "codex --approval-mode full-auto")
        self.assertEqual(build_launch_command(oyabun_cfg), ["codex", "--approval-mode", "full-auto"])

    def test_worker_codex_returns_batch_command(self):
        path = self._write_temp_config(
            """
            agents:
              worker:
                cli: codex
            """
        )
        worker_cfg = load_agent_config(path, "worker")

        self.assertEqual(worker_cfg.get("mode"), "batch_stdin")
        self.assertEqual(worker_cfg.get("command"), "codex exec --sandbox {sandbox} -")
        self.assertEqual(
            build_launch_command(worker_cfg),
            ["codex", "exec", "--sandbox", "workspace-write", "-"],
        )

    def test_oyabun_codex_sandbox_resolved(self):
        path = self._write_temp_config(
            """
            agents:
              oyabun:
                cli: codex
            """
        )
        oyabun_cfg = load_agent_config(path, "oyabun")

        cmd = build_launch_command(oyabun_cfg)
        self.assertEqual(cmd, ["codex", "--approval-mode", "full-auto"])

    def test_waka_codex_sandbox_resolved(self):
        path = self._write_temp_config(
            """
            agents:
              waka:
                cli: codex
            """
        )
        waka_cfg = load_agent_config(path, "waka")

        cmd = build_launch_command(waka_cfg)
        self.assertEqual(cmd, ["codex", "--approval-mode", "full-auto"])

    def test_lightweight_parser_edge_cases(self):
        path = self._write_temp_config(
            """
            agents:
              oyabun:
                cli: "claude"
              waka:
                cli: 'gemini'
              worker:
                cli: claude  # main agent
                web_search: false
                enabled: true
              plan:
                cli: ""
              plan_review:
                cli: custom
                command: ""
            """
        )

        oyabun_cfg = load_agent_config(path, "oyabun")
        waka_cfg = load_agent_config(path, "waka")
        worker_cfg = load_agent_config(path, "worker")
        plan_cfg = load_agent_config(path, "plan")
        plan_review_cfg = load_agent_config(path, "plan_review")

        self.assertIn("claude", oyabun_cfg.get("command", ""))
        self.assertIn("gemini", waka_cfg.get("command", ""))
        self.assertIn("claude", worker_cfg.get("command", ""))
        self.assertIs(worker_cfg.get("web_search"), False)
        self.assertIn("claude", plan_cfg.get("command", ""))
        self.assertIn("codex", plan_review_cfg.get("command", ""))

    def test_invalid_indentation_fallback(self):
        path = self._write_temp_config(
            """
            agents:
              oyabun:
                cli: gemini
               bad_indent: value
              worker:
                cli: codex
            """
        )
        oyabun_cfg = load_agent_config(path, "oyabun")
        worker_cfg = load_agent_config(path, "worker")

        self.assertIn("gemini", oyabun_cfg.get("command", ""))
        self.assertIn("codex", worker_cfg.get("command", ""))

    def test_stdin_pipe_command(self):
        codex_path = self._write_temp_config(
            """
            agents:
              worker:
                cli: codex
            """
        )
        codex_cfg = load_agent_config(codex_path, "worker")
        codex_cmd = build_launch_command(codex_cfg, sandbox="workspace-write")
        self.assertIsInstance(codex_cmd, list)
        self.assertIn("codex", codex_cmd)
        self.assertIn("exec", codex_cmd)
        self.assertTrue(all(isinstance(part, str) for part in codex_cmd))

        claude_path = self._write_temp_config(
            """
            agents:
              worker:
                cli: claude
            """
        )
        claude_cfg = load_agent_config(claude_path, "worker")
        claude_cmd = build_launch_command(claude_cfg)
        self.assertIsInstance(claude_cmd, list)
        self.assertTrue(all(isinstance(part, str) for part in claude_cmd))


if __name__ == "__main__":
    unittest.main()
