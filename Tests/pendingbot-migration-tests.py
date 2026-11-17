#!/usr/bin/env python3
"""Synthetic cache conversion regressions; never opens user data."""

import importlib.util
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "migration", Path(__file__).resolve().parents[1] / "Scripts/migrate-pendingbot-cache.py")
migration = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(migration)


def fixture_cache(path):
    with sqlite3.connect(path) as database:
        database.executescript("""
            CREATE TABLE conversations (id TEXT PRIMARY KEY, title TEXT, bot_id TEXT,
              bot_name TEXT, conversation_type TEXT, last_activity_at INTEGER);
            CREATE TABLE bots (id TEXT PRIMARY KEY, display_name TEXT);
            CREATE TABLE messages (id TEXT PRIMARY KEY, conversation_id TEXT, role TEXT,
              content TEXT, created_at INTEGER, message_seq INTEGER, parent_message_id TEXT,
              bubble_group_id TEXT, status TEXT);
            INSERT INTO bots VALUES ('bot', '旧机器人');
            INSERT INTO conversations VALUES ('chat', '旧标题', 'bot', NULL, 'user_bot', 1750000001);
        """)
        rows = [
            ("prompt", "user", "问题", None, None, None),
            ("first-a", "bot", "原回答第一段", "prompt", "group-a", "done"),
            ("variant-a", "bot", "候选第一段", "prompt", "group-b", "done"),
            ("first-b", "bot", "原回答第二段", "prompt", "group-a", "done"),
            ("next-prompt", "user", "下个问题", None, None, None),
            ("variant-b", "bot", "候选第二段", "prompt", "group-b", "done"),
            ("removed", "bot", "已撤回正文", "prompt", "group-b", "deleted"),
            ("next-answer", "bot", "下一轮回答", "next-prompt", "group-b", "done"),
        ]
        database.executemany("INSERT INTO messages VALUES (?, 'chat', ?, ?, 1750000000, ?, ?, ?, ?)",
                             [(key, role, content, index, parent, group, status)
                              for index, (key, role, content, parent, group, status) in enumerate(rows)])
    return migration.read_cache(path, "sqlcipher")


class MigrationTests(unittest.TestCase):
    def test_split_variants_remain_separate_answers(self):
        with tempfile.TemporaryDirectory() as folder:
            cache = fixture_cache(Path(folder) / "cache.sqlite")
        manifest, count, skipped = migration.backup_manifest(cache, "https://example.invalid/v1", "fixture")
        messages = manifest["conversations"][0]["messages"]
        alternatives = [message for message in messages if message.get("isAlternative")]
        self.assertEqual([message["content"] for message in alternatives], ["候选第一段\n\n候选第二段"])
        self.assertEqual([message["content"] for message in messages if not message.get("isAlternative")],
                         ["问题", "原回答第一段", "原回答第二段", "下个问题", "下一轮回答"])
        self.assertEqual((count, skipped), (6, 1))
        self.assertEqual(alternatives[0]["replyTo"], messages[0]["id"])
        self.assertEqual(messages[-1]["replyTo"], messages[-2]["id"])
        self.assertEqual(messages[1]["date"], 1750000000 - migration.APPLE_EPOCH)

    def test_missing_group_or_parent_does_not_invent_variants(self):
        with tempfile.TemporaryDirectory() as folder:
            cache = fixture_cache(Path(folder) / "cache.sqlite")
        for row in cache["messages"]:
            row["group"] = None
        manifest, count, skipped = migration.backup_manifest(cache, "https://example.invalid/v1", "fixture")
        self.assertEqual((count, skipped), (7, 1))
        self.assertFalse(any(row.get("isAlternative") for row in manifest["conversations"][0]["messages"]))
        for row in cache["messages"]:
            row["group"] = row["id"]
            row["parent"] = "not-cached"
        manifest, count, skipped = migration.backup_manifest(cache, "https://example.invalid/v1", "fixture")
        self.assertEqual(count, 7)
        self.assertFalse(any(row.get("isAlternative") for row in manifest["conversations"][0]["messages"]))

    def test_group_identity_is_scoped_to_its_chat_and_prompt(self):
        with tempfile.TemporaryDirectory() as folder:
            cache = fixture_cache(Path(folder) / "cache.sqlite")
        cache["conversations"].append(dict(cache["conversations"][0], id="other-chat"))
        cache["messages"].extend([
            {"id": "other-prompt", "chat": "other-chat", "role": "user", "content": "另一会话",
             "time": 1750000000, "parent": None, "group": None, "status": None},
            {"id": "other-answer", "chat": "other-chat", "role": "bot", "content": "独立回答",
             "time": 1750000000, "parent": "other-prompt", "group": "group-b", "status": "done"},
        ])
        manifest, count, _ = migration.backup_manifest(cache, "https://example.invalid/v1", "fixture")
        self.assertEqual(count, 8)
        other = manifest["conversations"][1]["messages"]
        self.assertEqual([message["content"] for message in other], ["另一会话", "独立回答"])
        self.assertFalse(other[-1].get("isAlternative"))

    @unittest.skipUnless(os.environ.get("AAUV_TEST_SQLCIPHER"), "optional SQLCipher CLI not supplied")
    def test_encrypted_cache_keeps_the_same_answer_groups(self):
        cipher = os.environ["AAUV_TEST_SQLCIPHER"]
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)
            expected = fixture_cache(path / "plain.sqlite")
            with sqlite3.connect(path / "plain.sqlite") as database:
                dump = "\n".join(database.iterdump())
            subprocess.run([cipher, "-batch", "-bail", "-init", os.devnull, str(path / "encrypted.sqlite")],
                           input="PRAGMA key='synthetic-fixture-only';\n" + dump,
                           text=True, stdout=subprocess.DEVNULL, check=True)
            with patch.object(migration.getpass, "getpass", return_value="synthetic-fixture-only"):
                actual = migration.read_cache(path / "encrypted.sqlite", cipher)
            self.assertEqual(actual, expected)
            self.assertEqual(migration.backup_manifest(actual, "https://example.invalid/v1", "fixture"),
                             migration.backup_manifest(expected, "https://example.invalid/v1", "fixture"))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--fixture":
        with tempfile.TemporaryDirectory() as folder:
            cache = fixture_cache(Path(folder) / "cache.sqlite")
        manifest, _, _ = migration.backup_manifest(cache, "https://example.invalid/v1", "fixture")
        migration.write_backup(Path(sys.argv[2]), manifest)
    else:
        unittest.main()
