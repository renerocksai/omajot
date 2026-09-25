# Spike: omajot TUI on libvaxis (Zig 0.16)

Date: 2026-09-26. A standalone prototype that reads `examples/sample-notes/`
directly (no daemon) and shows the plugin's layout: folders + tags │ note list │
rendered preview, plus a status bar. Run: `cd spikes/tui && zig build run`
(or `-- /path/to/notes`); `zig build test` runs 4 tests.

**Verdict:** libvaxis works well on Zig 0.16 and fits. Its basic API (`Vaxis`,
`Loop`, `Window.child`/`print`) is enough for the three-column layout, and the
terminal is always restored, even after a panic. A few rough edges on 0.16 have
one-line workarounds (below).

## Verified (detached tmux 3.7c, 160×45)

| Check | Result | Capture |
|---|---|---|
| Three columns, rounded borders, titles in the border, focus in the accent colour | ok | `01-start` |
| Colours from the Omarchy theme (`~/.local/state/omarchy/current/theme/colors.toml`), built-in palette otherwise | ok, RGB values match | `01-start.ansi` |
| Nerd Font icons as in the plugin's `Model.mjs` | ok | `01-start` |
| Every row exactly 160 cells, borders aligned, checked by script | ok with 👋 🇩🇪 umlauts ß 日本語 | `16-unicode` |
| Markdown: H1–H3, bold/italic/strike, code spans, fenced code with a language label, nested lists, task boxes, links as OSC 8 hyperlinks, tables (with formatting in cells), quotes, rules, #tag chips | ok | `03-mdtour`, `04-scrolled` |
| Preview scrolling (`d`/`u`), clean clipping under the meta line | ok | `04-scrolled` |
| Picture via the Kitty graphics protocol, else a placeholder line | placeholder ok; real pictures untested (tmux shows none) | `02-lisbon` |
| `/` search: live filter, Backspace, Enter keeps, Esc clears | ok | `06-search-kept` |
| Resize 160→100→60→160: 3/2/1 columns, `h`/`l` switch column, hints drop when they do not fit | ok | `08`–`10` |
| `q` exits 0; a test panic; `stty -a` identical before and after both | ok | |

## Editor handoff

`e`/Enter writes the note to `$XDG_RUNTIME_DIR/omajot-<slug>.md` and runs
`sh -c '<editor> "$1"' omajot <file>`, with the editor from `$VISUAL`, then
`$EDITOR`, then `vi`. The TUI stops input, resets terminal modes, restores the
original termios, runs the editor, then goes back to raw mode and the alt screen,
re-enables detected features, resizes, redraws completely and restarts input.

| Case | Result |
|---|---|
| `EDITOR="append.sh --tag spike"` | argument arrives intact; the editor gets a normal terminal; "Saved: 352 bytes, 2 new lines"; preview and tags update |
| `VISUAL` and `EDITOR` both set | `VISUAL` wins |
| `EDITOR="/nonexistent/editor --wait"` | "Cannot run the editor "…". Set $VISUAL or $EDITOR." (exit 126/127) |
| neither set | falls back to `vi` |
| editor exits unchanged / with an error | "No changes." / "…exited with status N; the note is unchanged." |
| resize after an editor round trip | redraws correctly |

## libvaxis on Zig 0.16: findings

- **Version:** no `v0.6.0` tag yet (latest tag v0.5.1 targets older Zig). Pinned
  main `173a890d`, whose `build.zig.zon` says 0.6.0 and requires Zig 0.16.0.
  Depends on zigimg (images) and uucode (Unicode tables).
- **`vaxis.Panic` does not compile on 0.16** (old three-argument handler). Use
  our own `std.debug.FullPanic(...)` that calls `vaxis.recover()` and then
  `std.debug.defaultPanic`. Worth an upstream PR.
- **Debug builds crash the Zig 0.16 x86_64 backend** on libvaxis; `.use_llvm = true`
  fixes it (libvaxis' own build defaults to LLVM too).
- **`Loop.start()` does not install the SIGWINCH handler.** Call
  `loop.installResizeHandler()`, or resizes only arrive from terminals with
  in-band resize reports (mode 2048) — tmux has none.
- **`print` borrows the text until the next render.** Text formatted into a
  temporary buffer shows as garbage; the real TUI needs a per-frame arena.
- **Grapheme widths depend on the terminal:** without mode 2027, 👨‍👩‍👧 counts
  as 6 cells in vaxis but 2 in tmux (that row's border shifts by 4). Flags, plain
  emoji, CJK and umlauts are fine.
- **Small annoyances:** mixed integer types for offsets and sizes (many casts); no
  built-in scroll view (the preview renders twice: measure, then draw offset);
  key matching is pleasant; the vxfw widget framework was not needed.
- **Images:** Kitty graphics protocol only (no sixel); `loadImage` decodes with
  zigimg; over ssh the image data goes through the terminal stream, slow for big
  images. Needs a test in a real Ghostty or kitty.

## Size (x86_64-linux, the whole spike)

| Build | Size |
|---|---|
| ReleaseSafe | 7.2 MB, 1.4 MB stripped |
| ReleaseSmall | 0.87 MB |
| Debug | 10 MB |

Adding it to `omajot` should cost about 1–1.5 MB stripped.

## What we build ourselves

The markdown renderer (`md.zig`, 370 lines, line-based, not full CommonMark), the
layout and focus model, list scrolling/virtualisation, the search box and status
bar, the editor handoff, the theme reader. Folder create/rename needs a text-input
widget (vxfw's `TextField`).

## What the real TUI needs from the CLI/socket API

1. Sources in one call: folders (id, name, parent, counts), tags with counts, and
   counts for all, pinned, unfiled and trash.
2. A note list of summaries (id, title, markdown-free snippet, folder, tags,
   pinned, trashed, updated), filtered by source and query, pinned first then
   newest, so the TUI never loads bodies it does not show.
3. Read one note's text with its version or hash.
4. Save after the external editor as "base version + new text" (or a diff),
   merged by the daemon if the note changed meanwhile: no lock while `$EDITOR` is open.
5. Full-text search in the daemon (the spike only folds ASCII case).
6. Change events (notes changed/added/removed; sync state) to refresh live.
7. Local file paths of attachments, so pictures load from disk.
8. Sync status for the status bar: synced, syncing, offline or conflict, and the last sync time.
9. The plugin's actions: pin, move to folder, trash and restore, new note.

## Files

- `build.zig`, `build.zig.zon`: libvaxis pinned by tarball URL + hash; LLVM backend.
- `src/main.zig`: app state, keys, layout, status bar, editor handoff, panic handler.
- `src/md.zig`: markdown renderer.
- `src/notes.zig`: sample-notes loader, sources, list, filter.
- `src/theme.zig`: Omarchy `colors.toml` reader with a built-in fallback.
- `captures/`: 11 tmux captures, plain text and ANSI.
