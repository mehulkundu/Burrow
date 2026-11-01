# Burrow

A Mac file manager that works like Windows 11 File Explorer, dressed in Liquid
Glass: tabs, dual pane, details and icon views, Quick Look, tags, undo, batch
rename, zip, folder sizes and Spotlight search.

## Download

Get `Burrow-<version>.zip` from the [latest release](https://github.com/mehulkundu/Burrow/releases/latest),
unzip it, and drag Burrow.app to Applications.

Needs macOS 26 (Tahoe) on an Apple silicon Mac.

Burrow isn't notarized by Apple yet, so the first launch is blocked with
"Apple could not verify Burrow". To open it anyway, either:

- open System Settings > Privacy & Security, scroll down, and click **Open Anyway** next to Burrow, or
- run this once in Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Burrow.app
```

## Build from source

Needs Xcode 26.

```bash
./build.sh --open
```

This builds, signs, and installs `~/Applications/Burrow.app`. `tools/selftest.sh`
runs the self-test. `docs/EXPLORER.md` is the spec.

## Release

Push a version tag. GitHub Actions builds the app and publishes the zip on the
Releases page.

```bash
git tag v0.2.0 && git push origin v0.2.0
```
