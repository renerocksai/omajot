#!/usr/bin/env python3
"""A stand-in for `omajot daemon`, for developing the plugin (docs/PROTOCOL.md §1).

    tools/mock-daemon.py daemon --hub <url> --data <dir>

Same argv and the same JSON-lines protocol as the real daemon, with the
engine replaced by an in-memory store persisted to <dir>/mock-state.json.
No hub: sync always reports "offline".

Extras for testing:
  * <dir>/mock-remote is a FIFO. Each JSON line written to it,
    {"note": "<id>|first", "pos": p, "del": d, "ins": "…"}, is applied as a
    remote edit and sent to the plugin as a `patch`.
  * Edits carry `ack` (the last patch pseq the client applied). An edit that
    crossed a patch in flight is transformed over the patches with pseq > ack,
    with src/core/ot.zig's rules (a port of xform), like the real engine.
"""
import base64
import hashlib
import html.parser
import json
import os
import random
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse

LOCK = threading.Lock()
OUT = sys.stdout


# --- UTF-16 text ----------------------------------------------------------

def u16(s):
    return len(s.encode("utf-16-le", "surrogatepass")) // 2


def to16(s):
    return s.encode("utf-16-le", "surrogatepass")


def from16(b):
    return b.decode("utf-16-le", "surrogatepass")


def slice16(s, a, b=None):
    raw = to16(s)
    return from16(raw[2 * a:] if b is None else raw[2 * a:2 * b])


# --- transform (a port of src/core/ot.zig xform / xformPrim) ----------------
# Prims are dicts {k: "ins"|"del", pos, len, text, tag}; positions in UTF-16.

def ins_prim(pos, text, tag):
    return {"k": "ins", "pos": pos, "len": 0, "text": text, "tag": tag}


def del_prim(pos, length, tag):
    return {"k": "del", "pos": pos, "len": length, "text": "", "tag": tag}


def empty(p):
    return u16(p["text"]) == 0 if p["k"] == "ins" else p["len"] == 0


def one(p):
    return [] if empty(p) else [p]


def two(p, q):
    if empty(p):
        return one(q)
    if empty(q):
        return one(p)
    return [p, q]


def prims_from_edit(pos, dele, ins, tag):
    out = []
    if dele > 0:
        out.append(del_prim(pos, dele, tag))
    if ins:
        out.append(ins_prim(pos, ins, tag))
    return out


def ins_vs_del(i, d):
    d_end = d["pos"] + d["len"]
    moved = dict(i)
    n = u16(i["text"])
    if i["pos"] <= d["pos"]:
        d2 = dict(d)
        d2["pos"] += n
        return one(moved), one(d2)
    if i["pos"] >= d_end:
        moved["pos"] -= d["len"]
        return one(moved), one(dict(d))
    moved["pos"] = d["pos"]
    before = del_prim(d["pos"], i["pos"] - d["pos"], d["tag"])
    after = del_prim(d["pos"] + n, d_end - i["pos"], d["tag"])
    return one(moved), two(before, after)


def del_vs_del(a, b):
    a_end = a["pos"] + a["len"]
    b_end = b["pos"] + b["len"]
    lo, hi = max(a["pos"], b["pos"]), min(a_end, b_end)
    overlap = hi - lo if hi > lo else 0
    r = dict(a)
    r["len"] = a["len"] - overlap
    r["pos"] = a["pos"] if a["pos"] <= b["pos"] else (a["pos"] - b["len"] if a["pos"] >= b_end else b["pos"])
    return r


def xform_prim(a, b, a_wins):
    if a["k"] == "ins":
        if b["k"] == "ins":
            a2, b2 = dict(a), dict(b)
            if a["pos"] < b["pos"] or (a["pos"] == b["pos"] and a_wins):
                b2["pos"] += u16(a["text"])
            else:
                a2["pos"] += u16(b["text"])
            return one(a2), one(b2)
        i, d = ins_vs_del(a, b)
        return i, d
    if b["k"] == "ins":
        i, d = ins_vs_del(b, a)
        return d, i
    return one(del_vs_del(a, b)), one(del_vs_del(b, a))


