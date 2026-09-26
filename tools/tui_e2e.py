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
survive), pin, Trash and restore, move to a folder, new and renamed folder,
live refresh (a CLI note, a note from device B), the help overlay, resize,
and that `q`, a panic and SIGTERM all give the terminal back (`stty -a`).

--capture FILE writes the first screen at 110x30 (sample notes only) as plain
text, for the docs (site/assets/tui-terminal.txt).
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
                              len(rows(s)) >= h and cells(rows(s)[0]) == w, f"layout at {w}x{h}")
            for i, line in enumerate(rows(s)[:h - 1]):
                assert cells(line) == w, f"{w}x{h} row {i}: {cells(line)} cells"
        ok("resize 160 -> 100 -> 60 -> 160: 3, 2, 1, 3 columns, rows fit")

        # -------------------------------------------------- quit
        e.keys("q")
        e.wait_screen("EXIT=0", "q exits 0")
        assert e.stty_same("tui"), "stty differs after q"
        assert open(os.path.join(tmp, "tui.stderr")).read() == "", "stderr not empty"
        ok("q exits 0, terminal settings unchanged, nothing on stderr")

        # -------------------------------------------------- panic and SIGTERM
        e.start("panic", extra_env="export OMAJOT_TUI_PANIC_KEY=1")
        e.wait_screen(lambda s: "All notes · " in s, "panic session up", name="panic")
        e.keys("!", name="panic")
        e.wait_screen(lambda s: "EXIT=" in s and "EXIT=0" not in s, "panic exits", name="panic")
        assert e.stty_same("panic"), "stty differs after a panic"
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
