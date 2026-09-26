//! Help texts of the omajot commands. site/pages/cli.html and SKILL.md
//! repeat them; change them together.
const std = @import("std");

pub const Verb = struct {
    name: []const u8,
    /// One line for the overview.
    summary: []const u8,
    help: []const u8,
    /// Options that take a value, and options that do not.
    values: []const []const u8 = &.{},
    bools: []const []const u8 = &.{},
    /// Short forms: {"-r", "--recursive"}.
    short: []const [2][]const u8 = &.{},
};

pub fn find(name: []const u8) ?Verb {
    for (verbs) |v| if (std.mem.eql(u8, v.name, name)) return v;
    return null;
}

const common =
    \\
    \\Options for all commands:
    \\  --json           Write the result as one JSON object to stdout
    \\  --data <dir>     Use this data directory
    \\  --socket <path>  Use the daemon on this socket
    \\  --no-start       Do not start a daemon; fail with exit code 69
    \\  --hub <url>, --no-hub
    \\                   Hub for a daemon that the command starts
    \\
;

const addressing =
    \\A note is "Folder/Subfolder/Title" (the title is the first line of the
    \\note, without "# "), only "Title", or its id ("n-…").
    \\
;

pub const overview =
    \\usage: omajot <command> [arguments] [options]
    \\
    \\Read and change your omajot notes from a terminal or a script.
    \\The commands use the omajot daemon of your data directory. When no
    \\daemon runs, a command starts one in the background.
    \\
    \\Notes:
    \\  ls [folder]                 List notes and folders
    \\  cat <note>                  Write the text of a note to stdout
    \\  search <text>               Find the notes that contain a text
    \\  new <title> [text|-]        Make a note
    \\  write <note>                Replace the text of a note with stdin
    \\  edit <note>                 Change a note in your text editor
    \\  append <note> <text|->      Add text to the end of a note
    \\  replace <note> <old> <new>  Replace a text in a note
    \\  mv <note> <folder>          Move a note to a folder
    \\  rm <note>                   Move a note to the Trash (--restore: back)
    \\  history <note>              List the versions of a note
    \\  restore <note> <version>    Make an earlier version the current text
    \\  tags                        List the tags and how many notes use them
    \\
    \\Folders:
    \\  mkdir <path>                Make a folder
    \\  rmdir <folder>              Delete an empty folder
    \\
    \\Other:
    \\  tui                         Browse and edit your notes in the terminal
    \\  export <dir>                Write all notes as Markdown files
    \\  status                      Show the daemon and the sync state
    \\  qr [url]                    Show the hub address as a QR code
    \\  daemon, hub                 Run the daemon or the hub (see --help)
    \\  --version                   Print the version
    \\
++ addressing ++
    \\
    \\Exit codes: 0 done, 1 not found, 2 ambiguous, 3 conflict, 64 usage,
    \\69 no daemon, 70 other error.
    \\
    \\Run "omajot <command> --help" for the details and examples of a command.
    \\
++ common;