def xform(a, b, a_wins):
    if not a or not b:
        return [dict(p) for p in a], [dict(p) for p in b]
    if len(a) == 1 and len(b) == 1:
        return xform_prim(a[0], b[0], a_wins)
    if len(a) > 1:
        fa, fb = xform(a[:1], b, a_wins)
        ra, rb = xform(a[1:], fb, a_wins)
        return fa + ra, rb
    fa, fb = xform(a, b[:1], a_wins)
    ra, rb = xform(fa, b[1:], a_wins)
    return ra, fb + rb


def apply_prim(text, p):
    raw = to16(text)
    if p["k"] == "ins":
        return from16(raw[:2 * p["pos"]] + to16(p["text"]) + raw[2 * p["pos"]:])
    return from16(raw[:2 * p["pos"]] + raw[2 * (p["pos"] + p["len"]):])


# --- notes ------------------------------------------------------------------

TAG_RE = re.compile(r"(^|\s)#([\w\-/]+)", re.UNICODE)


def extract_tags(text):
    found = set()
    fenced = False
    for line in text.split("\n"):
        if re.match(r"^\s*(```|~~~)", line):
            fenced = not fenced
            continue
        if fenced:
            continue
        prose = re.sub(r"`[^`]*`", " ", line)
        for m in TAG_RE.finditer(prose):
            tag = re.sub(r"[/\-]+$", "", m.group(2)).lower()
            if tag and not tag.isdigit():
                found.add(tag)
    return sorted(found)


def summary(note):
    text = note["text"]
    first, _, rest = text.partition("\n")
    title = re.sub(r"^\s*#{1,6}\s+", "", first).strip()
    snippet = re.sub(r"\s+", " ", rest).strip()[:120]
    return {
        "id": note["id"], "title": title, "snippet": snippet,
        "folder": note.get("folder"), "tags": extract_tags(text),
        "pinned": bool(note.get("pinned")), "trashed": bool(note.get("trashed")),
        "created": note["created"], "updated": note["updated"],
    }


class Store:
    def __init__(self, data):
        self.data = data
        self.path = os.path.join(data, "mock-state.json")
        self.notes = {}
        self.folders = {}
        self.replica = "%016x" % random.getrandbits(64)
        self.counter = 0
        # Per open note: seq of the last applied client edit, and the patches
        # sent that the client has not acknowledged yet (as ops).
        self.open = {}
        self.load()

    def load(self):
        try:
            with open(self.path) as f:
                state = json.load(f)
            self.notes = state["notes"]
            self.folders = state["folders"]
            self.replica = state["replica"]
            self.counter = state["counter"]
        except (OSError, ValueError, KeyError):
            now = int(time.time() * 1000)
            welcome = self.new_id("n")
            self.notes[welcome] = {
                "id": welcome, "folder": None, "pinned": True, "trashed": False,
                "created": now, "updated": now,
                "text": "# Welcome to omajot\n\nThis note comes from the **mock daemon**.\n\n"
                        "- [ ] try a checkbox\n- [x] #omajot runs\n\nTags like #ideas work inline.\n",
            }
            self.save()

    def save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump({"notes": self.notes, "folders": self.folders,
                       "replica": self.replica, "counter": self.counter}, f)
        os.replace(tmp, self.path)

    def new_id(self, prefix):
        self.counter += 1
        return "%s-%s-%d" % (prefix, self.replica, self.counter)


# --- paste ------------------------------------------------------------------

EXTENSIONS = {"image/png": "png", "image/jpeg": "jpg", "image/gif": "gif",
              "image/webp": "webp", "image/svg+xml": "svg", "image/bmp": "bmp"}


def store_attachment(data_dir, blob, ext):
    digest = hashlib.sha256(blob).hexdigest()
    rel = "attachments/%s.%s" % (digest, ext)
    os.makedirs(os.path.join(data_dir, "attachments"), exist_ok=True)
    path = os.path.join(data_dir, rel)
    if not os.path.exists(path):
        with open(path, "wb") as f:
            f.write(blob)
    return rel


def image_ref(data_dir, src, alt=""):
    """Markdown for an image source: data:/file: become attachments."""
    m = re.match(r"data:(image/[\w+.-]+);base64,(.*)", src, re.S)
    if m and m.group(1) in EXTENSIONS:
        rel = store_attachment(data_dir, base64.b64decode(m.group(2)), EXTENSIONS[m.group(1)])
        return "![%s](%s)" % (alt, rel)
    if src.startswith("file://"):
        path = urllib.parse.unquote(src[7:])
        ext = os.path.splitext(path)[1].lstrip(".").lower() or "bin"
        try:
            with open(path, "rb") as f:
                rel = store_attachment(data_dir, f.read(), ext)
            return "![%s](%s)" % (alt, rel)
        except OSError:
            return alt
    if src.startswith(("http://", "https://")):
        return "![%s](%s)" % (alt, src)
    return alt


