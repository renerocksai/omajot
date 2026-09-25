#!/usr/bin/env python3
"""End-to-end check of the omajot commands (src/cli) and the daemon socket.

    tools/cli_e2e.py [--bin zig-out/bin/omajot] [--keep]

Starts a hub on a free loopback port (--no-auth) and two daemons in scratch
data directories: A (driven like the plugin over stdin/stdout, and by the
commands over its socket) and B (another device, driven like the plugin).
Everything lives in one temporary directory; HOME and the XDG directories
point there, so the real config, data and socket are never used.
"""
import argparse, json, os, queue, shutil, socket, subprocess, sys, tempfile, threading, time

ROOT = None
BIN = None
ENV = None


class Daemon:
    """A daemon driven like the Omarchy plugin: JSON lines on stdin/stdout."""

    def __init__(self, name, data, sock, hub):
        self.name = name
        args = [BIN, "daemon", "--data", data, "--socket", sock] + (["--hub", hub] if hub else ["--no-hub"])
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
                                     env=ENV, stderr=open(os.path.join(ROOT, f"{name}.stderr"), "a"))
        self.lines = queue.Queue()
        self.next_id = 1
        self.text, self.seq, self.pseq = {}, {}, {}
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            if not line.strip():
                continue
            msg = json.loads(line)
            if msg.get("ev") == "patch" and msg["note"] in self.text:
                t = self.text[msg["note"]]
                self.text[msg["note"]] = t[:msg["pos"]] + msg["ins"] + t[msg["pos"] + msg["del"]:]
                self.pseq[msg["note"]] = msg["pseq"]
            self.lines.put(msg)

    def call(self, cmd, timeout=15, **fields):
        rid = self.next_id
        self.next_id += 1
        self.proc.stdin.write(json.dumps({"id": rid, "cmd": cmd, **fields}) + "\n")
        self.proc.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg = self.lines.get(timeout=max(0.01, deadline - time.time()))
            except queue.Empty:
                break
            if msg.get("re") == rid:
                if not msg.get("ok"):
                    raise RuntimeError(f"{self.name} {cmd}: {msg}")
                return msg
        raise TimeoutError(f"{self.name}: no reply to {cmd}")

    def open(self, note):
        r = self.call("open", note=note)
        self.text[note], self.seq[note], self.pseq[note] = r["text"], r["seq"], r["pseq"]

    def edit(self, note, pos, delete, ins):
        self.seq[note] += 1
        self.call("edit", note=note, seq=self.seq[note], ack=self.pseq[note], pos=pos, ins=ins, **{"del": delete})
        t = self.text[note]
        self.text[note] = t[:pos] + ins + t[pos + delete:]

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()


def omajot(data, sock, *args, stdin=None, env=None, check=True, want=0):
    r = subprocess.run([BIN, *args, "--data", data, "--socket", sock], input=stdin, capture_output=True,
                       text=True, env=env or ENV, timeout=60)
    if check and r.returncode != want:
        raise AssertionError(f"omajot {' '.join(args)}: exit {r.returncode}, want {want}\nstdout: {r.stdout}\nstderr: {r.stderr}")
    return r


def jomajot(data, sock, *args, **kw):
    r = omajot(data, sock, *args, "--json", **kw)
    return json.loads(r.stdout)


def wait_for(pred, what, timeout=30):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return
        time.sleep(0.1)
    raise TimeoutError(what)


def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def start_hub(port, data):
    hub = subprocess.Popen([BIN, "hub", "--port", str(port), "--data", data, "--no-auth", "--timeout-ms", "8000"],
                           stdout=subprocess.DEVNULL, stderr=open(os.path.join(ROOT, "hub.stderr"), "a"), env=ENV)
    wait_for(lambda: socket.socket().connect_ex(("127.0.0.1", port)) == 0, "hub up", 10)
    return hub


FAKE_EDITOR = r'''
import os, sys, time
path = sys.argv[1]
flag = os.environ["FAKE_EDITOR_DIR"]
text = open(path).read()
open(path, "w").write(text + "first save\n")
open(os.path.join(flag, "saved1"), "w").close()
while not os.path.exists(os.path.join(flag, "go")):
    time.sleep(0.05)
text = open(path).read()
open(path, "w").write(text.replace("first save", "first save, then second save"))
time.sleep(0.8)
'''


