#!/usr/bin/env python3
"""Import a Joplin desktop profile into omajot.

Drives a real `omajot daemon` over the client protocol (docs/PROTOCOL.md §1),
so notes are stored and synced exactly as if they had been typed:

- notebooks become folders (nested as in Joplin),
- notes keep their created/updated times,
- the title becomes the first line (`# Title`) unless the body already starts with it,
- Joplin tags become inline #hashtags on the last line,
- resources (`:/<id>` links) become attachments (`attachments/<sha256>.<ext>`).

Re-running is safe: `<data>/import-joplin.json` maps Joplin ids to omajot ids,
and anything already imported is skipped. Joplin's database is opened read-only.

    tools/import_joplin.py [--profile ~/.config/joplin-desktop] [--data DIR]
                           [--hub URL | --no-hub] [--dry-run]
"""
import argparse
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESOURCE_LINK = re.compile(r"\]\(:/([0-9a-f]{32})\)")
TAG_CHARS = re.compile(r"[^\w\-/]", re.UNICODE)


def default_binary():
    """A local build wins; else the release binary that tools/install-release.sh installs."""
    built = os.path.join(ROOT, "zig-out", "bin", "omajot")
    return built if os.access(built, os.X_OK) else os.path.join(ROOT, "bin", "omajot")


def tag_word(title):
    """A Joplin tag title as an omajot #hashtag word, or None if nothing is left."""
    word = TAG_CHARS.sub("", title.strip().replace(" ", "-")).strip("-/").lower()
    return word if word and not word.isdigit() else None


def first_line(text):
    for line in text.splitlines():
        if line.strip():
            return line.strip().lstrip("#").strip()
    return ""


class Daemon:
    def __init__(self, binary, data, hub, no_hub=False):
        """`hub=None` lets the daemon choose (config file, then its default)."""
        cmd = [binary, "daemon", "--data", data]
        if no_hub:
            cmd.append("--no-hub")
        elif hub:
            cmd += ["--hub", hub]
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.next_id = 0

    def call(self, cmd, **fields):
        self.next_id += 1
        request = {"id": self.next_id, "cmd": cmd, **fields}
        self.proc.stdin.write(json.dumps(request) + "\n")
        self.proc.stdin.flush()
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError(f"daemon exited during {cmd}")
            message = json.loads(line)
            if message.get("re") == self.next_id:
                if not message.get("ok"):
                    raise RuntimeError(f"{cmd} failed: {message.get('error')}")
                return message

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.terminate()


