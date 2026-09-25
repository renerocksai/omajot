---
name: omajot
description: Read, search, write and organize the user's omajot notes (Markdown notes synced between Omarchy, the web app and phones) with the `omajot` command line. Use it when the user asks about their notes, to take notes, to update a to-do list, or to find, move, restore or export notes.
---

# omajot notes from the command line

omajot is the user's note app: Markdown notes in folders, synced between their
computers (Omarchy plugin), the web app and phones through a hub they run. Every
note is plain Markdown. Its **title is its first line** (`# Title` or `Title`).
`#word` in the text is a tag. Deleted notes go to a Trash and can come back.

You use the `omajot` binary. Each command talks to the omajot daemon on this
computer and starts one in the background when none runs. Changes that you make
sync to the user's other devices within seconds, like their own typing.

## Rules

1. **Use `--json`** for everything that you parse. Human output can change.
2. **Read before you change.** `omajot cat <note>` shows the current text.
3. **Prefer small changes**: `append` to add, `replace` to change a part. They
   merge with edits that the user makes at the same time. `write` replaces the
   whole text: use it only for a note that you made, or when the user asks you
   to rewrite a note, and give it the full text (read it first).
4. **Never delete text that you did not read.** `rm` only moves a note to the
   Trash; `omajot rm <note> --restore` brings it back.
5. **Undo** with `omajot history <note>` and `omajot restore <note> <version>`.
   A restore is a normal change, so it can be undone too.
6. **Do not touch the data directory** (`~/.local/share/omajot`) or run
   `omajot daemon` yourself. Use the commands only.
7. **Ambiguous names**: exit code 2 lists the candidates with ids. Ask the user
   which one, or use the id (`n-…`) from the output.
8. Do not add markers such as "edited by AI" to notes unless the user asks.

## Addressing notes and folders

- `Folder/Subfolder/Title`: the full path. `Title` alone works when only one
  note has that title.
- `n-<hex16>-<number>`: the exact id, from `--json` output. Ids never change;
  titles and folders can. Use ids in scripts and after a lookup.
- Lookup order: id, exact path, exact title, then both without case. Notes in
  the Trash match only when no other note matches.
- Folders: `Work/Meetings`, or an id `f-…`. `/` is the top level (for `mv`).

## Commands

| Command | Does |
|---|---|
| `omajot ls [folder] [-r] [-l] [--tag <t>] [--trash]` | List folders and notes in a folder (`-r`: all below it, as paths; `--tag`, `--trash` include subfolders) |
| `omajot cat <note> [--at <time>]` | The text, exactly as stored; `--at`: as it was at a time |
| `omajot search <text> [--trash]` | Notes whose title or text contains the text (case ignored). Exit 1: no match |
| `omajot new <title> [text\|-] [--folder <f>]` | Make a note `# <title>\n\n<text>`; makes missing folders |
| `omajot write <note> [--folder <f>]` | stdin becomes the full text; makes the note if missing (folder from the path or `--folder`; adds `# <title>` when the text does not start with it) |
| `omajot append <note> <text\|->` | Add text at the end, on a new line |
| `omajot replace <note> <old> <new> [--all]` | Replace text that occurs exactly once (exit 1: not found, exit 2: more than once, nothing changed) |
| `omajot edit <note>` | Open in `$VISUAL`/`$EDITOR` (for people; do not use it) |
| `omajot mv <note> <folder>` | Move a note (`/`: top level). The folder must exist |
| `omajot rm <note> [--restore]` | Move to the Trash, or back |
| `omajot mkdir <path>` | Make a folder and missing parents (no error if it exists) |
| `omajot rmdir <folder> [--force]` | Delete an empty folder (exit 3 if not empty; `--force` moves its notes to the top level) |
| `omajot tags` | Tags of all notes not in the Trash, with counts |
| `omajot history <note>` | Versions, oldest first (changes of one device less than a minute apart) |
| `omajot restore <note> <version\|time>` | Make an earlier text current (as a normal, undoable change) |
| `omajot export <dir> [--trash] [--force]` | Every note as `<dir>/Folder/Title.md`, attachments in `<dir>/attachments/`, a README |
| `omajot status` | Daemon, data directory, socket, hub, sync state |

