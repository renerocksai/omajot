#!/usr/bin/env python3
"""End-to-end check of `omajot tui` in a detached tmux session of a fixed size.

    tools/tui_e2e.py [--bin zig-out/bin/omajot] [--keep] [--capture FILE]

Starts a hub on a free loopback port (--no-auth), seeds the sample notes
(tools/seed_sample.py), starts a daemon with explicit --data and --socket, and
a second daemon ("device B") that syncs through the same hub. The TUI runs in a
private tmux server (tmux -L), 160x45. HOME and the XDG directories point into
one temporary directory, so the real config, data, socket and tmux are never
used. $EDITOR is a fake editor that takes an argument.

Checks: layout and row widths, navigation, server-side search, a new note
through the editor, an edit while `omajot write` changes the same note (both
survive), pin, Trash and restore, move to a folder, new, renamed and deleted folder,
live refresh (a CLI note, a note from device B), the help overlay, resize,
and that `q`, a panic and SIGTERM all give the terminal back (`stty -a`).

--capture FILE writes the first screen at 110x30 (sample notes only) as plain
text (the docs show a screenshot instead: site/assets/shots/tui-*).
"""
import argparse, json, os, shutil, socket, subprocess, sys, tempfile, time, unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from cli_e2e import Daemon, free_port, wait_for  # noqa: E402
import cli_e2e  # noqa: E402

ROOT = os.path.dirname(HERE)
W, H = 160, 45

FAKE_EDITOR = r'''
import json, os, sys, time
# usage: fake_editor.py --plan PLAN FILE (the argument checks that $EDITOR may carry one)
assert sys.argv[1] == "--plan", sys.argv
plan = json.load(open(sys.argv[2]))
path = sys.argv[3]
def save(extra):
    text = open(path).read()
    open(path, "w").write(text + extra)
if plan["mode"] == "append":
    save(plan["text"])
    time.sleep(0.5)
elif plan["mode"] == "two-saves":
    save(plan["first"])
    time.sleep(1.0)  # the TUI applies it (it looks every 250 ms)
    open(plan["flag"], "w").write("saved")
    deadline = time.time() + 30
    while not os.path.exists(plan["go"]) and time.time() < deadline:
        time.sleep(0.05)
    save(plan["second"])
    time.sleep(0.5)
'''


