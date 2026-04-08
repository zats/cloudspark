#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPCAST_PATH="$ROOT_DIR/appcast.xml"
NOTES_TO_HTML_SCRIPT="$ROOT_DIR/scripts/release-notes-to-html.py"
ZIP_PATH="${1:?usage: scripts/make-appcast.sh <zip> <version> <tag> <notes-file> [feed-url]}"
VERSION="${2:?usage: scripts/make-appcast.sh <zip> <version> <tag> <notes-file> [feed-url]}"
TAG="${3:?usage: scripts/make-appcast.sh <zip> <version> <tag> <notes-file> [feed-url]}"
NOTES_FILE="${4:?usage: scripts/make-appcast.sh <zip> <version> <tag> <notes-file> [feed-url]}"
FEED_URL="${5:-https://raw.githubusercontent.com/zats/cloudspark/main/appcast.xml}"
SPARKLE_KEYCHAIN_ACCOUNT="${SPARKLE_KEYCHAIN_ACCOUNT:-cloudspark}"

find_sparkle_tool() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  if [[ -n "${SPARKLE_BIN_DIR:-}" && -x "${SPARKLE_BIN_DIR}/$name" ]]; then
    printf '%s\n' "${SPARKLE_BIN_DIR}/$name"
    return 0
  fi
  local candidate
  for candidate in /opt/homebrew/Caskroom/sparkle/*/bin/"$name" /Applications/sparkle.app/Contents/bin/"$name"; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

GENERATE_APPCAST="$(find_sparkle_tool generate_appcast)" || {
  echo "Missing generate_appcast. Install Sparkle tools or set SPARKLE_BIN_DIR." >&2
  exit 1
}

[[ -f "$ZIP_PATH" ]] || { echo "Zip not found: $ZIP_PATH" >&2; exit 1; }
[[ -f "$NOTES_FILE" ]] || { echo "Notes file not found: $NOTES_FILE" >&2; exit 1; }
[[ -f "$NOTES_TO_HTML_SCRIPT" ]] || { echo "Missing $NOTES_TO_HTML_SCRIPT" >&2; exit 1; }

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cloudspark-appcast.XXXXXX")"
cleanup() {
  if [[ -d "${WORK_DIR:-}" ]]; then
    trash "$WORK_DIR" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

ZIP_NAME="$(basename "$ZIP_PATH")"
HTML_NAME="${ZIP_NAME%.zip}.html"
DOWNLOAD_PREFIX="https://github.com/zats/cloudspark/releases/download/${TAG}/"

cp "$ZIP_PATH" "$WORK_DIR/$ZIP_NAME"
if [[ -f "$APPCAST_PATH" ]]; then
  cp "$APPCAST_PATH" "$WORK_DIR/appcast.xml"
fi
python3 "$NOTES_TO_HTML_SCRIPT" "$NOTES_FILE" "$WORK_DIR/$HTML_NAME"

"$GENERATE_APPCAST" \
  --account "$SPARKLE_KEYCHAIN_ACCOUNT" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  --embed-release-notes \
  --link "$FEED_URL" \
  "$WORK_DIR"

cp "$WORK_DIR/appcast.xml" "$APPCAST_PATH"

python3 - "$APPCAST_PATH" "$VERSION" "$TAG" <<'PY'
import sys
import xml.etree.ElementTree as ET

path, version, tag = sys.argv[1:]
tree = ET.parse(path)
root = tree.getroot()
ns = {
    "sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle",
}
for item in root.findall("./channel/item"):
    short = item.findtext("sparkle:shortVersionString", namespaces=ns)
    enclosure = item.find("enclosure")
    if short == version and enclosure is not None:
        url = enclosure.attrib.get("url", "")
        if f"/download/{tag}/Cloudspark-macos.zip" in url:
            sys.exit(0)
sys.exit(f"appcast missing version {version} for {tag}")
PY

echo "Updated appcast: $APPCAST_PATH"
