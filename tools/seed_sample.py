#!/usr/bin/env python3
"""Seed the sample notes (examples/sample-notes) into an omajot replica.

Drives a real `omajot daemon` over the client protocol (docs/PROTOCOL.md §1),
like tools/import_joplin.py: folders, notes with their created/updated times,
images as attachments, pinned and trashed notes. Times are relative to now, so
screenshots always look recent.

    tools/seed_sample.py --data DIR [--hub URL | --no-hub]

Use a fresh DIR: the tool does not check for notes that are already there.
Without --hub or --no-hub the daemon uses its config file.
"""
import argparse
import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from import_joplin import Daemon, ROOT, wait_synced  # noqa: E402

SAMPLES = os.path.join(ROOT, "examples", "sample-notes")
IMAGE_LINK = re.compile(r"\]\((images/[^)\s]+)\)")
DAY_MS = 24 * 60 * 60 * 1000


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data", required=True, help="replica directory (use a fresh one)")
    ap.add_argument("--hub", default=None, help="hub URL (default: the daemon's config)")
    ap.add_argument("--no-hub", action="store_true", help="keep the notes local")
    # A local build wins, like in the plugin; else the released binary.
    built = os.path.join(ROOT, "zig-out", "bin", "omajot")
    ap.add_argument("--binary", default=built if os.path.exists(built) else os.path.join(ROOT, "bin", "omajot"))
    args = ap.parse_args()

    manifest = json.load(open(os.path.join(SAMPLES, "manifest.json")))
    now = int(time.time() * 1000)
    daemon = Daemon(args.binary, args.data, args.hub, no_hub=args.no_hub)
    try:
        hello = daemon.call("hello", client="seed-sample")
        hub = None if args.no_hub else (args.hub or hello.get("hub") or None)

        folder_ids = {}
        for f in manifest["folders"]:  # parents come first in the manifest
            reply = daemon.call("folder.create", name=f["name"], parent=folder_ids.get(f["parent"]))
            folder_ids[f["id"]] = reply["folder"]

        attachments = {}

        def attach(match):
            rel = match.group(1)
            if rel not in attachments:
                attachments[rel] = daemon.call("attach", path=os.path.join(SAMPLES, rel))["name"]
            return f"]({attachments[rel]})"

        # Oldest first, so the list order matches the times.
        for n in sorted(manifest["notes"], key=lambda n: -n["created_days_ago"]):
            text = open(os.path.join(SAMPLES, n["file"])).read()
            text = IMAGE_LINK.sub(attach, text)
            created = now - n["created_days_ago"] * DAY_MS - 3 * 60 * 60 * 1000
            if "updated_minutes_ago" in n:
                updated = now - n["updated_minutes_ago"] * 60 * 1000
            else:
                updated = now - n["updated_days_ago"] * DAY_MS - 2 * 60 * 60 * 1000
            updated = max(created, updated)
            note = daemon.call("create", folder=folder_ids.get(n["folder"]), text=text,
                               created=created, updated=updated)["note"]
            if n.get("pinned"):
                daemon.call("set", note=note, pinned=True)
            if n.get("trashed"):
                daemon.call("set", note=note, trashed=True)
            print(f"  + {n['file']}")

        if hub:
            status = wait_synced(daemon, hub, list(attachments.values()))
            print(f"synced to {hub}: head {status.get('head')}")
        listing = daemon.call("list")
        live = [x for x in listing["notes"] if not x["trashed"]]
        print(f"{len(live)} notes ({len(listing['notes']) - len(live)} in Trash), "
              f"{len(listing['folders'])} folders, {len(attachments)} images")
    finally:
        daemon.close()


if __name__ == "__main__":
    main()
