#!/usr/bin/env python3
"""End-to-end sync check: two `omajot daemon`s with separate data dirs sync
through a hub. Drives the daemons over stdin/stdout (docs/PROTOCOL.md §1).

    tools/e2e_sync.py --hub https://host.tail.ts.net:8443 [--bin zig-out/bin/omajot]
    tools/e2e_sync.py --local            # starts its own hub on loopback (--no-auth)

With --local it also runs an offline/online cycle: the hub is stopped, both
daemons edit the same note, the hub comes back, and both must converge.
"""
import argparse, json, os, queue, shutil, subprocess, sys, tempfile, threading, time

class Daemon:
    def __init__(self, name, binary, hub, data):
        self.name = name
        args = [binary, "daemon", "--data", data] + (["--hub", hub] if hub else ["--no-hub"])
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(os.path.join(data, "..", f"{name}.stderr"), "w"),
                                     text=True, bufsize=1)
        self.lines = queue.Queue()
        self.events = []
        self.next_id = 1
        self.seq = {}      # note -> last edit seq sent
        self.pseq = {}     # note -> last patch applied
        self.text = {}     # note -> local text (patches applied)
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            line = line.strip()
            if not line:
                continue
            msg = json.loads(line)
            if "ev" in msg:
                self.events.append(msg)
                if msg["ev"] == "patch" and msg["note"] in self.text:
                    self._apply_patch(msg)
            self.lines.put(msg)

    def _apply_patch(self, p):
        # This client never has unacknowledged edits when patches arrive in
        # the test (it waits for replies), so plain application is exact.
        t = self.text[p["note"]]
        self.text[p["note"]] = t[:p["pos"]] + p["ins"] + t[p["pos"] + p["del"]:]
        self.pseq[p["note"]] = p["pseq"]

    def call(self, cmd, timeout=15, **fields):
        rid = self.next_id
        self.next_id += 1
        self.proc.stdin.write(json.dumps({"id": rid, "cmd": cmd, **fields}) + "\n")
        self.proc.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg = self.lines.get(timeout=deadline - time.time())
            except queue.Empty:
                break
            if msg.get("re") == rid:
                if not msg.get("ok"):
                    raise RuntimeError(f"{self.name} {cmd}: {msg}")
                return msg
        raise TimeoutError(f"{self.name}: no reply to {cmd}")

    def open(self, note):
        r = self.call("open", note=note)
        self.text[note] = r["text"]
        self.seq[note] = r["seq"]
        self.pseq[note] = r.get("pseq", 0)
        return r

    def edit(self, note, pos, delete, ins):
        self.seq[note] += 1
        self.call("edit", note=note, seq=self.seq[note], ack=self.pseq[note], pos=pos, **{"del": delete}, ins=ins)
        t = self.text[note]
        self.text[note] = t[:pos] + ins + t[pos + delete:]

    def wait_for(self, predicate, what, timeout=20):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate():
                return
            time.sleep(0.1)
        raise TimeoutError(f"{self.name}: timed out waiting for {what}")

    def sync_state(self):
        states = [e for e in self.events if e.get("ev") == "sync"]
        return states[-1] if states else None

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=5)