pub const verbs = [_]Verb{
    .{
        .name = "ls",
        .summary = "List notes and folders",
        .values = &.{"--tag"},
        .bools = &.{ "--recursive", "--trash", "--long" },
        .short = &.{ .{ "-r", "--recursive" }, .{ "-l", "--long" } },
        .help =
        \\usage: omajot ls [folder] [-r] [-l] [--tag <tag>] [--trash]
        \\
        \\List the folders and notes in a folder. Without a folder: the top level.
        \\Pinned notes come first, then the notes that changed last.
        \\
        \\  -r, --recursive  Also list the notes in all subfolders, as paths
        \\  -l, --long       Also show the time of the last change and the id
        \\  --tag <tag>      Only notes with this tag (with or without "#");
        \\                   includes subfolders
        \\  --trash          Only notes in the Trash; includes subfolders
        \\
        \\Examples:
        \\  omajot ls
        \\  omajot ls Work -r
        \\  omajot ls --tag todo -l
        \\  omajot ls --json | jq -r '.notes[].path'
        \\
        ++ common,
    },
    .{
        .name = "cat",
        .summary = "Write the text of a note to stdout",
        .values = &.{"--at"},
        .help =
        \\usage: omajot cat <note> [--at <time>]
        \\
        \\Write the Markdown text of a note to stdout, exactly as stored.
        \\
        \\  --at <time>  The text as it was at this time. <time> is
        \\               "2026-09-26 14:03" (local time), "2026-09-26T12:03Z" (UTC),
        \\               "2026-09-26", or a time ago: 90s, 15m, 2h, 3d, 1w.
        \\
        ++ addressing ++
        \\
        \\Examples:
        \\  omajot cat "Work/Plans/Q3"
        \\  omajot cat n-3f9c2a1b7d4e5f60-42
        \\  omajot cat Groceries --at 2d
        \\
        ++ common,
    },
    .{
        .name = "search",
        .summary = "Find the notes that contain a text",
        .bools = &.{"--trash"},
        .help =
        \\usage: omajot search <text> [--trash]
        \\
        \\Find the notes whose title or text contains <text>. Case is ignored.
        \\Writes the path of each note, the note that changed last first. Exit
        \\code 1 when no note matches.
        \\
        \\  --trash  Search the notes in the Trash instead
        \\
        \\Examples:
        \\  omajot search invoice
        \\  omajot search "#todo" --json
        \\
        ++ common,
    },
    .{
        .name = "new",
        .summary = "Make a note",
        .values = &.{"--folder"},
        .help =
        \\usage: omajot new <title> [text|-] [--folder <folder>]
        \\
        \\Make a note. Its text is "# <title>", an empty line, and the text.
        \\"-" reads the text from stdin. Writes the path of the new note.
        \\
        \\  --folder <folder>  Put the note in this folder. omajot makes the
        \\                     folder and its parent folders if necessary.
        \\
        \\Examples:
        \\  omajot new "Groceries" "- milk"
        \\  omajot new "Meeting 2026-09-26" --folder Work/Meetings
        \\  git log -5 --oneline | omajot new "Release notes" - --folder Work
        \\
        ++ common,
    },
    .{
        .name = "write",
        .summary = "Replace the text of a note with stdin",
        .values = &.{"--folder"},
        .help =
        \\usage: omajot write <note> [--folder <folder>] < text
        \\
        \\Make stdin the full text of a note. omajot applies only the parts that
        \\are different, so changes from other devices in other parts of the note
        \\stay.
        \\
        \\When the note does not exist, omajot makes it: in --folder, or in the
        \\folder of the path ("Work/Todo" goes into Work). When the first line of
        \\the text is not the title, omajot adds "# <title>" at the top, so that
        \\the name finds the note again.
        \\
        ++ addressing ++
        \\
        \\Examples:
        \\  omajot cat Todo > todo.md; $EDITOR todo.md; omajot write Todo < todo.md
        \\  printf '# Status\n\nAll green.\n' | omajot write Work/Status
        \\
        ++ common,
    },
    .{
        .name = "edit",
        .summary = "Change a note in your text editor",
        .help =
        \\usage: omajot edit <note>
        \\
        \\Open the note in your text editor. Each time you save, omajot applies
        \\your changes to the note, also while other devices change it. omajot
        \\applies the last save again when the editor closes.
        \\
        \\The editor: $VISUAL, else $EDITOR, else vi. The value can have
        \\arguments, for example "code --wait" or "nvim -u NONE"; omajot runs it
        \\with sh -c. A graphical editor must wait until you close the file
        \\(code --wait, subl -w, gedit -s). When no editor is set and vi is not
        \\installed, the command fails: set $EDITOR.
        \\
        \\The file is in a private temporary directory, which omajot deletes
        \\after the editor closes.
        \\
        ++ addressing ++
        \\
        \\Examples:
        \\  omajot edit Todo
        \\  EDITOR="code --wait" omajot edit "Work/Plans/Q3"
        \\
        ++ common,
    },
    .{
        .name = "append",
        .summary = "Add text to the end of a note",
        .help =
        \\usage: omajot append <note> <text|->
        \\
        \\Add the text to the end of the note, on a new line. "-" reads the text
        \\from stdin. omajot adds a line break at the end when the text has none.
        \\
        \\Examples:
        \\  omajot append Groceries "- eggs"
        \\  date | omajot append Log -
        \\
        ++ common,
    },
    .{
        .name = "replace",
        .summary = "Replace a text in a note",
        .bools = &.{"--all"},
        .help =
        \\usage: omajot replace <note> <old> <new> [--all]
        \\
        \\Replace the text <old> with <new>. <old> must occur exactly one time:
        \\when the note does not contain it, exit code 1; when it occurs more
        \\than one time, exit code 2 and no change. Add more of the text around
        \\<old> to make it unique, or use --all. Case matters. Changes made on
        \\other devices at the same time stay.
        \\
        \\  --all  Replace every occurrence
        \\
        \\Examples:
        \\  omajot replace Todo "- [ ] call Anna" "- [x] call Anna"
        \\  omajot replace Notes "2025" "2026" --all
        \\
        ++ common,
    },
    .{
        .name = "mv",
        .summary = "Move a note to a folder",
        .help =
        \\usage: omajot mv <note> <folder>
        \\
        \\Move the note to the folder. "/" is the top level. The folder must
        \\exist (see omajot mkdir).
        \\
        \\Examples:
        \\  omajot mv Todo Work
        \\  omajot mv "Work/Old plan" /
        \\
        ++ common,
    },
    .{
        .name = "rm",
        .summary = "Move a note to the Trash",
        .bools = &.{"--restore"},
        .help =
        \\usage: omajot rm <note> [--restore]
        \\
        \\Move the note to the Trash. omajot does not delete notes: you can get
        \\them back from the Trash.
        \\
        \\  --restore  Move the note out of the Trash
        \\
        \\Examples:
        \\  omajot rm "Old idea"
        \\  omajot rm "Old idea" --restore
        \\
        ++ common,
    },
    .{
        .name = "mkdir",
        .summary = "Make a folder",
        .help =
        \\usage: omajot mkdir <path>
        \\
        \\Make the folder and its missing parent folders. A folder that exists
        \\is not an error.
        \\
        \\Examples:
        \\  omajot mkdir Work/Meetings/2026
        \\
        ++ common,
    },
    .{
        .name = "rmdir",
        .summary = "Delete a folder",
        .bools = &.{"--force"},
        .help =
        \\usage: omajot rmdir <folder> [--force]
        \\
        \\Delete an empty folder. When the folder has notes or folders, the
        \\command stops with exit code 3.
        \\
        \\  --force  Delete the folder all the same. Its notes move to the top
        \\           level and its folders to the parent folder. No note is deleted.
        \\
        \\Examples:
        \\  omajot rmdir Work/Old
        \\
        ++ common,
    },
    .{
        .name = "tags",
        .summary = "List the tags",
        .help =
        \\usage: omajot tags
        \\
        \\List the tags ("#word" in the text) of the notes that are not in the
        \\Trash, with the number of notes, the most used first.
        \\
        \\Examples:
        \\  omajot tags
        \\  omajot ls --tag todo
        \\
        ++ common,
    },
    .{
        .name = "history",
        .summary = "List the versions of a note",
        .help =
        \\usage: omajot history <note>
        \\
        \\List the versions of a note, the oldest first. A version is a group of
        \\changes from one device with less than one minute between them. For
        \\each version: the number, the time of its last change, the device, and
        \\the number of characters added and removed.
        \\
        \\Show an old text with "omajot cat --at", and make it the current text
        \\with "omajot restore".
        \\
        \\Examples:
        \\  omajot history Todo
        \\  omajot restore Todo 3
        \\
        ++ common,
    },
    .{
        .name = "restore",
        .summary = "Make an earlier version the current text",
        .help =
        \\usage: omajot restore <note> <version|time>
        \\
        \\Make the text of an earlier version the current text of the note.
        \\omajot applies it as a normal change: it syncs to your other devices,
        \\and the history keeps every version, so you can undo the restore.
        \\
        \\<version> is a number from "omajot history". <time> is
        \\"2026-09-26 14:03" (local time), "2026-09-26T12:03Z" (UTC), or a time
        \\ago: 90s, 15m, 2h, 3d, 1w.
        \\
        \\Examples:
        \\  omajot restore Todo 3
        \\  omajot restore Todo 2h
        \\
        ++ common,
    },
    .{
        .name = "export",
        .summary = "Write all notes as Markdown files",
        .bools = &.{ "--trash", "--force" },
        .help =
        \\usage: omajot export <dir> [--trash] [--force]
        \\
        \\Write every note as a Markdown file: <dir>/Folder/Subfolder/Title.md.
        \\Attachments go to <dir>/attachments/, and the links in the notes still
        \\work. <dir>/README.md tells what the files are. The export is a copy:
        \\changes to the files do not go back into omajot.
        \\
        \\omajot changes characters that file names cannot have to "-". Notes
        \\with the same title get " (2)", " (3)", … at the end of the name.
        \\
        \\  --trash  Also write the notes in the Trash, to <dir>/Trash/
        \\  --force  Write into a directory that is not empty
        \\
        \\Examples:
        \\  omajot export ~/notes-backup
        \\
        ++ common,
    },
    .{
        .name = "status",
        .summary = "Show the daemon and the sync state",
        .help =
        \\usage: omajot status
        \\
        \\Show the daemon (version, how it started), the data directory, the
        \\socket, the hub, and the sync state: online, connecting or offline, and
        \\the number of changes that the hub did not get yet.
        \\
        \\Examples:
        \\  omajot status
        \\  omajot status --no-start
        \\
        ++ common,
    },
};

test "every verb has a help text that starts with its usage" {
    for (verbs) |v| {
        const want = try std.fmt.allocPrint(std.testing.allocator, "usage: omajot {s}", .{v.name});
        defer std.testing.allocator.free(want);
        try std.testing.expect(std.mem.startsWith(u8, v.help, want));
        try std.testing.expect(std.mem.find(u8, overview, v.name) != null);
    }
}
