#!/usr/bin/env python3
"""Unit tests for tools/agent-sessions CLI helpers."""

import sqlite3
import sys
import tempfile
import types
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
CLI_PATH = TOOLS_DIR / "agent-sessions"
cli = types.ModuleType("agent_sessions_cli")
cli.__file__ = str(CLI_PATH)
sys.modules["agent_sessions_cli"] = cli
exec(CLI_PATH.read_text(encoding="utf-8"), cli.__dict__)


class AgentSessionsCLITests(unittest.TestCase):
    def test_resolve_agent_aliases(self) -> None:
        self.assertEqual(cli.resolve_agent("opencode"), "opencode")
        self.assertEqual(cli.resolve_agent("Claude-Code"), "claude")

    def test_resolve_agent_unknown_exits(self) -> None:
        import io
        from contextlib import redirect_stderr

        buf = io.StringIO()
        with redirect_stderr(buf), self.assertRaises(SystemExit) as ctx:
            cli.resolve_agent("not-an-agent")
        self.assertEqual(ctx.exception.code, 2)
        self.assertIn("Unknown agent", buf.getvalue())

    def test_fetch_sessions_filters_by_cwd_prefix(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "index.db"
            conn = sqlite3.connect(db_path)
            conn.row_factory = sqlite3.Row
            conn.execute(
                """
                CREATE TABLE session_meta (
                  session_id TEXT PRIMARY KEY,
                  source TEXT NOT NULL,
                  path TEXT NOT NULL,
                  mtime INTEGER,
                  size INTEGER,
                  start_ts INTEGER,
                  end_ts INTEGER,
                  model TEXT,
                  cwd TEXT,
                  repo TEXT,
                  title TEXT,
                  codex_internal_session_id TEXT,
                  is_housekeeping INTEGER NOT NULL DEFAULT 0,
                  messages INTEGER DEFAULT 0,
                  commands INTEGER DEFAULT 0,
                  custom_title TEXT
                );
                """
            )
            conn.execute(
                "INSERT INTO session_meta VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    "aaa",
                    "claude",
                    "/tmp/a.jsonl",
                    0,
                    0,
                    0,
                    100,
                    "m",
                    "/proj/sub",
                    "proj",
                    "In repo",
                    None,
                    0,
                    3,
                    0,
                    None,
                ),
            )
            conn.execute(
                "INSERT INTO session_meta VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                (
                    "bbb",
                    "codex",
                    "/tmp/b.jsonl",
                    0,
                    0,
                    0,
                    200,
                    "m",
                    "/elsewhere",
                    "other",
                    "Outside",
                    None,
                    0,
                    1,
                    0,
                    None,
                ),
            )
            conn.commit()

            root = Path("/proj")
            rows = cli.fetch_sessions_index(conn, root, "proj", None, None, False)
            conn.close()

            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0].session_id, "aaa")
            self.assertEqual(rows[0].source, "claude")

    def test_merge_prefers_index_over_disk(self) -> None:
        index = [
            cli.SessionRow(
                source="opencode",
                session_id="ses_1",
                title="from index",
                modified="",
                sort_ts=100,
                cwd="/proj",
                repo="proj",
                model=None,
            ).finish()
        ]
        disk = [
            cli.SessionRow(
                source="opencode",
                session_id="ses_1",
                title="from disk",
                modified="",
                sort_ts=200,
                cwd="/proj",
                repo="proj",
                model=None,
            ).finish()
        ]
        merged = cli.merge_session_rows(index, disk)
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0].title, "from index")

    def test_merge_dedups_codex_index_vs_disk_internal_id(self) -> None:
        # Index keys on file content hash; disk keys on internal uuid.
        index = [
            cli.SessionRow(
                source="codex",
                session_id="contenthash",
                title="from index",
                modified="",
                sort_ts=100,
                cwd="/proj",
                repo="proj",
                model=None,
                codex_internal_session_id="uuid-123",
            ).finish()
        ]
        disk = [
            cli.SessionRow(
                source="codex",
                session_id="uuid-123",
                title="from disk",
                modified="",
                sort_ts=100,
                cwd="/proj",
                repo="proj",
                model=None,
                codex_internal_session_id="uuid-123",
            ).finish()
        ]
        merged = cli.merge_session_rows(index, disk)
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0].title, "from index")

    def test_resume_hint_codex_prefers_internal_id(self) -> None:
        hint = cli.build_resume_hint("codex", "file-uuid", "/proj", "internal-abc")
        self.assertIn("internal-abc", hint)
        self.assertNotIn("file-uuid", hint)

    def test_path_matches_project_prefix_and_repo_substring(self) -> None:
        root = Path("/Users/me/Github/tools")
        match = cli._DISK.path_matches_project
        self.assertTrue(match("/Users/me/Github/tools/projects/x", root, "tools"))
        self.assertTrue(match("/other/path/tools/foo", root, "tools"))
        self.assertFalse(match("/Users/me/other", root, "tools"))

    def test_cli_disk_listable_all_sources(self) -> None:
        present = {s: True for s in cli.ALL_SOURCES}
        listable = cli.cli_disk_listable(present)
        self.assertEqual(set(listable.keys()), set(cli.ALL_SOURCES))
        self.assertTrue(all(listable.values()))

    def test_grok_sessions_root_honors_grok_home(self) -> None:
        import os

        with tempfile.TemporaryDirectory() as tmp:
            grok_home = Path(tmp) / "custom-grok"
            sessions = grok_home / "sessions"
            sessions.mkdir(parents=True)
            old = os.environ.get("GROK_HOME")
            os.environ["GROK_HOME"] = str(grok_home)
            try:
                self.assertEqual(cli._DISK.grok_sessions_root(), sessions)
                present = cli.agent_data_present()
                self.assertTrue(present["grok"])
            finally:
                if old is None:
                    os.environ.pop("GROK_HOME", None)
                else:
                    os.environ["GROK_HOME"] = old

    def test_amp_sessions_root_default(self) -> None:
        expected = Path.home() / ".local" / "share" / "amp" / "threads"
        self.assertEqual(cli._DISK.amp_sessions_root(), expected)

    def test_antigravity_sessions_root_default(self) -> None:
        expected = Path.home() / ".gemini" / "antigravity-cli"
        self.assertEqual(cli._DISK.antigravity_sessions_root(), expected)

    def test_amp_and_antigravity_registered_in_disk_fetchers(self) -> None:
        self.assertIn("amp", cli._DISK.DISK_FETCHERS)
        self.assertIn("antigravity", cli._DISK.DISK_FETCHERS)

    def test_pi_project_directory_round_trip(self) -> None:
        encode = cli._DISK._pi_project_dir_name
        decode = cli._DISK._decode_pi_project_dir
        self.assertEqual(encode("/tmp/as-agent-fixture/project"), "--tmp-as-agent-fixture-project--")
        self.assertEqual(decode("--tmp-pifixture-project--"), "/tmp/pifixture/project")


if __name__ == "__main__":
    unittest.main()