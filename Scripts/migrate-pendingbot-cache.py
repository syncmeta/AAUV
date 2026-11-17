#!/usr/bin/env python3
"""Convert an explicitly supplied PendingBot SQLite cache copy to AAUV."""

import argparse
import getpass
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from urllib.parse import urlsplit
from uuid import NAMESPACE_URL, UUID, uuid5
import warnings
from zipfile import ZIP_DEFLATED, ZipFile


MAX_MANIFEST = 64 * 1024 * 1024
APPLE_EPOCH = 978307200
READ_CACHE = """
SELECT json_object(
  'conversations', (SELECT json_group_array(json_object(
    'id', c.id, 'title', c.title, 'bot', c.bot_id, 'name', c.bot_name))
    FROM (SELECT * FROM conversations WHERE conversation_type='user_bot' AND bot_id<>''
          ORDER BY last_activity_at DESC, id) c),
  'bots', (SELECT json_group_array(json_object('id', id, 'name', display_name)) FROM bots),
  'messages', (SELECT json_group_array(json_object(
    'id', id, 'chat', conversation_id, 'role', role, 'content', content,
    'time', created_at, 'parent', parent_message_id, 'group', bubble_group_id, 'status', status))
    FROM (SELECT m.* FROM messages m JOIN conversations c ON c.id=m.conversation_id
          WHERE c.conversation_type='user_bot' AND c.bot_id<>''
          ORDER BY m.created_at, coalesce(m.message_seq, 9223372036854775807), m.id)),
  'skipped', (SELECT count(*) FROM conversations
              WHERE conversation_type IS NOT 'user_bot' OR bot_id IS NULL OR bot_id='')
);
"""


def read_cache(source, cipher):
    if not source.is_file():
        raise ValueError("Choose a regular database file.")
    with source.open("rb") as file:
        encrypted = file.read(16) != b"SQLite format 3\0"
    shell = shutil.which(cipher if encrypted else "sqlite3")
    if shell is None:
        raise ValueError("SQLCipher CLI is required for an encrypted cache." if encrypted else "SQLite CLI is required.")
    prefix = ".output /dev/null\n"
    if encrypted:
        # Never pass the key on the command line or read it from a keychain.
        with warnings.catch_warnings():
            warnings.simplefilter("error", getpass.GetPassWarning)
            passphrase = getpass.getpass("PendingBot database passphrase: ")
        if not passphrase or any(ch in passphrase for ch in "\0\r\n"):
            raise ValueError("Invalid database passphrase.")
        quoted = passphrase.replace("'", "''")
        prefix += f"PRAGMA key = '{quoted}';\n"
    result = subprocess.run(
        [shell, "-readonly", "-batch", "-bail", "-init", os.devnull, str(source)],
        input=prefix + "PRAGMA query_only=ON;\nPRAGMA trusted_schema=OFF;\nPRAGMA temp_store=MEMORY;\n"
        + f".limit length {MAX_MANIFEST}\n.output stdout\n" + READ_CACHE,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=120,
    )
    if result.returncode:
        raise ValueError("Could not read the cache. Check the passphrase and use a complete PendingBot v9+ snapshot.")
    try:
        # Some SQLite shells write the .limit result directly to stdout.
        return json.loads(result.stdout.rstrip("\n").rsplit("\n", 1)[-1])
    except json.JSONDecodeError:
        raise ValueError("Could not parse the PendingBot cache.") from None


def identity(kind, key):
    if not key:
        raise ValueError("The cache contains a missing record identifier.")
    try:
        value = UUID(key)
    except ValueError:
        value = uuid5(NAMESPACE_URL, f"urn:pendingbot-cache:{kind}:{key}")
    return str(value).upper()


