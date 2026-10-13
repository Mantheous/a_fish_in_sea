#!/usr/bin/env bash
# Downloads remote image attachments referenced in an issue body/comments
# to a local dir so headless agents (which can READ local images via the
# read tool but cannot view remote URLs) can see screenshots.
# Usage: fetch-issue-images.sh <issue-number> [outdir]
# Prints downloaded paths, one per line. Safe to re-run. Never touches git.
set -euo pipefail
N="${1:?usage: fetch-issue-images.sh <issue-number> [outdir]}"
OUT="${2:-/tmp/opencode/issue-$N-imgs}"
mkdir -p "$OUT"
TEXT_FILE="$OUT/.issue-text.txt"
URLS_FILE="$OUT/.urls.txt"
if ! gh issue view "$N" --json body,comments --jq '[.body] + [.comments[].body] | join("\n")' >"$TEXT_FILE" 2>/dev/null; then
  echo "[fetch-images] #$N: could not read issue text" >&2
  exit 0
fi
python3 - "$TEXT_FILE" "$URLS_FILE" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
urls: list[str] = []
patterns = [
    r'<img[^>]+src=["\']([^"\']+)["\']',
    r'!\[[^\]]*\]\((https?://[^)\s]+)\)',
    r'(https://github\.com/user-attachments/assets/[A-Za-z0-9\-]+)',
    r'(https://[^\s)"\'<>]+\.(?:png|jpg|jpeg|gif|webp)(?:\?[^\s)"\'<>]*)?)',
]
for pat in patterns:
    for m in re.findall(pat, text, flags=re.IGNORECASE):
        u = m.strip().rstrip(').,.')
        if u and u not in urls:
            urls.append(u)
open(sys.argv[2], "w").write("\n".join(urls) + ("\n" if urls else ""))
PY
i=0
while IFS= read -r URL; do
  [ -z "${URL:-}" ] && continue
  i=$((i + 1))
  EXT="png"
  case "$URL" in
    *.jpg*|*.jpeg*|*.JPG*|*.JPEG*) EXT="jpg" ;;
    *.gif*|*.GIF*) EXT="gif" ;;
    *.webp*|*.WEBP*) EXT="webp" ;;
  esac
  DEST="$OUT/img${i}.${EXT}"
  if [ -f "$DEST" ]; then
    echo "$DEST"
    continue
  fi
  if curl -sL --max-time 30 "$URL" -o "$DEST" 2>/dev/null; then
    if file "$DEST" 2>/dev/null | grep -qiE 'image|PNG|JPEG|GIF|WebP'; then
      echo "$DEST"
    else
      rm -f "$DEST"
    fi
  fi
done <"$URLS_FILE"