class Env:
    def __init__(self, tmp, binary):
        self.tmp = tmp
        self.bin = binary
        self.data = os.path.join(tmp, "a")
        self.run = os.path.join(tmp, "run")
        self.sock = os.path.join(self.run, "a.sock")
        os.makedirs(self.run, mode=0o700)
        self.env = dict(os.environ)
        for k in ("VISUAL", "EDITOR", "NO_COLOR", "TMUX", "TMUX_PANE"):
            self.env.pop(k, None)
        self.env.update(HOME=os.path.join(tmp, "home"), XDG_CONFIG_HOME=os.path.join(tmp, "config"),
                        XDG_DATA_HOME=os.path.join(tmp, "share"), XDG_RUNTIME_DIR=self.run,
                        XDG_STATE_HOME=os.path.join(tmp, "state"))
        os.makedirs(self.env["HOME"])
        self.tmux_name = "omajot-tui-e2e-%d" % os.getpid()
        self.plan = os.path.join(tmp, "plan.json")
        self.editor = os.path.join(tmp, "fake_editor.py")
        open(self.editor, "w").write(FAKE_EDITOR)
        # Intercept the platform opener: never open real apps during the test.
        self.bin_dir = os.path.join(tmp, "fakebin")
        self.opened = os.path.join(tmp, "opened.txt")
        os.makedirs(self.bin_dir)
        for name in ("xdg-open", "open"):
            opener = os.path.join(self.bin_dir, name)
            open(opener, "w").write(f'#!/bin/sh\necho "$1" >> "{self.opened}"\n')
            os.chmod(opener, 0o755)

    def call(self, cmd, **fields):
        """One request on the daemon socket (what the TUI talks to)."""
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(15)
        s.connect(self.sock)
        f = s.makefile("rw")
        f.write(json.dumps({"id": 1, "cmd": cmd, **fields}) + "\n")
        f.flush()
        for line in f:
            msg = json.loads(line)
            if msg.get("re") == 1:
                s.close()
                if not msg.get("ok"):
                    raise RuntimeError(f"{cmd}: {msg}")
                return msg
        raise RuntimeError(f"{cmd}: no reply")

    def note(self, title):
        for n in self.call("list")["notes"]:
            if n["title"] == title:
                return n
        return None

    def omajot(self, *args, stdin=None):
        r = subprocess.run([self.bin, *args, "--data", self.data, "--socket", self.sock], input=stdin,
                           capture_output=True, text=True, env=self.env, timeout=60)
        if r.returncode != 0:
            raise AssertionError(f"omajot {args}: {r.returncode} {r.stderr}")
        return r.stdout

    # ---------------------------------------------------------------- tmux

    def tmux(self, *args, check=True):
        return subprocess.run(["tmux", "-L", self.tmux_name, "-f", "/dev/null", *args], capture_output=True,
                              text=True, env=self.env, check=check).stdout

    def script(self, name, tui_args="", extra_env="", background=False):
        path = os.path.join(self.tmp, name + ".sh")
        tui = f'"{self.bin}" tui --data "{self.data}" --socket "{self.sock}" --no-start {tui_args} 2>"{self.tmp}/{name}.stderr"'
        run = f'{tui} & echo $! > "{self.tmp}/{name}.pid"; wait $!' if background else tui
        open(path, "w").write(f"""
export HOME="{self.env['HOME']}" XDG_CONFIG_HOME="{self.env['XDG_CONFIG_HOME']}" XDG_DATA_HOME="{self.env['XDG_DATA_HOME']}"
export XDG_RUNTIME_DIR="{self.run}" XDG_STATE_HOME="{self.env['XDG_STATE_HOME']}"
export EDITOR='python3 {self.editor} --plan {self.plan}'
export PATH="{self.bin_dir}:$PATH"
unset VISUAL NO_COLOR
{extra_env}
stty -a > "{self.tmp}/{name}.stty.before"
{run}
code=$?
stty -a > "{self.tmp}/{name}.stty.after"
echo "EXIT=$code"
exec sleep 100000
""")
        return path

    def start(self, name, **kw):
        self.tmux("new-session", "-d", "-s", name, "-x", str(W), "-y", str(H), "sh " + self.script(name, **kw))

    def screen(self, name="tui"):
        return self.tmux("capture-pane", "-p", "-t", name)

    def keys(self, *keys, name="tui"):
        # One at a time: Escape followed at once by a key reads as Alt+key.
        for k in keys:
            self.tmux("send-keys", "-t", name, k)
            time.sleep(0.15)

    def click(self, col, row, pause=0.2, name="tui"):
        """A left click on a cell (0-based), as an SGR mouse report."""
        self.tmux("send-keys", "-t", name, "-l", f"\x1b[<0;{col + 1};{row + 1}M\x1b[<0;{col + 1};{row + 1}m")
        time.sleep(pause)

    def wheel(self, col, row, down, name="tui"):
        self.tmux("send-keys", "-t", name, "-l", f"\x1b[<{65 if down else 64};{col + 1};{row + 1}M")
        time.sleep(0.2)

    def text(self, s, name="tui"):
        self.tmux("send-keys", "-t", name, "-l", s)
        time.sleep(0.2)

    def wait_screen(self, pred, what, timeout=15, name="tui"):
        deadline = time.time() + timeout
        last = ""
        while time.time() < deadline:
            last = self.screen(name)
            if (pred(last) if callable(pred) else pred in last):
                return last
            time.sleep(0.1)
        raise AssertionError(f"timeout: {what}\n--- screen ---\n{last}")

    def stty_same(self, name):
        before = open(os.path.join(self.tmp, name + ".stty.before")).read()
        after = open(os.path.join(self.tmp, name + ".stty.after")).read()
        return before == after


def cells(s):
    n = 0
    for ch in s:
        if unicodedata.combining(ch) or ch in "‍️":
            continue
        n += 2 if unicodedata.east_asian_width(ch) in "WF" else 1
    return n


def rows(screen):
    return screen.split("\n")


def status(screen):
    return rows(screen)[H - 1]


def strip_glyphs(s):
    return "".join(ch for ch in s if not ("" <= ch <= "")).strip()


def card_title(screen, i):
    """Title of the i-th card in the notes column (wide layout)."""
    line = rows(screen)[1 + 3 * i][31:73]
    return strip_glyphs(line.split("  #")[0])


def preview_title(screen):
    return rows(screen)[3][75:].strip(" │")


def folder_order(folders):
    """Folders as the move picker lists them: tree order, siblings by name."""
    out = []

    def walk(parent, depth):
        kids = [f for f in folders if f.get("parent") == parent]
        for f in sorted(kids, key=lambda f: f["name"].lower()):
            out.append(f)
            walk(f["id"], depth + 1)
    walk(None, 0)
    return out


def ok(msg):
    print(f"ok  {msg}", flush=True)