def load_joplin(profile):
    db = sqlite3.connect(f"file:{os.path.join(profile, 'database.sqlite')}?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    folders = db.execute("select id, parent_id, title from folders where deleted_time = 0").fetchall()
    notes = db.execute(
        "select id, parent_id, title, body, markup_language, created_time, updated_time,"
        " user_created_time, user_updated_time, is_conflict, encryption_applied"
        " from notes where deleted_time = 0 order by created_time").fetchall()
    resources = {r["id"]: r for r in db.execute("select id, title, file_extension, mime from resources")}
    tags = {}
    for row in db.execute("select nt.note_id, t.title from note_tags nt join tags t on t.id = nt.tag_id"):
        tags.setdefault(row["note_id"], []).append(row["title"])
    return folders, notes, resources, tags


def ordered_folders(folders):
    """Parents before children; folders whose parent is missing become roots."""
    ids = {f["id"] for f in folders}
    done, out = set(), []
    pending = list(folders)
    while pending:
        progressed = False
        for f in list(pending):
            parent = f["parent_id"] if f["parent_id"] in ids else ""
            if not parent or parent in done:
                out.append((f, parent))
                done.add(f["id"])
                pending.remove(f)
                progressed = True
        if not progressed:  # a cycle: break it by making the rest roots
            out += [(f, "") for f in pending]
            break
    return out


def note_text(note, tags, attach):
    body = note["body"] or ""
    if note["markup_language"] == 2:
        print(f"  note {note['title']!r} is HTML in Joplin; importing its source as-is", file=sys.stderr)
    body = RESOURCE_LINK.sub(lambda m: f"]({attach(m.group(1))})", body)
    title = (note["title"] or "").strip()
    if title and first_line(body) != title:
        body = f"# {title}\n\n{body}" if body.strip() else f"# {title}\n"
    words = [w for w in (tag_word(t) for t in tags) if w]
    missing = [w for w in dict.fromkeys(words) if not re.search(rf"(^|\s)#{re.escape(w)}\b", body, re.I)]
    if missing:
        body = body.rstrip("\n") + "\n\n" + " ".join("#" + w for w in missing) + "\n"
    return body


def wait_synced(daemon, hub, attachments, timeout=120):
    deadline = time.time() + timeout
    while time.time() < deadline:
        status = daemon.call("status")
        if status.get("sync") == "online" and status.get("pending", 1) == 0:
            break
        time.sleep(0.5)
    else:
        raise RuntimeError(f"not synced after {timeout}s: {status}")
    for name in attachments:
        url = f"{hub.rstrip('/')}/api/blobs/{name.split('/', 1)[1]}"
        while True:
            try:
                with urllib.request.urlopen(urllib.request.Request(url), timeout=10):
                    break
            except Exception:
                if time.time() > deadline:
                    raise RuntimeError(f"attachment {name} not on the hub after {timeout}s")
                time.sleep(0.5)
    return status


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--profile", default=os.path.expanduser("~/.config/joplin-desktop"))
    ap.add_argument("--data", default=os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "omajot"))
    ap.add_argument("--hub", default=None, help="hub URL (default: the daemon's config/default)")
    ap.add_argument("--no-hub", action="store_true")
    ap.add_argument("--binary", default=default_binary(), help="default: zig-out/bin/omajot (a local build), else bin/omajot (the release)")
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    folders, notes, resources, tags = load_joplin(args.profile)
    map_path = os.path.join(args.data, "import-joplin.json")
    mapping = json.load(open(map_path)) if os.path.exists(map_path) else {"folders": {}, "notes": {}, "resources": {}}
    print(f"Joplin: {len(notes)} notes, {len(folders)} notebooks, {len(resources)} resources; "
          f"already imported: {len(mapping['notes'])} notes, {len(mapping['folders'])} folders")

    skipped = [n for n in notes if n["encryption_applied"] or n["is_conflict"]]
    for n in skipped:
        print(f"  skipping {'encrypted' if n['encryption_applied'] else 'conflict'} note {n['title']!r}", file=sys.stderr)
    notes = [n for n in notes if n not in skipped]

    if args.dry_run:
        for f, parent in ordered_folders(folders):
            print(f"  folder {f['title']!r} (parent {parent[:6] or '-'})")
        for n in notes:
            text = note_text(n, tags.get(n["id"], []), lambda rid: f"attachments/<{rid[:6]}>")
            print(f"  note {first_line(text)!r} {len(text)} chars, tags {tags.get(n['id'], [])}")
        return

    hub = None if args.no_hub else args.hub
    daemon = Daemon(args.binary, args.data, hub, no_hub=args.no_hub)
    uploaded = []

    def save():
        tmp = map_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(mapping, f, indent=1)
        os.replace(tmp, map_path)

    try:
        hello = daemon.call("hello", client="import-joplin")
        hub_url = None if args.no_hub else (hub or hello.get("hub") or None)
        print(f"omajot replica {hello['replica']}, data {hello.get('data')}, hub {hub_url or '(none)'}")

        for f, parent in ordered_folders(folders):
            if f["id"] in mapping["folders"]:
                continue
            reply = daemon.call("folder.create", name=f["title"], parent=mapping["folders"].get(parent))
            mapping["folders"][f["id"]] = reply["folder"]
            save()
            print(f"  + folder {f['title']}")

        def attach(rid):
            if rid in mapping["resources"]:
                return mapping["resources"][rid]
            res = resources.get(rid)
            if res is None:
                print(f"  link to :/{rid} is not a resource (a note link?); left as-is", file=sys.stderr)
                return f":/{rid}"
            path = os.path.join(args.profile, "resources", f"{rid}.{res['file_extension']}")
            name = daemon.call("attach", path=path)["name"]
            mapping["resources"][rid] = name
            uploaded.append(name)
            save()
            return name

        for n in notes:
            if n["id"] in mapping["notes"]:
                continue
            text = note_text(n, tags.get(n["id"], []), attach)
            created = n["user_created_time"] or n["created_time"]
            updated = max(n["user_updated_time"] or n["updated_time"], created)
            reply = daemon.call("create", folder=mapping["folders"].get(n["parent_id"]), text=text,
                                created=created, updated=updated)
            mapping["notes"][n["id"]] = reply["note"]
            save()
            print(f"  + note {first_line(text)}")

        if hub_url:
            status = wait_synced(daemon, hub_url, list(mapping["resources"].values()))
            print(f"synced: hub head {status.get('head')}, nothing pending")
        listing = daemon.call("list")
        live = [x for x in listing["notes"] if not x["trashed"]]
        print(f"omajot now has {len(live)} notes in {len(listing['folders'])} folders")
    finally:
        daemon.close()


if __name__ == "__main__":
    main()