def backup_manifest(cache, endpoint, model):
    names = {row["id"]: row["name"] for row in cache["bots"]}
    profiles = {}
    conversations = {}
    message_ids = {}
    skipped_messages = 0
    for row in cache["conversations"]:
        bot = row["bot"]
        if bot not in profiles:
            name = (names.get(bot) or row["name"] or "大绿豆").strip()[:80] or "大绿豆"
            profiles[bot] = {"id": identity("bot", bot), "configuration": {
                "name": name, "endpoint": endpoint, "model": model, "loginMethod": "byok", "apiProtocol": "responses",
            }}
        profile = profiles[bot]
        conversations[row["id"]] = {
            "id": identity("conversation", row["id"]), "title": row["title"] or profile["configuration"]["name"],
            "automaticTitle": False, "bot": dict(profile["configuration"], profileID=profile["id"]), "messages": [],
        }
    for row in cache["messages"]:
        if row["role"] not in ("user", "bot") or row["status"] in ("deleted", "replaced") or not row["content"]:
            skipped_messages += 1
            continue
        message = {"id": identity("message", row["id"]), "role": "assistant" if row["role"] == "bot" else "user",
                   "content": row["content"]}
        if row["time"] and row["time"] > 0:
            message["date"] = row["time"] - APPLE_EPOCH
        conversations[row["chat"]]["messages"].append(message)
        message_ids[row["id"]] = (row["chat"], row["parent"], row.get("group"), message)
    answers = {}
    for chat, parent, group, message in message_ids.values():
        prior = message_ids.get(parent)
        if message["role"] == "assistant" and prior and prior[0] == chat and prior[3]["role"] == "user":
            message["replyTo"] = prior[3]["id"]
            if group:
                answers.setdefault((chat, parent), {}).setdefault(group, []).append(message)
    merged_ids = set()
    for groups in answers.values():
        # The cache records answer identities, but no selected-answer state.
        # Keep the earliest answer's original bubbles. Each later answer must
        # become one selectable alternative, including all of its own bubbles.
        for bubbles in list(groups.values())[1:]:
            bubbles[0]["content"] = "\n\n".join(message["content"] for message in bubbles)
            bubbles[0]["isAlternative"] = True
            merged_ids.update(message["id"] for message in bubbles[1:])
    for conversation in conversations.values():
        conversation["messages"] = [message for message in conversation["messages"] if message["id"] not in merged_ids]
    if not conversations:
        raise ValueError("The supplied cache contains no one-to-one bot conversations.")
    manifest = {"version": 2, "conversations": list(conversations.values()), "bots": list(profiles.values())}
    return manifest, len(message_ids) - len(merged_ids), skipped_messages


def write_backup(destination, manifest):
    data = json.dumps(manifest, ensure_ascii=False, separators=(",", ":")).encode()
    if len(data) > MAX_MANIFEST:
        raise ValueError("The backup manifest exceeds AAUV's 64 MiB limit.")
    with tempfile.NamedTemporaryFile(dir=destination.parent) as stage:
        with ZipFile(stage, "w", compression=ZIP_DEFLATED) as archive:
            archive.writestr("manifest.json", data)
        stage.flush()
        os.link(stage.name, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="a copy of pendingbot.sqlite")
    parser.add_argument("destination", type=Path, help="a new .aauvbackup file")
    parser.add_argument("--base-url", required=True, help="the BYOK service to bind to the imported bots")
    parser.add_argument("--model", required=True, help="a model available at the chosen service")
    parser.add_argument("--sqlcipher", default="sqlcipher", help="path to the SQLCipher CLI for encrypted caches")
    args = parser.parse_args()
    try:
        endpoint = args.base_url.strip().rstrip("/")
        url = urlsplit(endpoint)
        host = url.hostname
        if (not host or host.rstrip(".") == "aauv.invalid" or url.username is not None or
                "?" in endpoint or "#" in endpoint or any(ch.isspace() for ch in endpoint) or
                (url.scheme != "https" and not (url.scheme == "http" and host in ("localhost", "127.0.0.1", "::1")))):
            raise ValueError("Use a valid HTTPS Base URL, or HTTP on localhost, without credentials.")
        model = args.model.strip()
        if not model or len(model.encode()) > 512 or args.destination.suffix.lower() != ".aauvbackup":
            raise ValueError("Provide a model name and a destination ending in .aauvbackup.")
        cache = read_cache(args.source.resolve(strict=True), args.sqlcipher)
        manifest, messages, skipped = backup_manifest(cache, endpoint, model)
        write_backup(args.destination, manifest)
    except (OSError, ValueError, getpass.GetPassWarning, subprocess.TimeoutExpired) as error:
        parser.exit(1, f"Migration failed: {error if not isinstance(error, subprocess.TimeoutExpired) else 'cache read timed out'}\n")
    print(f"Saved {len(manifest['conversations'])} chats, {messages} messages and {len(manifest['bots'])} bots.")
    print(f"Skipped {cache['skipped']} non-bot or unsupported chats and {skipped} empty, removed or system messages.")


if __name__ == "__main__":
    main()
