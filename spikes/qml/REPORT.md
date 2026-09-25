# Spike 0c — QML TextArea as the editor

Date: 2026-09-25, Quickshell 0.3.1 (standalone `qs -p spikes/qml/shell.qml`,
not inside omarchy-shell; the plugin host is the same Qt/Quickshell),
Qt 6.11.2. Driven with `wtype` and `hyprctl` key dispatch; results from `console.log`.

| Question | Result |
|---|---|
| Load a 200 KB note into `TextArea` | 169 ms (once per note open) |
| Cost of reading `.text` | 0.02 ms (cached, not re-serialised) |
| Prefix/suffix diff per keystroke on 200 KB | **~7 ms** worst case. OK; can drop to O(edit) by starting the scan at `cursorPosition` |
| Diff output while typing | One clean `{pos, del:0, ins:"x"}` per key, including `ü`, `ß`, emoji |
| Position units | **UTF-16**: an emoji advances the position by 2 |
| Remote `insert()` / `remove()` before the cursor | Cursor **and selection** shift correctly (150000→150011→150009) |
| Remote insert after the cursor | Cursor stays put |
| Spurious `textChanged` | One empty diff after load/focus: ignore empty ops |
| **Built-in undo** | **Broken for us**: after typing, the 1st Ctrl+Z undid all typing at once, and the **2nd to 4th undid the remote patches**, which then came out as local edits |
| Intercept Ctrl+Z / Ctrl+Y | `Keys.onPressed` with `event.accepted = true` stops the built-in undo (verified) |
| Markdown preview, relative image | Works with `baseUrl`, which **must end with `/`** (otherwise it resolves one directory up); a missing image is retried on every relayout and floods the log |
| Task lists in preview | `- [x]` / `- [ ]` render as ☒ / ☐ |
| Image layout | Cosmetic: the image slightly overlaps the next block; revisit (explicit size or spacing) |

## Consequences for the design

- **Undo/redo is omajot's own**: intercept Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y, and undo
  only this device's ops (inverse local ops through the CRDT). This is the standard
  answer for collaborative editors anyway. Check whether Qt 6.11's `TextArea`
  context menu offers Undo, and replace or remove it.
- Guard remote patches with an `applyingRemote` flag so they aren't echoed back as local ops.
- Coalesce local ops (e.g. every 300 ms or at word boundaries) before sending to the daemon.
- Still unverified: behaviour inside omarchy-shell's plugin host (expected to be
  identical) and IME / dead-key input.
