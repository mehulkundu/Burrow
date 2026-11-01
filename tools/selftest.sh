#!/bin/zsh
# Runs the in-app self-test on a sample folder in /tmp. Exit code 0 when every check passed.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.mehul.burrow.savedState
APP_STORE=/tmp/Burrow-self ~/Applications/Burrow.app/Contents/MacOS/Burrow --selftest
