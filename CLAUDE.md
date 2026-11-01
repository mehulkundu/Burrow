# Burrow

A native macOS file manager in SwiftUI that works like Windows 11 File Explorer,
dressed in Liquid Glass, with the best of Finder and the power tools on top:
Quick Look, tags, undo, dual pane, batch rename, zip, folder sizes, Spotlight
search. `docs/EXPLORER.md` is the spec.

## Layout

- `Sources/Burrow/App.swift` window group (tabs), menus, the /tmp sample folder (`Fixture`).
- `Sources/Burrow/Model.swift` `FS` (disk work and Spotlight off the main thread), `Prefs` (Favorites, hidden items, view, details pane), `Clip` (cut marks), `Browser` (one window: navigation, search, actions, Explorer keys in `handle(_:)`).
- `Sources/Burrow/Views.swift` the window: `Workspace` (one or two panes), sidebar, glass header, command and status bars.
- `Sources/Burrow/Pages.swift` what a pane shows: details table, icon grid, Home, This Mac, details panel, batch rename sheet.
- `build.sh` builds, signs, and installs `~/Applications/Burrow.app`.

## Build and check

- Build and install: `./build.sh` (`--open` restarts the app). Fix every warning.
- Self-test: `tools/selftest.sh`. Runs real file actions on `/tmp/Burrow-self`, exit 0 when every check passes. Add a check for every new action in `SelfTest.swift`.
- Snapshots: `tools/snap.sh` writes `/tmp/Burrow-shots/{home,thismac,thismac-search,folder,icons,search}-{light,dark}.png`. Look at them after UI changes. Without Screen Recording permission the sidebar renders blank.
- Self-test and snapshots refuse to run unless `APP_STORE` is in /tmp. They never touch the real pasteboard or the real pins.

## Rules

- Never overwrite a file: name clashes get " (2)", copies into the same folder get " - Copy".
- Delete moves to the Trash. There is no permanent delete.
- Every file action records itself in `History` so Ctrl+Z can reverse it.
- No layout feedback: never size a view from its own measured width (AppKit kills the app after too many layout passes). Use `ViewThatFits`.
- Keys work with Ctrl (Windows habit) and Cmd. A key handler ignores events while a text field has focus.
- System controls, SF Symbols, `.primary` / `.secondary` colors.

## Git

- Commit after each working change, with a message that says what the user can now do.
