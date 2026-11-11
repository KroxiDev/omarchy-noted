# How Noted works

The details behind Noted, for anyone curious and for people (or agents)
working on the code. You don't need any of this to use it.

## Requirements

Noted is built for Omarchy 4 (developed on 4.0.6) and runs inside
`omarchy-shell` (Quickshell). Everything else comes with a standard Omarchy
install:

| Dependency | Used for |
| --- | --- |
| `/usr/bin/python3` | The two helper scripts in `bin/` |
| `python-gobject` | Talking to the desktop's file chooser |
| `xdg-desktop-portal` with a FileChooser backend (`xdg-desktop-portal-gtk` on Omarchy) | The **Save as** dialog |
| `gio` (from `glib2`) | Moving notes to the Trash and restoring them |
| `notify-send` (from `libnotify`) | Warnings shown while Noted is hidden |
| `xdg-user-dirs` (optional) | Finding your Documents folder when it has a translated name |

## Where your notes live

There are two kinds of notes:

- **Drafts.** Every new note starts as a draft. Drafts are autosaved to
  `$XDG_STATE_HOME/noted/drafts` (usually `~/.local/state/noted/drafts`) with a
  name like `2026-11-03_174012.md`. The footer shows *Draft · autosaved*.
- **Saved notes.** After **Ctrl+S** a note is a regular file wherever you chose.
  Noted edits that file directly. There are no hidden copies.

The notes folder is the `folder` setting. When it's empty, Noted uses
`Noted` inside your Documents folder (found with `xdg-user-dir DOCUMENTS`, or
`~/Documents` when that's unavailable). Paths may start with `~`.

The list shows, newest first:

- every `.md` file directly inside the notes folder, including files made by
  other apps;
- all drafts;
- files you saved outside the notes folder. Noted remembers these in
  `$XDG_STATE_HOME/noted/catalog.json`.

A note's title is its first non-empty line, without leading `#`. An empty
note falls back to its file name.

Changing the notes folder doesn't move any files. Noted saves pending edits
first, then switches. Drafts and files saved elsewhere stay in the list.

## Saving

- Noted autosaves 300 ms after you stop typing, when you leave a note, when you
  hide Noted, and when the shell shuts down. A forced power-off can lose the
  last few keystrokes.
- Writes are atomic: a file is either the old version or the new one, never
  half-written.
- A new note you never type in doesn't create a file.
- If you clear a saved note completely, Noted moves it to the Trash when you
  leave it, so the last content can still be restored. If another app changed
  the file in the meantime, Noted leaves it alone.
- **Ctrl+S** on a draft opens the save dialog in the notes folder, with a file
  name taken from the note's first line. On a saved note it saves right away
  (useful to retry after an error).
- **Ctrl+Shift+S** (or right-clicking the save icon) picks a new name or place.
  Saving from A to B writes B, then moves A to the Trash. From then on the note
  is B. Picking the same path moves nothing. If A can't be moved to the Trash,
  it stays where it is and Noted tells you.
- The dialog asks before replacing an existing file. Files inside the notes
  folder must end in `.md`.

## Changes from other apps

Noted watches the open file. If another app changes it and you have no
unsaved edits, Noted reloads it.

Before writing, Noted checks the file is still the version it last read. If it
changed in the meantime, Noted doesn't overwrite it. It shows three ways out:

- **Overwrite** keeps your version.
- **Reload** throws away your pending edits and loads the file.
- **Save as** (**Ctrl+Shift+S**) puts your text in a different file.

The check is optimistic, not a lock: avoid editing the same file from two
editors at the same moment.

## When a save fails

Your text is never dropped:

- The text stays in Noted, with a message explaining what went wrong (full
  disk, missing permissions, and so on). If Noted is hidden, you get a
  notification instead.
- If the shell shuts down with text that still couldn't be saved, Noted writes
  it as a new draft named `recovered-….md` and tells you. The original file is
  left untouched. If the drafts folder can't be written either, recovery isn't
  possible, and the notification says so.

## Deleting and undo

- Deleting needs two clicks within three seconds.
- Deleted notes go to the system Trash (`gio trash`), never straight to
  oblivion.
- **↶**, or **Ctrl+Z** in the list, restores deleted notes one at a time,
  newest first. The undo history is shared by all bars and lasts until the
  shell restarts. After that, restore from your file manager's Trash.
- A restore is refused if a file already exists at that path, or if the Trash
  holds zero or several matching copies.

## The window

- Noted opens next to the bar you clicked, on any edge: top, bottom, left or
  right.
- Only one Noted window is open at a time, even with several bars or monitors.
- A click outside hides Noted. That click doesn't reach the app underneath.
  The bar itself stays clickable.
- Hiding and reopening a note keeps its cursor, scroll position and undo
  history.
- Text is plain: no Markdown preview or syntax highlighting.

## Commands

The shell exposes four commands:

```sh
omarchy-shell krox.noted toggle
omarchy-shell krox.noted open
omarchy-shell krox.noted close
omarchy-shell krox.noted newNote
```

They open Noted on the focused monitor's bar, or on the first bar if that
monitor has none.

## Language

`language` can be `auto` (the default), `en` or `es`. With `auto`, Noted uses
the first of these that is set: Omarchy's language
(`~/.config/omarchy/language`), `LC_ALL`, `LC_MESSAGES`, `LANG`. Anything other
than English or Spanish falls back to English. Regional variants such as
`es-MX` only change date formats. Language changes apply without restarting.

## Limits

- Symbolic links aren't supported anywhere in a note's path. If your Documents
  folder is a symlink, set `folder` to the real path.
- Files must be UTF-8 text.

## For contributors

| Path | What it is |
| --- | --- |
| `manifest.json` | Plugin manifest: id `krox.noted`, settings schema |
| `Panel.qml` | The bar button and all note logic: autosave, conflicts, Trash, undo, commands |
| `NotedPopup.qml` | The floating card, its placement and outside-click handling |
| `NoteEditor.qml`, `ActionButton.qml`, `SaveButton.qml` | UI pieces |
| `Session.js` | Coordinates copies on several bars: one window at a time, one command owner, shared undo |
| `Strings.qml`, `Locale.js`, `i18n/*.json` | Translations and language choice |
| `bin/noted-store` | Python helper for every file operation. Reads one JSON request on stdin and prints one JSON reply |
| `bin/noted-save-dialog` | Opens the portal's Save dialog and prints the chosen path |
| `tests/` | Automated tests |

Run the checks from the repository root on Omarchy:

```sh
omarchy plugin validate .
python3 -m unittest discover -s tests -p 'test_*.py' -v
node tests/test_logic.cjs
bash tests/test_fileview.sh
```

The FileView check uses offscreen Qt and temporary files. Run it as a regular
user so its permission checks are meaningful. None of these tests use your notes.
GitHub Actions runs the same checks in an Arch Linux container on pushes and
pull requests, using Arch's Quickshell package and a pinned Omarchy validator.

Notes for changes:

- `bin/noted-store` operations: `init`, `list`, `allocate`, `info`, `trash`,
  `restore`, `save-as`. It also accepts `trash-file <path> [folder]` as
  arguments, used during shutdown. Errors come back as keys that match entries
  in `i18n/*.json`.
- Adding a language takes more than a new `i18n/<code>.json`. `Locale.js` only
  accepts `en` and `es`, `Strings.qml` loads exactly those two catalogs, and
  the `language` options live in `manifest.json`.
- Versions before 1.0 kept linked copies listed in `links.json`. On the first
  `init`, `noted-store` adds the files listed there to the catalog once. It
  never deletes anything.