def main():
    global ROOT, BIN, ENV
    ap = argparse.ArgumentParser()
    ap.add_argument("--bin", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "zig-out", "bin", "omajot"))
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    BIN = os.path.abspath(a.bin)
    ROOT = tempfile.mkdtemp(prefix="omajot-cli-", dir="/tmp")
    ENV = dict(os.environ, HOME=ROOT, XDG_CONFIG_HOME=os.path.join(ROOT, "config"),
               XDG_DATA_HOME=os.path.join(ROOT, "share"), XDG_RUNTIME_DIR=ROOT, TZ="UTC")
    ENV.pop("VISUAL", None)
    port = free_port()
    hub_url = f"http://127.0.0.1:{port}"
    os.makedirs(os.path.join(ROOT, "hub"))
    hub = start_hub(port, os.path.join(ROOT, "hub"))
    da, sa = os.path.join(ROOT, "a"), os.path.join(ROOT, "a.sock")
    db, sb = os.path.join(ROOT, "b"), os.path.join(ROOT, "b.sock")
    A = Daemon("A", da, sa, hub_url)
    B = Daemon("B", db, sb, hub_url)
    t0 = time.time()
    others = []

    def step(msg):
        print(f"[{time.time() - t0:5.1f}s] {msg}")

    try:
        # The site repeats every command's usage line from its --help.
        import html as htmlmod
        page = htmlmod.unescape(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "site", "pages", "cli.html")).read())
        for verb in ["ls", "cat", "search", "new", "write", "edit", "append", "replace", "mv", "rm", "mkdir", "rmdir",
                     "tags", "history", "restore", "export", "status"]:
            usage = subprocess.run([BIN, verb, "--help"], capture_output=True, text=True, env=ENV).stdout.splitlines()[0]
            assert usage.startswith("usage: ") and usage[len("usage: "):] in page, f"cli.html lacks: {usage}"
        step("site/pages/cli.html has the usage line of every command")

        A.call("hello", client="qml")
        B.call("hello", client="qml")
        wait_for(lambda: os.path.exists(sa), "A socket")
        assert oct(os.stat(sa).st_mode & 0o777) == "0o600", oct(os.stat(sa).st_mode)

        # --- new, ls, ambiguous names, addressing by path and id
        a1 = jomajot(da, sa, "new", "Todo", "- call Anna", "--folder", "Work/Plans")
        a2 = jomajot(da, sa, "new", "Todo", "- buy milk", "--folder", "Home")
        assert a1["path"] == "Work/Plans/Todo" and a2["path"] == "Home/Todo", (a1, a2)
        amb = omajot(da, sa, "cat", "Todo", want=2)
        assert a1["id"] in amb.stderr and a2["id"] in amb.stderr, amb.stderr
        amb_json = json.loads(omajot(da, sa, "cat", "Todo", "--json", want=2).stdout)
        assert {c["id"] for c in amb_json["candidates"]} == {a1["id"], a2["id"]}
        assert omajot(da, sa, "cat", "work/plans/todo").stdout == "# Todo\n\n- call Anna\n"
        assert omajot(da, sa, "cat", a2["id"]).stdout == "# Todo\n\n- buy milk\n"
        omajot(da, sa, "cat", "Nope", want=1)
        ls = jomajot(da, sa, "ls", "-r")
        assert {n["path"] for n in ls["notes"]} == {"Work/Plans/Todo", "Home/Todo"}, ls
        top = jomajot(da, sa, "ls")
        assert {f["name"] for f in top["folders"]} == {"Home", "Work"} and top["notes"] == []
        step("new, ls, paths, ids, ambiguous (exit 2) and not found (exit 1)")

        # --- append / replace
        omajot(da, sa, "append", "Home/Todo", "- eggs")
        omajot(da, sa, "append", "Home/Todo", "-", stdin="- bread")
        omajot(da, sa, "replace", "Home/Todo", "- ", "* ", want=2)
        omajot(da, sa, "replace", "Home/Todo", "cheese", "brie", want=1)
        omajot(da, sa, "replace", "Home/Todo", "milk", "oat milk")
        r = jomajot(da, sa, "replace", "Home/Todo", "- ", "* ", "--all")
        assert r["count"] == 3, r
        assert omajot(da, sa, "cat", "Home/Todo").stdout == "# Todo\n\n* buy oat milk\n* eggs\n* bread\n"
        step("append, replace (exactly once, --all, 0 → exit 1, many → exit 2)")

        # --- CLI write on A while B edits the same note on another device
        note = a2["id"]
        wait_for(lambda: any(n["id"] == note for n in B.call("list")["notes"]), "note on B")
        B.open(note)
        wait_for(lambda: B.text[note] == omajot(da, sa, "cat", "Home/Todo").stdout, "B has A's text")
        hub.terminate(); hub.wait()
        B.edit(note, B.text[note].index("* eggs"), 0, "* B was here\n")
        cur = omajot(da, sa, "cat", "Home/Todo").stdout
        omajot(da, sa, "write", "Home/Todo", stdin=cur.replace("* bread\n", "* bread\n* A wrote this\n"))
        hub = start_hub(port, os.path.join(ROOT, "hub"))
        want_both = lambda t: "B was here" in t and "A wrote this" in t
        wait_for(lambda: want_both(omajot(da, sa, "cat", "Home/Todo").stdout), "B's edit on A", 60)
        wait_for(lambda: want_both(B.text[note]), "A's write on B", 60)
        final = omajot(da, sa, "cat", "Home/Todo").stdout
        assert final == B.text[note] == B.call("read", note=note)["text"], (final, B.text[note])
        step(f"concurrent: CLI write on A + edit on B both survive: {final!r}")

        # --- the plugin session on A gets the CLI's change as a patch
        A.open(a1["id"])
        omajot(da, sa, "append", a1["id"], "- plugin sees this")
        wait_for(lambda: A.text[a1["id"]] == omajot(da, sa, "cat", a1["id"]).stdout, "patch to A's plugin session", 10)
        step("CLI change reaches the open plugin session as a patch")

        # --- edit with a fake $EDITOR that saves twice, while B edits too
        flagdir = os.path.join(ROOT, "editor-flags")
        os.makedirs(flagdir)
        editor = os.path.join(ROOT, "fake_editor.py")
        open(editor, "w").write(FAKE_EDITOR)
        env = dict(ENV, EDITOR=f"{sys.executable} {editor}", FAKE_EDITOR_DIR=flagdir)
        p = subprocess.Popen([BIN, "edit", "Home/Todo", "--data", da, "--socket", sa, "--json"], env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        wait_for(lambda: os.path.exists(os.path.join(flagdir, "saved1")), "first save")
        wait_for(lambda: "first save" in omajot(da, sa, "cat", "Home/Todo").stdout, "first save applied", 10)
        wait_for(lambda: "first save" in B.text[note], "first save on B", 30)
        B.edit(note, len("# Todo\n"), 0, "B during edit\n")
        open(os.path.join(flagdir, "go"), "w").close()
        out, err = p.communicate(timeout=60)
        assert p.returncode == 0, (out, err)
        res = json.loads(out)
        assert res["saves"] == 2, res
        want = lambda t: "first save, then second save" in t and "B during edit" in t and "B was here" in t
        wait_for(lambda: want(omajot(da, sa, "cat", "Home/Todo").stdout), "edit + B merged on A", 60)
        wait_for(lambda: want(B.text[note]), "edit on B", 60)
        assert omajot(da, sa, "cat", "Home/Todo").stdout == B.text[note]
        step(f"edit: fake editor saved twice, B's concurrent edit kept (merged={res['merged']})")

        # --- history, cat --at, restore
        h = jomajot(da, sa, "new", "Diary", "v1")
        time.sleep(0.05)
        t_v1 = int(time.time() * 1000)
        time.sleep(0.05)
        omajot(da, sa, "write", "Diary", stdin="# Diary\n\nv2\n")
        hist = jomajot(da, sa, "history", "Diary")
        assert hist["versions"] and hist["versions"][0]["created"] and hist["versions"][0]["self"], hist
        assert omajot(da, sa, "cat", "Diary", "--at", str(t_v1)).stdout == "# Diary\n\nv1\n"
        r = jomajot(da, sa, "restore", "Diary", str(t_v1))
        assert r["changed"], r
        assert omajot(da, sa, "cat", "Diary").stdout == "# Diary\n\nv1\n"
        assert "v2" not in omajot(da, sa, "cat", "Diary").stdout
        omajot(da, sa, "cat", "Diary", "--at", "2000-01-01", want=1)
        step("history, cat --at, restore to a time")

        # --- rm / --restore, mv, mkdir, rmdir, tags, search
        omajot(da, sa, "rm", "Diary")
        assert [n["path"] for n in jomajot(da, sa, "ls", "--trash")["notes"]] == ["Diary"]
        omajot(da, sa, "rm", "Diary", "--restore")
        omajot(da, sa, "mkdir", "Archive/2026")
        omajot(da, sa, "mv", "Diary", "Archive/2026")
        assert omajot(da, sa, "cat", "Archive/2026/Diary").returncode == 0
        omajot(da, sa, "rmdir", "Archive", want=3)
        omajot(da, sa, "append", "Archive/2026/Diary", "#journal #private")
        assert {t["tag"] for t in jomajot(da, sa, "tags")["tags"]} >= {"journal", "private"}
        assert [n["path"] for n in jomajot(da, sa, "search", "JOURNAL")["notes"]] == ["Archive/2026/Diary"]
        omajot(da, sa, "search", "no such text anywhere", want=1)
        step("rm/--restore, mkdir, mv, rmdir refuses non-empty, tags, search")

        # --- export round trip, with an attachment in a subfolder note
        img = os.path.join(ROOT, "pixel.png")
        open(img, "wb").write(b"\x89PNG\r\n\x1a\n" + b"\0" * 16)
        att = A.call("attach", path=img)["name"]
        omajot(da, sa, "append", "Work/Plans/Todo", f"![pixel]({att})")
        exp = os.path.join(ROOT, "export")
        e = jomajot(da, sa, "export", exp)
        assert e["notes"] == 3 and e["attachments"] == 1, e
        for f in e["files"]:
            body = open(os.path.join(exp, f["file"])).read()
            text = omajot(da, sa, "cat", f["id"]).stdout
            depth = f["file"].count("/")
            assert body == text.replace("(attachments/", "(" + "../" * depth + "attachments/"), (f, body, text)
        assert os.path.exists(os.path.join(exp, "Work", "Plans", "../..", att))
        assert os.path.exists(os.path.join(exp, "README.md"))
        omajot(da, sa, "export", exp, want=3)
        step(f"export: {e['notes']} files match cat, attachment link works, README written")

        # --- one daemon per data directory; --no-start; background start and handover
        r = subprocess.run([BIN, "daemon", "--data", da, "--socket", os.path.join(ROOT, "x.sock"), "--no-hub"],
                           input="", capture_output=True, text=True, env=ENV, timeout=10)
        assert r.returncode == 3 and "another omajot daemon" in r.stderr, r
        dc, sc = os.path.join(ROOT, "c"), os.path.join(ROOT, "c.sock")
        omajot(dc, sc, "status", "--no-start", want=69)
        st = jomajot(dc, sc, "status", "--no-hub")
        assert st["mode"] == "background" and st["data"] == dc, st
        omajot(dc, sc, "new", "Background note", "--no-hub")
        C = Daemon("C", dc, sc, None)  # a plugin daemon takes over from the background one
        others.append(C)
        C.call("hello", client="qml")
        wait_for(lambda: os.path.exists(sc), "C socket")
        st = jomajot(dc, sc, "status", "--no-start")
        assert st["mode"] == "plugin", st
        assert omajot(dc, sc, "cat", "Background note", "--no-start").stdout == "# Background note\n"
        step("lock: second daemon exits 3; --no-start → 69; background daemon hands over to a plugin daemon")

        print("CLI E2E PASS")
    finally:
        for d in [A, B, *others]:
            d.close()
        hub.terminate()
        try:
            hub.wait(timeout=15)
        except subprocess.TimeoutExpired:
            hub.kill()
        # Background daemons that a failed step left behind.
        for sub in os.listdir(ROOT):
            try:
                os.kill(json.load(open(os.path.join(ROOT, sub, "daemon.lock")))["pid"], 15)
            except Exception:
                pass
        if a.keep:
            print("kept", ROOT)
        else:
            shutil.rmtree(ROOT, ignore_errors=True)


if __name__ == "__main__":
    main()