class HtmlToMarkdown(html.parser.HTMLParser):
    """Enough HTML → markdown for pastes from browsers and office apps."""

    def __init__(self, data_dir):
        super().__init__(convert_charrefs=True)
        self.data_dir = data_dir
        self.out = []
        self.lists = []
        self.href = None
        self.pre = False
        self.skip = 0

    def emit(self, s):
        self.out.append(s)

    def block(self):
        text = "".join(self.out)
        if text and not text.endswith("\n\n"):
            self.emit("\n" if text.endswith("\n") else "\n\n")

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag in ("style", "script", "head", "title"):
            self.skip += 1
        elif re.fullmatch(r"h[1-6]", tag):
            self.block(); self.emit("#" * int(tag[1]) + " ")
        elif tag in ("p", "div", "table", "tr"):
            self.block()
        elif tag == "br":
            self.emit("\n")
        elif tag in ("b", "strong"):
            self.emit("**")
        elif tag in ("i", "em"):
            self.emit("*")
        elif tag == "code" and not self.pre:
            self.emit("`")
        elif tag == "pre":
            self.block(); self.emit("```\n"); self.pre = True
        elif tag == "blockquote":
            self.block(); self.emit("> ")
        elif tag in ("ul", "ol"):
            if not self.lists:
                self.block()
            self.lists.append([tag, 0])
        elif tag == "li":
            depth = max(0, len(self.lists) - 1)
            kind = self.lists[-1] if self.lists else ["ul", 0]
            kind[1] += 1
            marker = "%d." % kind[1] if kind[0] == "ol" else "-"
            if "".join(self.out) and not "".join(self.out).endswith("\n"):
                self.emit("\n")
            self.emit("  " * depth + marker + " ")
        elif tag == "input" and a.get("type") == "checkbox":
            self.emit("[x] " if "checked" in a else "[ ] ")
        elif tag == "a":
            self.href = a.get("href")
            self.emit("[")
        elif tag == "img":
            self.emit(image_ref(self.data_dir, a.get("src", ""), a.get("alt", "")))
        elif tag in ("td", "th"):
            self.emit(" | ")

    def handle_endtag(self, tag):
        if tag in ("style", "script", "head", "title"):
            self.skip = max(0, self.skip - 1)
        elif re.fullmatch(r"h[1-6]", tag) or tag in ("p", "div", "blockquote", "table"):
            self.block()
        elif tag in ("b", "strong"):
            self.emit("**")
        elif tag in ("i", "em"):
            self.emit("*")
        elif tag == "code" and not self.pre:
            self.emit("`")
        elif tag == "pre":
            self.emit("\n```"); self.pre = False; self.block()
        elif tag in ("ul", "ol"):
            if self.lists:
                self.lists.pop()
            if not self.lists:
                self.block()
        elif tag == "a":
            self.emit("](%s)" % (self.href or ""))
            self.href = None
        elif tag == "tr":
            self.emit(" |\n")

    def handle_data(self, data):
        if self.skip:
            return
        self.emit(data if self.pre else re.sub(r"\s+", " ", data))

    def markdown(self):
        text = "".join(self.out)
        text = re.sub(r"[ \t]+\n", "\n", text)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text.strip()


