#!/bin/zsh
# Snapshots of This Mac, a sample folder, cut + rename, and search, in light and dark.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.mehul.burrow.savedState
rm -rf /tmp/Burrow-shots
APP_STORE=/tmp/Burrow-test APP_SNAPSHOT=/tmp/Burrow-shots ~/Applications/Burrow.app/Contents/MacOS/Burrow
