# Burrow

A native macOS file manager in SwiftUI that works like Windows File Explorer:
navigation pane with Quick access pins and a This Mac tree, address bar with
breadcrumbs, details view, Ctrl+X / Ctrl+C / Ctrl+V, recursive name search.

## Layout

- `Sources/Burrow/App.swift` window group (tabs), menus, the /tmp sample folder (`Fixture`).
- `Sources/Burrow/Model.swift` `FS` (disk work off the main thread), `Prefs` (pins, hidden items), `Clip` (cut marks), `Browser` (one window: navigation, actions, Explorer keys in `handle(_:)`).
- `Sources/Burrow/Views.swift` every view.
- `build.sh` builds, signs, and installs `~/Applications/Burrow.app`.

## Build and check

- Build and install: `./build.sh` (`--open` restarts the app). Fix every warning.
- Self-test: `tools/selftest.sh`. Runs real file actions on `/tmp/Burrow-self`, exit 0 when every check passes. Add a check for every new action in `SelfTest.swift`.
- Snapshots: `tools/snap.sh` writes `/tmp/Burrow-shots/{thismac,folder,cut-rename,search}-{light,dark}.png`. Look at them after UI changes. Without Screen Recording permission the sidebar renders blank.
- Self-test and snapshots refuse to run unless `APP_STORE` is in /tmp. They never touch the real pasteboard or the real pins.

## Rules

- Never overwrite a file: name clashes get " (2)", copies into the same folder get " - Copy".
- Delete moves to the Trash. There is no permanent delete.
- Keys work with Ctrl (Windows habit) and Cmd. A key handler ignores events while a text field has focus.
- System controls, SF Symbols, `.primary` / `.secondary` colors.

## Git

- Commit after each working change, with a message that says what the user can now do.
