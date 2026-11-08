#!/usr/bin/env bash
# Install/update the add-on in the local Anki profile directory.
#
# Usage: ./install.sh [Anki2-base-dir]
# Defaults to the platform's standard Anki data directory. Existing
# config.json is left untouched so an update never erases the token.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
src="$here/a_fish_in_sea"

if [ "${1:-}" != "" ]; then
  base="$1"
elif [ "$(uname -s)" = "Darwin" ]; then
  base="$HOME/Library/Application Support/Anki2"
elif [ -d "$HOME/.var/app/net.ankiweb.Anki/data/Anki2" ]; then
  base="$HOME/.var/app/net.ankiweb.Anki/data/Anki2"
else
  base="$HOME/.local/share/Anki2"
fi

dest="$base/addons21/a_fish_in_sea"
if [ ! -d "$base" ]; then
  echo "Anki data directory not found: $base" >&2
  echo "Pass it explicitly: ./install.sh /path/to/Anki2" >&2
  exit 1
fi

mkdir -p "$dest"
cp "$src/__init__.py" "$src/report.py" "$src/manifest.json" "$src/config.md" "$dest/"
if [ ! -f "$dest/config.json" ]; then
  cp "$src/config.json" "$dest/config.json"
fi
echo "Installed to $dest"
echo "Restart Anki, then Tools → A Fish in Sea: Test connection."