def kitty_pictures(e):
    """tmux shows no pictures, so this runs the TUI on a pty that answers
    the Kitty graphics query like Kitty or Ghostty, opens the note with a
    picture, and looks for the picture being sent and placed."""
    import fcntl, pty, select, struct, termios
    pid, fd = pty.fork()
    if pid == 0:
        os.execve(e.bin, [e.bin, "tui", "--data", e.data, "--socket", e.sock, "--no-start"], e.env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", H, W, 0, 0))
    out = bytearray()
    answered = False

    def read_until(pred, what, timeout=15):
        nonlocal answered
        deadline = time.time() + timeout
        while time.time() < deadline:
            r, _, _ = select.select([fd], [], [], 0.1)
            if r:
                try:
                    out.extend(os.read(fd, 65536))
                except OSError:
                    break
            if not answered and b"\x1b_Gi=1,a=q" in out:
                os.write(fd, b"\x1b_Gi=1;OK\x1b\\\x1b[?62;22c")  # graphics OK, then DA1
                answered = True
            if pred():
                return
        raise AssertionError(f"timeout: {what}; last output: {bytes(out[-400:])!r}")

    read_until(lambda: b"All notes" in out, "kitty pty: first screen")
    mark = len(out)
    os.write(fd, b"/")
    time.sleep(0.2)
    os.write(fd, b"lisbon\r")
    read_until(lambda: b"\x1b_Ga=p" in out[mark:], "a picture placement (a=p) for the Lisbon note")
    sent = out[mark:]
    assert b"\x1b_Gf=" in sent, "no picture transmission (f=…) before the placement"
    assert b"shows no pictures" not in sent
    os.write(fd, b"q")
    read_until(lambda: b"\x1b[?1049l" in out[mark:], "kitty pty: alt screen left")
    _, st = os.waitpid(pid, 0)
    os.close(fd)
    assert os.WIFEXITED(st) and os.WEXITSTATUS(st) == 0, st


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", default=os.path.join(ROOT, "zig-out", "bin", "omajot"))
    ap.add_argument("--keep", action="store_true", help="keep the temporary directory")
    ap.add_argument("--capture", help="write the first screen here (plain text)")
    args = ap.parse_args()
    if not shutil.which("tmux"):
        sys.exit("tui_e2e: needs tmux")

    # Short base path: unix socket paths are limited to ~100 bytes.
    tmp = tempfile.mkdtemp(prefix="omajot-tui-", dir="/tmp")
    e = Env(tmp, os.path.abspath(args.bin))
    cli_e2e.ROOT, cli_e2e.BIN, cli_e2e.ENV = tmp, e.bin, e.env
    procs = []
    b = None
    try:
        port = free_port()
        hub_url = f"http://127.0.0.1:{port}"
        procs.append(cli_e2e.start_hub(port, os.path.join(tmp, "hub")))
        subprocess.run([sys.executable, os.path.join(HERE, "seed_sample.py"), "--data", e.data, "--hub", hub_url,
                        "--binary", e.bin], env=e.env, check=True, capture_output=True, text=True, timeout=120)
        procs.append(subprocess.Popen([e.bin, "daemon", "--background", "--data", e.data, "--socket", e.sock,
                                       "--hub", hub_url], env=e.env, stdout=subprocess.DEVNULL,
                                      stderr=open(os.path.join(tmp, "daemon.stderr"), "w")))
        wait_for(lambda: os.path.exists(e.sock), "daemon socket", 15)
        b = Daemon("b", os.path.join(tmp, "b"), "", hub_url)
        b.call("hello", client="e2e")

        # -------------------------------------------------- start, layout
        theme = os.path.join(e.env["HOME"], ".local/state/omarchy/current/theme")
        os.makedirs(theme)
        open(os.path.join(theme, "colors.toml"), "w").write('accent = "#8bc9eb"\nbackground = "#16242d"\n')
        e.start("tui")
        s = e.wait_screen(lambda s: "Synced" in status(s) and "All notes · " in s, "first screen with Synced")
        live = [n for n in e.call("list")["notes"] if not n["trashed"]]
        assert f"All notes · {len(live)} " in rows(s)[0], rows(s)[0]
        for i, line in enumerate(rows(s)[:H - 1]):
            assert cells(line) == W, f"row {i} is {cells(line)} cells: {line!r}"
        assert "FOLDERS" in s and "TAGS" in s and "Trash" in s and " preview " in rows(s)[0]
        ok(f"three columns, {len(live)} notes, every row {W} cells, status Synced")
        ansi = e.tmux("capture-pane", "-p", "-e", "-t", "tui")
        assert "38;2;139;201;235" in ansi and "48;2;22;36;45" in ansi, "Omarchy theme colours not used"
        ok("colours from the Omarchy theme's colors.toml")
        if args.capture:
            # The narrowest three-column layout, for the docs.
            e.tmux("resize-window", "-t", "tui", "-x", "110", "-y", "30")
            c = e.wait_screen(lambda c: cells(rows(c)[0]) == 110 and len(rows(c)) >= 30 and "FOLDERS" in c, "110x30")
            with open(args.capture, "w") as f:
                f.write("\n".join(line.rstrip() for line in rows(c)[:30]) + "\n")
            e.tmux("resize-window", "-t", "tui", "-x", str(W), "-y", str(H))
            e.wait_screen(lambda c: cells(rows(c)[0]) == W, "back to 160x45")
            ok(f"capture (110x30) written to {args.capture}")

        # -------------------------------------------------- navigation
        first, second = card_title(s, 0), card_title(s, 1)
        assert preview_title(s) == first, (preview_title(s), first)
        e.keys("j")
        e.wait_screen(lambda s: preview_title(s) == second, f"preview shows {second!r} after j")
        e.keys("k")
        e.wait_screen(lambda s: preview_title(s) == first, "back with k")
        e.keys("h", "j")
        e.wait_screen(lambda s: "Pinned · 2" in rows(s)[0], "h then j selects Pinned")
        e.keys("g", "l")
        e.wait_screen(lambda s: "All notes · " in rows(s)[0], "g selects All notes")
        ok("j/k move the note, h/j/g/l the source")

        # -------------------------------------------------- search
        e.keys("/")
        e.text("lisbon")
        s = e.wait_screen(lambda s: "All notes · 1 " in rows(s)[0], "search narrows to one note")
        assert preview_title(s) == "Lisbon in October", preview_title(s)
        e.keys("Enter", "Escape")
        e.wait_screen(lambda s: f"All notes · {len(live)} " in rows(s)[0], "Esc clears the search")
        ok("/ searches in the daemon, Esc clears")

        # -------------------------------------------------- new note via the editor
        json.dump({"mode": "append", "text": "Written by the fake editor\n"}, open(e.plan, "w"))
        e.keys("n")
        e.wait_screen("Title of the new note", "title prompt")
        e.text("TUI made this")
        e.keys("Enter")
        s = e.wait_screen(lambda s: "Saved “TUI made this”" in status(s), "saved after the editor")
        text = e.omajot("cat", "TUI made this")
        assert text.startswith("# TUI made this\n") and "Written by the fake editor" in text, text
        assert preview_title(s) == "TUI made this"
        ok("n: title, editor with an argument, saved and shown")

        # -------------------------------------------------- edit while the CLI writes
        flag, go = os.path.join(tmp, "flag"), os.path.join(tmp, "go")
        json.dump({"mode": "two-saves", "first": "first TUI save\n", "second": "second TUI save\n",
                   "flag": flag, "go": go}, open(e.plan, "w"))
        e.keys("e")
        wait_for(lambda: os.path.exists(flag), "the editor's first save", 20)
        current = e.omajot("cat", "TUI made this")
        assert "first TUI save" in current, current
        e.omajot("write", "TUI made this", stdin=current.replace("# TUI made this\n", "# TUI made this\nCLI line\n", 1))
        open(go, "w").write("go")
        e.wait_screen(lambda s: "Saved and merged “TUI made this”" in status(s), "merged message", 20)
        final = e.omajot("cat", "TUI made this")
        for part in ("CLI line", "Written by the fake editor", "first TUI save", "second TUI save"):
            assert part in final, (part, final)
        ok("e while `omajot write` changes the note: both edits survive, 'Saved and merged'")

        # -------------------------------------------------- pin, trash, restore
        e.keys("p")
        e.wait_screen("Pinned “TUI made this”", "pin message")
        assert e.note("TUI made this")["pinned"]
        e.keys("x")
        e.wait_screen("Moved “TUI made this” to the Trash", "trash message")
        assert e.note("TUI made this")["trashed"]
        e.keys("h", "G", "l")
        e.wait_screen(lambda s: "Trash · 2" in rows(s)[0] and "TUI made this" in s, "the Trash lists it")
        e.keys("g", "x")
        e.wait_screen("Restored “TUI made this”", "restore message")
        assert not e.note("TUI made this")["trashed"]
        ok("p pins, x trashes, x in the Trash restores")

        # -------------------------------------------------- move to a folder
        e.keys("h", "g", "l", "/")
        e.text("TUI made this")
        e.keys("Enter")
        e.wait_screen(lambda s: "All notes · 1 " in rows(s)[0], "find the note")
        folders = folder_order(e.call("list")["folders"])
        idx = 1 + [f["name"] for f in folders].index("Travel")
        e.keys("m")
        e.wait_screen("Move “TUI made this” to", "move picker")
        e.keys(*["j"] * idx, "Enter")
        e.wait_screen("Moved “TUI made this” to Travel", "move message")
        travel = [f for f in folders if f["name"] == "Travel"][0]
        assert e.note("TUI made this")["folder"] == travel["id"]
        e.keys("Escape")
        ok("m moves the note to a folder (picker)")

        # -------------------------------------------------- folders
        e.keys("h", "g", "N")
        e.wait_screen("New folder", "folder prompt")
        e.text("Scratch folder")
        e.keys("Enter")
        e.wait_screen("Made the folder “Scratch folder”", "folder made")
        assert any(f["name"] == "Scratch folder" for f in e.call("list")["folders"])
        e.keys("r")
        e.wait_screen("Rename the folder", "rename prompt")
        e.keys("C-u")
        e.text("Renamed folder")
        e.keys("Enter")
        e.wait_screen("Renamed the folder to “Renamed folder”", "renamed")
        names = [f["name"] for f in e.call("list")["folders"]]
        assert "Renamed folder" in names and "Scratch folder" not in names, names
        ok("N makes a folder, r renames it")

        # -------------------------------------------------- delete a folder, not its notes
        target = next(f["id"] for f in e.call("list")["folders"] if f["name"] == "Renamed folder")
        parent = e.call("folder.create", name="Parent folder", parent=None)["folder"]
        e.call("folder.move", folder=target, parent=parent)
        child = e.call("folder.create", name="Child folder", parent=target)["folder"]
        grandchild = e.call("folder.create", name="Grandchild folder", parent=child)["folder"]
        direct = e.call("create", folder=target, text="Folder note\n\nKeep this text\n")["note"]
        trashed = e.call("create", folder=target, text="Trashed folder note\n\nKeep this too\n")["note"]
        e.call("set", note=trashed, trashed=True)
        nested = e.call("create", folder=child, text="Child note\n\nStill in its folder\n")["note"]
        before = e.call("list")
        texts = {n: e.call("read", note=n)["text"] for n in (direct, trashed, nested)}
        e.wait_screen("Child folder", "folder contents refreshed")
        e.keys("x")
        e.wait_screen("Delete folder?", "folder deletion asks first")
        assert "Parent folder/Renamed folder" in e.screen(), "confirmation names the selected folder"
        assert e.call("list") == before, "opening the confirmation changed data"
        e.tmux("resize-window", "-t", "tui", "-x", "60", "-y", "20")
        s = e.wait_screen(lambda s: "Delete folder?" in s and "No note is deleted." in s and
                          "Cancel" in s and all(cells(r) == 60 for r in rows(s)[:19]),
                          "folder confirmation fits a narrow terminal")
        # Even with Delete selected, shrinking below the dialog's usable size
        # must pause the action rather than permit an unseen confirmation.
        e.keys("Tab")
        e.tmux("resize-window", "-t", "tui", "-x", "20", "-y", "3")
        e.wait_screen("Resize to 40x11.", "small terminal pauses folder deletion")
        e.keys("Enter")
        e.wait_screen("Resize to 40x11.", "Enter cannot accept an unseen folder confirmation")
        assert e.call("list") == before, "small terminal allowed an unseen deletion"
        e.tmux("resize-window", "-t", "tui", "-x", str(W), "-y", str(H))
        e.wait_screen(lambda s: "Delete folder?" in s and cells(rows(s)[0]) == W, "confirmation back to full size")
        e.keys("Escape")
        e.wait_screen(lambda s: "Delete folder?" not in s, "Esc cancels folder deletion")
        e.keys("x", "Enter")
        e.wait_screen(lambda s: "Delete folder?" not in s, "Enter defaults to Cancel")
        assert e.call("list") == before, "cancelling changed data"

        # Refresh and reordering while the dialog is open must not change its target.
        e.keys("x")
        e.wait_screen("Delete folder?", "asks again")
        e.call("folder.rename", folder=target, name="Renamed elsewhere")
        extra = e.call("folder.create", name="AAA refresh", parent=None)["folder"]
        e.wait_screen("AAA refresh", "live refresh while the confirmation is open")
        assert "Parent folder/Renamed folder" in e.screen(), "confirmation lost its captured name"
        e.keys("Tab", "Enter")
        e.wait_screen("Deleted the folder", "Tab selects Delete, Enter confirms")
        assert "All notes · " in rows(e.screen())[0], "deletion left a stale folder view"
        after = e.call("list")
        folders = {f["id"]: f for f in after["folders"]}
        assert target not in folders and extra in folders
        assert folders[child]["parent"] == parent and folders[grandchild]["parent"] == child
        notes = {n["id"]: n for n in after["notes"]}
        for n in before["notes"]:
            expected = dict(n, folder=None) if n["folder"] == target else n
            assert notes[n["id"]] == expected, (notes[n["id"]], expected)
        for n, text in texts.items():
            assert e.call("read", note=n)["text"] == text
        wait_for(lambda: target not in {f["id"] for f in b.call("list")["folders"]} and
                 any(f["id"] == child and f["parent"] == parent for f in b.call("list")["folders"]),
                 "folder deletion syncs to device B")
        ok("x in sources: cancel by default; captured folder deleted, notes and descendants preserved, synced")

        # Built-in sources must never accidentally trash the selected note.
        before = e.call("list")
        e.keys("g", "x")
        assert e.call("list") == before, "x on All notes trashed a note"
        e.wait_screen("Select a folder", "built-in source explains how to delete a folder")

        # The mouse can cancel and confirm the same dialog, including an empty folder.
        e.keys("N")
        e.wait_screen("New folder", "empty folder prompt")
        e.text("Empty folder")
        e.keys("Enter")
        e.wait_screen("Made the folder “Empty folder”", "empty folder made")
        empty = next(f["id"] for f in e.call("list")["folders"] if f["name"] == "Empty folder")
        e.keys("x")
        s = e.wait_screen("Delete folder?", "empty folder confirmation")
        r, line = next((r, line) for r, line in enumerate(rows(s)) if "Cancel" in line and "Delete" in line)
        e.click(cells(line[:line.index("Cancel")]), r)
        e.wait_screen(lambda s: "Delete folder?" not in s, "mouse cancels")
        assert empty in {f["id"] for f in e.call("list")["folders"]}
        e.keys("x")
        s = e.wait_screen("Delete folder?", "empty folder asks again")
        r, line = next((r, line) for r, line in enumerate(rows(s)) if "Cancel" in line and "Delete" in line)
        e.click(cells(line[:line.index("Delete")]), r)
        e.wait_screen("Deleted the folder “Empty folder”", "mouse confirms deletion")
        assert empty not in {f["id"] for f in e.call("list")["folders"]}
        ok("x on built-in sources changes nothing; mouse cancels and deletes an empty folder")

        # If another device deletes the target, confirmation must not delete
        # whichever source now occupies its row, or report a false success.
        e.keys("N")
        e.wait_screen("New folder", "stale target prompt")
        e.text("Gone elsewhere")
        e.keys("Enter")
        e.wait_screen("Made the folder “Gone elsewhere”", "stale target made")
        gone = next(f["id"] for f in e.call("list")["folders"] if f["name"] == "Gone elsewhere")
        e.keys("x")
        e.wait_screen("Delete folder?", "stale target confirmation")
        e.call("folder.delete", folder=gone)
        e.call("folder.create", name="Another refresh", parent=None)
        e.wait_screen("Another refresh", "target deleted during live refresh")
        before = e.call("list")
        e.keys("y")
        e.wait_screen("unknown folder", "stale target refusal")
        assert e.call("list") == before, "stale confirmation deleted another folder or note"
        assert "Deleted the folder" not in status(e.screen()), "false deletion success"
        ok("y on a remotely deleted target reports the refusal without changing another source")

        # A legal folder path can exceed libvaxis's u16 display-width range.
        # Only the displayed suffix may be shortened, never the deletion ID.
        long_parent = e.call("folder.create", name="🌱" * 32770, parent=None)["folder"]
        long_target = e.call("folder.create", name="Display tail 🌱", parent=long_parent)["folder"]
        folders = folder_order(e.call("list")["folders"])
        idx = [f["id"] for f in folders].index(long_target)
        e.keys("g", *["j"] * (3 + idx), "x")
        s = e.wait_screen(lambda s: "Delete folder?" in s and "Display tail 🌱" in s,
                          "oversized folder path shows a valid display suffix")
        assert "…" in s, "long path has no truncation indicator"
        e.keys("y")
        s = e.wait_screen("Deleted the folder", "oversized path confirms without a panic")
        assert "Deleted the folder" in status(s), "wide deletion status scrolled the screen"
        assert rows(s)[0].startswith("╭") and all(cells(r) == W for r in rows(s)[:H - 1]), \
            "wide deletion status corrupted the layout"
        ids = {f["id"] for f in e.call("list")["folders"]}
        assert long_target not in ids and long_parent in ids, "truncated path changed the deletion target"
        ok("an oversized Unicode folder path displays a suffix and deletes only the captured ID")

        # -------------------------------------------------- live refresh
        e.keys("g", "l")
        e.omajot("new", "From the CLI", "made while the TUI runs")
        e.wait_screen("From the CLI", "a CLI note shows up without a key")
        b.call("create", folder=None, text="# From device B\n\nsynced through the hub\n")
        e.wait_screen("From device B", "a note from another device shows up", 30)
        ok("live refresh: a CLI note and a note from device B appear")

        # -------------------------------------------------- help overlay
        e.keys("?")
        e.wait_screen("move down / up", "help overlay")
        e.keys("Escape")
        e.wait_screen(lambda s: "move down / up" not in s, "help closes")
        ok("? shows the keys")

        # -------------------------------------------------- mouse
        assert e.tmux("display", "-p", "-t", "tui", "#{mouse_any_flag}").strip() == "1", "mouse mode is not on"
        e.keys("g")
        s = e.wait_screen(lambda s: preview_title(s) == card_title(s, 0), "first note")
        third, fourth = card_title(s, 2), card_title(s, 3)
        e.click(40, 1 + 3 * 2)  # the title row of the third card
        s = e.wait_screen(lambda s: preview_title(s) == third, f"a click selects {third!r}")
        e.wheel(40, 10, down=True)
        e.wait_screen(lambda s: preview_title(s) == fourth, "the wheel moves to the next note")
        e.click(6, 2)  # "Pinned" in the sources column
        e.wait_screen(lambda s: "Pinned · " in rows(s)[0], "a click selects Pinned")
        e.click(6, 1)
        e.wait_screen(lambda s: "All notes · " in rows(s)[0], "a click selects All notes")
        # A checkbox in the preview: the Welcome note's first open one.
        e.keys("/")
        e.text("QR code")
        e.keys("Enter")
        s = e.wait_screen(lambda s: preview_title(s).startswith("Welcome"), "search finds the Welcome note")
        before = e.omajot("cat", "Welcome to omajot 👋").count("- [x]")
        box = next((r, line) for r, line in enumerate(rows(s)) if r >= 3 and "\uf096" in line[74:])
        e.click(cells(box[1][:box[1].index("\uf096", 74)]), box[0])
        wait_for(lambda: e.omajot("cat", "Welcome to omajot 👋").count("- [x]") == before + 1, "the click ticks the box", 10)
        e.keys("Escape")
        # Two clicks on a card open the note in the editor.
        json.dump({"mode": "append", "text": "Opened with a double click\n"}, open(e.plan, "w"))
        e.keys("g")
        s = e.wait_screen(lambda s: preview_title(s) == card_title(s, 0), "first note again")
        name = card_title(s, 0)
        e.click(40, 1, pause=0.05)
        e.click(40, 1)
        e.wait_screen(lambda s: "Saved" in status(s), "a double click edits the note")
        ok("mouse: click selects notes and sources, the wheel moves, a click ticks a box, a double click edits")

        # -------------------------------------------------- links: web at once, local files after a confirmation
        doc = os.path.join(tmp, "doc folder", "notes.txt")
        os.makedirs(os.path.dirname(doc))
        open(doc, "w").write("x")
        prog = os.path.join(tmp, "prog.sh")
        open(prog, "w").write("#!/bin/sh\n")
        os.chmod(prog, 0o755)
        link_note = ("Links test\n\nhttps://example.com/omajot-e2e\n\n[LINKDOC](file://" + doc.replace(" ", "%20") + ")\n\n"
                     "[LINKPROG](file://" + prog + ")\n\n[LINKGONE](file:///nope/not-here.txt)\n")
        e.omajot("write", "Links test", stdin=link_note)
        e.keys("/")
        e.text("LINKDOC")
        e.keys("Enter")
        s = e.wait_screen(lambda s: preview_title(s) == "Links test", "the links note")

        def click_text(label):
            scr = e.screen()
            r, line = next((r, line) for r, line in enumerate(rows(scr)) if r >= 3 and label in line[74:])
            e.click(cells(line[:line.index(label, 74)]) + 1, r)

        click_text("example.com/omajot-e2e")
        wait_for(lambda: os.path.exists(e.opened) and "https://example.com/omajot-e2e" in open(e.opened).read(), "a web link opens", 10)
        click_text("LINKDOC")
        e.wait_screen("Open a file from the note?", "a file link asks first")
        assert "notes.txt" in e.screen() and doc not in open(e.opened).read(), "opened before the confirmation"
        e.keys("Escape")
        e.wait_screen(lambda s: "Open a file from the note?" not in s, "Esc cancels")
        assert doc not in open(e.opened).read(), "opened after Esc"
        click_text("LINKDOC")
        e.wait_screen("Open a file from the note?", "asks again")
        e.keys("Enter")
        wait_for(lambda: doc in open(e.opened).read(), "Enter opens the file (decoded path)", 10)
        click_text("LINKPROG")
        e.wait_screen(lambda s: "is a program" in status(s), "a program is not opened")
        click_text("LINKGONE")
        e.wait_screen(lambda s: "Not on this computer" in status(s), "a missing file says so")
        assert prog not in open(e.opened).read()
        e.keys("Escape", "h")  # clear the search; the clicks gave the preview the focus
        ok("links: a web link opens, a file link after a confirmation, programs and missing files do not")

        # -------------------------------------------------- the daemon goes away and comes back
        daemon_args = [e.bin, "daemon", "--background", "--data", e.data, "--socket", e.sock, "--hub", hub_url]
        procs[1].terminate()
        procs[1].wait(timeout=10)
        e.wait_screen(lambda s: "No daemon" in status(s), "status shows the lost daemon")
        procs[1] = subprocess.Popen(daemon_args, env=e.env, stdout=subprocess.DEVNULL,
                                    stderr=open(os.path.join(tmp, "daemon2.stderr"), "w"))
        e.wait_screen(lambda s: "Synced" in status(s), "reconnects to the new daemon", 20)
        e.omajot("new", "After the restart", "the TUI listens again")
        e.wait_screen("After the restart", "events flow after the reconnect")
        ok("daemon stops: status says so; a new daemon: reconnects, live again")

        # -------------------------------------------------- resize
        for w, h, want, not_want in ((100, 40, " preview ", "FOLDERS"), (60, 20, "All notes · ", " preview "),
                                     (W, H, "FOLDERS", None)):
            e.tmux("resize-window", "-t", "tui", "-x", str(w), "-y", str(h))
            s = e.wait_screen(lambda s: want in s and (not_want is None or not_want not in s) and
                              len(rows(s)) >= h and all(cells(r) == w for r in rows(s)[:h - 1]),
                              f"layout at {w}x{h}")  # every row redrawn, not just the first
            for i, line in enumerate(rows(s)[:h - 1]):
                assert cells(line) == w, f"{w}x{h} row {i}: {cells(line)} cells: {line!r}"
        ok("resize 160 -> 100 -> 60 -> 160: 3, 2, 1, 3 columns, rows fit")

        # -------------------------------------------------- quit
        e.keys("q")
        e.wait_screen("EXIT=0", "q exits 0")
        assert e.stty_same("tui"), "stty differs after q"
        assert e.tmux("display", "-p", "-t", "tui", "#{mouse_any_flag}").strip() == "0", "mouse mode left on after q"
        assert open(os.path.join(tmp, "tui.stderr")).read() == "", "stderr not empty"
        ok("q exits 0, terminal settings and mouse mode restored, nothing on stderr")

        # -------------------------------------------------- panic and SIGTERM
        e.start("panic", extra_env="export OMAJOT_TUI_PANIC_KEY=1")
        e.wait_screen(lambda s: "All notes · " in s, "panic session up", name="panic")
        e.keys("!", name="panic")
        e.wait_screen(lambda s: "EXIT=" in s and "EXIT=0" not in s, "panic exits", name="panic")
        assert e.stty_same("panic"), "stty differs after a panic"
        assert e.tmux("display", "-p", "-t", "panic", "#{mouse_any_flag}").strip() == "0", "mouse mode left on (panic)"
        ok("a panic gives the terminal back")

        e.start("mono", extra_env="export NO_COLOR=1")
        e.wait_screen(lambda s: "All notes · " in s, "NO_COLOR session up", name="mono")
        ansi = e.tmux("capture-pane", "-p", "-e", "-t", "mono")
        assert "38;2;" not in ansi and "48;2;" not in ansi, "RGB colours despite NO_COLOR"
        assert "\x1b[7m" in ansi or ";7m" in ansi or ";7;" in ansi, "no reverse video for the selection"
        e.keys("q", name="mono")
        e.wait_screen("EXIT=0", "NO_COLOR session quits", name="mono")
        ok("NO_COLOR: no RGB colours, the selection in reverse video")

        e.start("term", background=True)
        e.wait_screen(lambda s: "All notes · " in s, "term session up", name="term")
        pid = int(open(os.path.join(tmp, "term.pid")).read())
        os.kill(pid, 15)
        e.wait_screen("EXIT=143", "SIGTERM exits 143", name="term")
        assert e.stty_same("term"), "stty differs after SIGTERM"
        assert e.tmux("display", "-p", "-t", "term", "#{mouse_any_flag}").strip() == "0", "mouse mode left on (term)"
        ok("SIGTERM gives the terminal back")

        kitty_pictures(e)
        ok("with Kitty graphics, the picture of a note is sent and placed")
        print("all TUI checks passed")
    finally:
        subprocess.run(["tmux", "-L", e.tmux_name, "kill-server"], capture_output=True, env=e.env)
        if b:
            b.close()
        for p in reversed(procs):
            p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                p.kill()
        if args.keep:
            print(f"kept {tmp}")
        else:
            shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