def start_hub(binary, port, data):
    hub = subprocess.Popen([binary, "hub", "--port", str(port), "--data", data, "--no-auth", "--timeout-ms", "8000"],
                           stdout=subprocess.DEVNULL, stderr=open(os.path.join(data, "..", "hub.stderr"), "a"))
    time.sleep(0.8)
    return hub


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hub")
    ap.add_argument("--local", action="store_true")
    ap.add_argument("--bin", default=os.path.join(os.path.dirname(__file__), "..", "zig-out", "bin", "omajot"))
    ap.add_argument("--keep", action="store_true")
    a = ap.parse_args()
    root = tempfile.mkdtemp(prefix="omajot-e2e-")
    hub_proc = None
    port = 18789
    hub_url = a.hub
    if a.local:
        os.makedirs(os.path.join(root, "hub"))
        hub_proc = start_hub(a.bin, port, os.path.join(root, "hub"))
        hub_url = f"http://127.0.0.1:{port}"
    assert hub_url, "--hub or --local"
    for n in ("a", "b"):
        os.makedirs(os.path.join(root, n))
    A = Daemon("A", a.bin, hub_url, os.path.join(root, "a"))
    B = Daemon("B", a.bin, hub_url, os.path.join(root, "b"))
    t0 = time.time()
    try:
        ha, hb = A.call("hello", client="qml"), B.call("hello", client="qml")
        assert ha["replica"] != hb["replica"], "replicas must differ"
        print(f"hello A={ha['replica']} B={hb['replica']} data={ha.get('attachments')}")

        # 1. A creates a note; B sees it and opens it.
        note = A.call("create", folder=None, text="Shopping\n")["note"]
        A.open(note)
        A.edit(note, len(A.text[note]), 0, "- milk\n")
        B.wait_for(lambda: any(n["id"] == note for n in B.call("list")["notes"]), "note on B")
        B.open(note)
        B.wait_for(lambda: B.text[note] == A.text[note], "B text == A text")
        print(f"[{time.time()-t0:5.1f}s] B sees A's note: {B.text[note]!r}")

        # 2. Live: B edits, A (note open) receives a patch.
        B.edit(note, len(B.text[note]), 0, "- eggs\n")
        A.wait_for(lambda: A.text[note] == B.text[note], "patch on A")
        print(f"[{time.time()-t0:5.1f}s] live patch to A: {A.text[note]!r}")

        if a.local:
            # 3. Offline: stop the hub, edit both sides concurrently.
            hub_proc.terminate(); hub_proc.wait()
            A.edit(note, len("Shopping\n"), 0, "- bread (A offline)\n")
            B.edit(note, len(B.text[note]), 0, "- butter (B offline)\n")
            time.sleep(1.5)
            sa, sb = A.call("status"), B.call("status")
            print(f"[{time.time()-t0:5.1f}s] offline: A {sa['sync']} pending={sa['pending']}, B {sb['sync']} pending={sb['pending']}")
            assert sa["pending"] > 0 and sb["pending"] > 0
            hub_proc = start_hub(a.bin, port, os.path.join(root, "hub"))
            A.wait_for(lambda: A.call("status")["pending"] == 0, "A flushed", 60)
            B.wait_for(lambda: B.call("status")["pending"] == 0, "B flushed", 60)
            A.wait_for(lambda: A.text[note] == B.text[note] and "bread" in A.text[note] and "butter" in A.text[note], "convergence", 60)
            # The engine's own view must match the patched client text.
            ra, rb = A.call("open", note=note)["text"], B.call("open", note=note)["text"]
            assert ra == rb == A.text[note], (ra, rb, A.text[note])
            print(f"[{time.time()-t0:5.1f}s] converged after offline edits: {ra!r}")

            # 4. Restart a daemon: state comes back from disk.
            A.close()
            A = Daemon("A2", a.bin, hub_url, os.path.join(root, "a"))
            A.call("hello", client="qml")
            assert A.call("open", note=note)["text"] == rb
            print(f"[{time.time()-t0:5.1f}s] A restarted from disk with identical text")
        else:
            # 3'. Offline daemon: B restarts against an unreachable hub, both
            # sides edit the same note, then B comes back online.
            B.close()
            B = Daemon("B-offline", a.bin, "http://127.0.0.1:9", os.path.join(root, "b"))
            B.call("hello", client="qml")
            B.open(note)
            B.edit(note, 0, 0, "(B offline) ")
            A.edit(note, len(A.text[note]), 0, "- cheese (A online)\n")
            time.sleep(2)
            sb = B.call("status")
            print(f"[{time.time()-t0:5.1f}s] B offline: {sb['sync']} pending={sb['pending']}")
            assert sb["pending"] > 0
            B.close()
            B = Daemon("B-back", a.bin, hub_url, os.path.join(root, "b"))
            B.call("hello", client="qml")
            B.open(note)
            A.wait_for(lambda: "(B offline)" in A.text[note], "B's offline edit on A", 60)
            B.wait_for(lambda: "cheese" in B.text[note], "A's edit on B", 60)
            ra, rb = A.call("open", note=note)["text"], B.call("open", note=note)["text"]
            assert ra == rb == A.text[note] == B.text[note], (ra, rb)
            print(f"[{time.time()-t0:5.1f}s] converged after B's offline period: {ra!r}")
        print("E2E PASS")
    finally:
        for d in (A, B):
            try:
                d.close()
            except Exception:
                d.proc.kill()
        if hub_proc:
            hub_proc.terminate()
        if not a.keep:
            shutil.rmtree(root, ignore_errors=True)
        else:
            print("kept", root)


if __name__ == "__main__":
    main()
