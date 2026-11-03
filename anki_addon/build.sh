#!/usr/bin/env bash
# Build a distributable .ankiaddon (zip with the package at the root).
set -euo pipefail
cd "$(dirname "$0")"
rm -rf dist
mkdir -p dist
# Anki expects __init__.py/manifest.json at the archive root, not inside a
# parent folder.
(cd a_fish_in_sea && zip -qr ../dist/a_fish_in_sea.ankiaddon . \
  -x '*.pyc' -x '__pycache__/*' -x '.DS_Store')
echo "built dist/a_fish_in_sea.ankiaddon"