Times (`cat --at`, `restore`): `2026-09-26 14:03` (local), `2026-09-26T12:03Z`
(UTC), `2026-09-26`, Unix milliseconds, or a time ago: `90s`, `15m`, `2h`, `3d`, `1w`.

Options for all commands: `--json`; `--data <dir>` and `--socket <path>` (only
when the user uses a non-default setup); `--no-start` (fail with 69 instead of
starting a daemon). `omajot <command> --help` has the details and examples.

## Examples

```sh
# What notes are there?
omajot ls -r --json | jq -r '.notes[] | "\(.id)  \(.path)"'

# Find and read
omajot search "dentist" --json | jq -r '.notes[].path'
omajot cat "Home/Appointments"

# Add to a list, tick a box
omajot append Home/Groceries "- oat milk"
omajot replace Home/Todo "- [ ] call the dentist" "- [x] call the dentist"

# A new note from generated text (stdin)
printf 'Summary of the meeting …\n' | omajot new "Meeting 2026-09-26" - --folder Work/Meetings

# Rewrite a note that you made, with its full new text
omajot write "Work/Status report" < report.md

# Undo
omajot history Home/Todo --json
omajot restore Home/Todo 4
```

## JSON output

Success: one object with `"ok": true`. Failure: `{"ok": false, "exit": <code>,
"error": "<text>"}`; for exit 2 of an ambiguous name also
`"candidates": [{"id", "path", "trashed"}]`. Times are Unix milliseconds.

```
Note    = {"id":"n-…","title":"Todo","path":"Home/Todo","folder":"f-…"|null,
           "tags":["home"],"pinned":false,"trashed":false,
           "created":1790000000000,"updated":1790000100000,"snippet":"- milk …"}

ls      → {"ok":true,"folder":{"id","path"}|null,"folders":[{"id","name","path"}],"notes":[Note]}
search  → {"ok":true,"notes":[Note]}
cat     → {"ok":true,"id","path","text","at":ms|null}
new, write, append, mv, rm
        → {"ok":true,"id","path","changed":bool,"action":"created"|"updated"|"appended"|"moved"|"trashed"|"untrashed"}
replace → {"ok":true,"id","path","changed","action":"replaced","count":n}
edit    → {"ok":true,"id","path","changed","saves":n,"merged":bool}
mkdir, rmdir
        → {"ok":true,"id","path","changed"}
tags    → {"ok":true,"tags":[{"tag":"todo","count":3}]}
history → {"ok":true,"id","path","versions":[{"n":1,"t_first","t_last","time":"2026-09-26T12:03:05Z",
           "replica":"<hex16>","self":bool,"inserted":n,"deleted":n,"created":bool,"other":n}]}
restore → {"ok":true,"id","path","changed","at":ms}
export  → {"ok":true,"dir","notes":n,"attachments":n,"missing":["<name>"],"files":[{"id","file"}]}
status  → {"ok":true,"sync":"online"|"connecting"|"offline","hub","pending","head","replica",
           "data","socket","mode":"plugin"|"background","daemon":"<version>","started":bool}
```

`changed: false` means the note already had that text (nothing was sent).
`self: true` in history is this computer; other replicas are the user's other
devices. `inserted`/`deleted` count UTF-16 code units.

## Exit codes

| Code | Meaning | What to do |
|---|---|---|
| 0 | Done | |
| 1 | Not found (note, folder, `replace` text, no `search` match) | `ls -r`, `search`, or check the text with `cat` |
| 2 | Ambiguous (name, or `replace` text found more than once) | Use an id, a longer path, or more context; `--all` only if the user wants every occurrence |
| 3 | Conflict (`rmdir` not empty, `export` into a non-empty directory, note open in another program) | Ask the user |
| 64 | Usage | See `omajot <command> --help` |
| 69 | No daemon (none runs and none could start, or `--no-start`) | `omajot status`; see `<data>/daemon.log` |
| 70 | Other error | Report the message to the user |

## Good to know

- A write while the user types in the same note is safe: both changes stay.
- `ls` shows pinned notes first, then the notes that changed last.
- Attachments are links like `![](attachments/<sha256>.png)`; keep them as they are.
- The daemon that a command starts stops after 10 minutes without commands.