def run(argv):
    try:
        return subprocess.run(argv, capture_output=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return b""


def paste_markdown(data_dir):
    types = run(["wl-paste", "--list-types"]).decode("utf-8", "replace").split("\n")
    types = [t.strip() for t in types if t.strip()]
    for t in types:
        if t in EXTENSIONS:
            blob = run(["wl-paste", "--no-newline", "--type", t])
            if blob:
                return "![](%s)" % store_attachment(data_dir, blob, EXTENSIONS[t])
    if "text/uri-list" in types:
        parts = []
        for uri in run(["wl-paste", "--no-newline", "--type", "text/uri-list"]).decode().split():
            if uri.startswith("file://"):
                path = urllib.parse.unquote(uri[7:])
                ext = os.path.splitext(path)[1].lstrip(".").lower() or "bin"
                try:
                    with open(path, "rb") as f:
                        rel = store_attachment(data_dir, f.read(), ext)
                except OSError:
                    continue
                name = os.path.basename(path)
                parts.append(("![%s](%s)" if ext in EXTENSIONS.values() else "[%s](%s)") % (name, rel))
        if parts:
            return "\n".join(parts)
    if "text/markdown" in types:
        text = run(["wl-paste", "--no-newline", "--type", "text/markdown"]).decode("utf-8", "replace")
        return re.sub(r"!\[([^\]]*)\]\(((?:data|file):[^)\s]+)[^)]*\)",
                      lambda m: image_ref(data_dir, m.group(2), m.group(1)), text)
    if "text/html" in types:
        parser = HtmlToMarkdown(data_dir)
        parser.feed(run(["wl-paste", "--no-newline", "--type", "text/html"]).decode("utf-8", "replace"))
        return parser.markdown()
    return run(["wl-paste", "--no-newline"]).decode("utf-8", "replace")


# --- protocol ---------------------------------------------------------------

def send(obj):
    with LOCK:
        OUT.write(json.dumps(obj, ensure_ascii=False) + "\n")
        OUT.flush()


class Engine:
    def __init__(self, store, hub, data):
        self.s = store
        self.hub = hub
        self.data = data

    def upsert(self, note):
        send({"ev": "notes", "upsert": [summary(note)]})

    def folders_event(self):
        send({"ev": "folders", "folders": list(self.s.folders.values())})

    def touch(self, note):
        note["updated"] = int(time.time() * 1000)
        self.s.save()
        self.upsert(note)

    def handle(self, req):
        cmd = req.get("cmd")
        rid = req.get("id", 0)
        s = self.s
        try:
            reply = getattr(self, "cmd_" + cmd.replace(".", "_"))(req) if cmd else None
        except AttributeError:
            return send({"re": rid, "ok": False, "error": "unknown command " + str(cmd)})
        except (KeyError, ValueError, TypeError) as error:
            return send({"re": rid, "ok": False, "error": "%s: %s" % (type(error).__name__, error)})
        out = {"re": rid, "ok": True}
        out.update(reply or {})
        send(out)
        after = getattr(self, "_after", None)
        if after:
            self._after = None
            after()

    def cmd_hello(self, req):
        self._after = lambda: send({"ev": "sync", "state": "offline", "pending": 0, "head": 0})
        return {"replica": self.s.replica, "version": "0.1.0-mock"}

    def cmd_list(self, req):
        return {"notes": [summary(n) for n in self.s.notes.values()],
                "folders": list(self.s.folders.values())}

    def cmd_open(self, req):
        note = self.s.notes[req["note"]]
        state = self.s.open.setdefault(note["id"], {"seq": 0, "pseq": 0, "unacked": []})
        return {"text": note["text"], "seq": state["seq"], "pseq": state["pseq"]}

    def cmd_close(self, req):
        return {}

    def cmd_edit(self, req):
        note = self.s.notes[req["note"]]
        state = self.s.open.setdefault(note["id"], {"seq": 0, "pseq": 0, "unacked": []})
        seq = int(req["seq"])
        if seq <= state["seq"]:
            return {}
        # Patches with pseq > ack were in flight when the client made this
        # edit: transform the edit over them (engine side wins ties).
        ack = int(req.get("ack", state["pseq"]))
        keep = [p for p in state["unacked"] if p["tag"] > ack]
        edit = prims_from_edit(int(req["pos"]), int(req["del"]), req.get("ins", ""), seq)
        mine, theirs = xform(edit, keep, False)
        state["unacked"] = theirs
        for p in mine:
            note["text"] = apply_prim(note["text"], p)
        state["seq"] = seq
        self.touch(note)
        return {}

    def cmd_create(self, req):
        now = int(time.time() * 1000)
        nid = self.s.new_id("n")
        self.s.notes[nid] = {"id": nid, "folder": req.get("folder"), "pinned": False,
                             "trashed": False, "created": now, "updated": now,
                             "text": req.get("text", "")}
        self.s.save()
        self._after = lambda: self.upsert(self.s.notes[nid])
        return {"note": nid}

    def cmd_set(self, req):
        note = self.s.notes[req["note"]]
        for key in ("folder", "pinned", "trashed"):
            if key in req:
                note[key] = req[key]
        self._after = lambda: self.touch(note)
        return {}

    def cmd_folder_create(self, req):
        fid = self.s.new_id("f")
        self.s.folders[fid] = {"id": fid, "name": str(req["name"]), "parent": req.get("parent")}
        self.s.save()
        self._after = self.folders_event
        return {"folder": fid}

    def cmd_folder_rename(self, req):
        self.s.folders[req["folder"]]["name"] = str(req["name"])
        self.s.save()
        self._after = self.folders_event
        return {}

    def cmd_folder_move(self, req):
        self.s.folders[req["folder"]]["parent"] = req.get("parent")
        self.s.save()
        self._after = self.folders_event
        return {}

    def cmd_folder_delete(self, req):
        fid = req["folder"]
        folder = self.s.folders.pop(fid)
        moved = []
        for other in self.s.folders.values():
            if other.get("parent") == fid:
                other["parent"] = folder.get("parent")
        for note in self.s.notes.values():
            if note.get("folder") == fid:
                note["folder"] = None
                moved.append(note)
        self.s.save()

        def after():
            self.folders_event()
            if moved:
                send({"ev": "notes", "upsert": [summary(n) for n in moved]})
        self._after = after
        return {}

    def cmd_search(self, req):
        q = str(req.get("q", "")).lower().strip()
        hits = [n for n in self.s.notes.values() if q and q in n["text"].lower()]
        hits.sort(key=lambda n: -n["updated"])
        return {"ids": [n["id"] for n in hits]}

    def cmd_paste(self, req):
        return {"ins": paste_markdown(self.data)}

    def cmd_status(self, req):
        return {"sync": "offline", "hub": self.hub, "pending": 0, "head": 0}

    # Remote edits from the FIFO, relative to the note's current text.
    def remote(self, msg):
        notes = sorted(self.s.notes.values(), key=lambda n: -n["updated"])
        nid = notes[0]["id"] if msg.get("note") == "first" and notes else msg.get("note")
        note = self.s.notes.get(nid)
        if not note:
            return
        length = u16(note["text"])
        pos = max(0, min(length, int(msg.get("pos", length))))
        dele = max(0, min(length - pos, int(msg.get("del", 0))))
        ins = msg.get("ins", "")
        state = self.s.open.get(nid)
        tag = state["pseq"] + 1 if state is not None else 0
        prims = prims_from_edit(pos, dele, ins, tag)
        for p in prims:
            note["text"] = apply_prim(note["text"], p)
        if state is not None:
            state["pseq"] = tag
            state["unacked"].extend(prims)
            send({"ev": "patch", "note": nid, "base": state["seq"], "pseq": tag,
                  "pos": pos, "del": dele, "ins": ins})
        self.touch(note)


def fifo_loop(engine, path):
    try:
        os.unlink(path)
    except OSError:
        pass
    os.mkfifo(path, 0o600)
    while True:
        with open(path) as fifo:
            for line in fifo:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                except ValueError:
                    continue
                with LOCK_ENGINE:
                    engine.remote(msg)


LOCK_ENGINE = threading.Lock()


def main():
    args = sys.argv[1:]
    if args and args[0] == "daemon":
        args = args[1:]
    if "--help" in args:
        print(__doc__)
        return
    hub = "https://localhost"
    data = os.path.join(os.environ.get("XDG_DATA_HOME") or os.path.expanduser("~/.local/share"), "omajot")
    for i, arg in enumerate(args):
        if arg == "--hub" and i + 1 < len(args):
            hub = args[i + 1]
        if arg == "--data" and i + 1 < len(args):
            data = args[i + 1]
    os.makedirs(data, exist_ok=True)
    engine = Engine(Store(data), hub, data)
    threading.Thread(target=fifo_loop, args=(engine, os.path.join(data, "mock-remote")), daemon=True).start()
    print("mock daemon ready data=%s" % data, file=sys.stderr, flush=True)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req = json.loads(line)
        except ValueError:
            send({"ev": "error", "error": "bad json"})
            continue
        with LOCK_ENGINE:
            engine.handle(req)


if __name__ == "__main__":
    main()
