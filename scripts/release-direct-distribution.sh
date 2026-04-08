#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/app/Cloudspark.xcodeproj"
SCHEME="Cloudspark"
CONFIGURATION="Release"
ASSET_NAME="Cloudspark-macos.zip"

OUTPUT_DIR=""
NOTARY_PROFILE="${APPLE_NOTARY_PROFILE:-}"
PUBLISH_GITHUB=0
DRAFT_RELEASE=0
RELEASE_NOTES_FILE=""
ALLOW_PROVISIONING_UPDATES=0
REPO="${GITHUB_REPOSITORY:-}"
TAG=""
TITLE=""
MARKETING_VERSION_OVERRIDE=""
BUILD_NUMBER_OVERRIDE=""
NOTARY_SUBMIT_ATTEMPTS="${NOTARY_SUBMIT_ATTEMPTS:-3}"

usage() {
  cat <<'EOF'
Usage:
  scripts/release-direct-distribution.sh [options]

Options:
  --notary-profile NAME         Keychain profile for xcrun notarytool.
  --output-dir PATH             Where to write final artifacts. Default: temp dir.
  --publish-github              Create or update the GitHub release and upload the zip.
  --draft                       Create the GitHub release as a draft.
  --notes-file PATH             Release notes file for gh release create/edit.
  --repo OWNER/NAME             GitHub repo for release publishing.
  --marketing-version X.Y       Override MARKETING_VERSION for this build.
  --build-number N              Override CURRENT_PROJECT_VERSION for this build.
  --tag vX.Y.Z                  Override Git tag. Default: derived from Xcode version.
  --title "Cloudspark X.Y.Z"    Override release title.
  --allow-provisioning-updates  Pass through to xcodebuild archive.
  -h, --help                    Show help.

Notes:
  - This script uses Apple's notarytool and stapler.
  - Store credentials first, for example:
      xcrun notarytool store-credentials cloudspark-notary --apple-id you@example.com --team-id TEAMID --password app-specific-password
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing command: $1" >&2
    exit 1
  fi
}

load_env_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    return
  fi
  set -a
  # shellcheck disable=SC1090
  source "$file"
  set +a
}

extract_build_setting() {
  local key="$1"
  xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings \
    | awk -F' = ' -v key="$key" '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); if ($1 == key) { print $2; exit } }'
}

cleanup() {
  if [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]]; then
    trash "$WORK_DIR" >/dev/null 2>&1 || true
  fi
}

developer_id_identity() {
  if [[ -n "${CLOUDFLARE2_CODESIGN_IDENTITY:-}" ]]; then
    printf '%s\n' "$CLOUDFLARE2_CODESIGN_IDENTITY"
    return 0
  fi

  codesign -dvv "$APP_PATH" 2>&1 \
    | awk -F= '/^Authority=Developer ID Application:/ {print $2; exit}'
}

resign_sparkle_bundle() {
  local identity="$1"
  local sparkle_path="$APP_PATH/Contents/Frameworks/Sparkle.framework"

  [[ -d "$sparkle_path" ]] || return 0

  echo "Re-signing Sparkle"

  local targets=(
    "$sparkle_path/Versions/B/Sparkle"
    "$sparkle_path/Versions/B/Autoupdate"
    "$sparkle_path/Versions/B/Updater.app/Contents/MacOS/Updater"
    "$sparkle_path/Versions/B/Updater.app"
    "$sparkle_path/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
    "$sparkle_path/Versions/B/XPCServices/Downloader.xpc"
    "$sparkle_path/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
    "$sparkle_path/Versions/B/XPCServices/Installer.xpc"
    "$sparkle_path/Versions/B"
    "$sparkle_path"
    "$APP_PATH"
  )

  local target
  for target in "${targets[@]}"; do
    [[ -e "$target" ]] || continue
    codesign --force --timestamp --options runtime --sign "$identity" "$target"
  done
}

submit_for_notarization() {
  local attempt=1
  local stderr_path="$WORK_DIR/notary-submit.stderr"
  while (( attempt <= NOTARY_SUBMIT_ATTEMPTS )); do
    if xcrun notarytool submit "$SUBMISSION_ZIP_PATH" \
      --keychain-profile "$NOTARY_PROFILE" \
      --wait \
      --output-format plist > "$NOTARY_RESULT_PATH" 2> "$stderr_path"; then
      return 0
    fi

    local stderr_text=""
    if [[ -f "$stderr_path" ]]; then
      stderr_text="$(cat "$stderr_path")"
    fi

    if (( attempt == NOTARY_SUBMIT_ATTEMPTS )) || [[ "$stderr_text" != *"HTTPClientError.connectTimeout"* ]]; then
      if [[ -n "$stderr_text" ]]; then
        echo "$stderr_text" >&2
      fi
      return 1
    fi

    echo "Notary submit timed out. Retrying ($((attempt + 1))/$NOTARY_SUBMIT_ATTEMPTS)..." >&2
    sleep 5
    ((attempt += 1))
  done
}

load_env_file "$ROOT_DIR/.env.local"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notary-profile)
      NOTARY_PROFILE="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --publish-github)
      PUBLISH_GITHUB=1
      shift
      ;;
    --draft)
      DRAFT_RELEASE=1
      shift
      ;;
    --notes-file)
      RELEASE_NOTES_FILE="${2:-}"
      shift 2
      ;;
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --marketing-version)
      MARKETING_VERSION_OVERRIDE="${2:-}"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER_OVERRIDE="${2:-}"
      shift 2
      ;;
    --tag)
      TAG="${2:-}"
      shift 2
      ;;
    --title)
      TITLE="${2:-}"
      shift 2
      ;;
    --allow-provisioning-updates)
      ALLOW_PROVISIONING_UPDATES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

NOTARY_PROFILE="${NOTARY_PROFILE:-${APPLE_NOTARY_PROFILE:-}}"
REPO="${REPO:-${GITHUB_REPOSITORY:-}}"

require_command xcodebuild
require_command xcrun
require_command ditto
require_command trash
require_command codesign
require_command spctl
require_command xcrun

if [[ -z "$NOTARY_PROFILE" ]]; then
  echo "--notary-profile is required. Set it or export APPLE_NOTARY_PROFILE." >&2
  exit 1
fi

if [[ -n "$RELEASE_NOTES_FILE" && ! -f "$RELEASE_NOTES_FILE" ]]; then
  echo "Notes file not found: $RELEASE_NOTES_FILE" >&2
  exit 1
fi

MARKETING_VERSION="${MARKETING_VERSION_OVERRIDE:-$(extract_build_setting MARKETING_VERSION)}"
CURRENT_PROJECT_VERSION="${BUILD_NUMBER_OVERRIDE:-$(extract_build_setting CURRENT_PROJECT_VERSION)}"
PRODUCT_NAME="$(extract_build_setting PRODUCT_NAME)"

if [[ -z "$MARKETING_VERSION" || -z "$CURRENT_PROJECT_VERSION" || -z "$PRODUCT_NAME" ]]; then
  echo "Failed to read build settings from Xcode project." >&2
  exit 1
fi

VERSION="${MARKETING_VERSION}.${CURRENT_PROJECT_VERSION}"
TAG="${TAG:-v$VERSION}"
TITLE="${TITLE:-Cloudspark $VERSION}"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cloudspark-release-work.XXXXXX")"
trap cleanup EXIT

if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cloudspark-release-out.XXXXXX")"
else
  mkdir -p "$OUTPUT_DIR"
fi

ARCHIVE_PATH="$WORK_DIR/${PRODUCT_NAME}.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/${PRODUCT_NAME}.app"
SUBMISSION_ZIP_PATH="$WORK_DIR/${ASSET_NAME}"
FINAL_ZIP_PATH="$OUTPUT_DIR/${ASSET_NAME}"
NOTARY_RESULT_PATH="$OUTPUT_DIR/notary-submit.plist"
NOTARY_LOG_PATH="$OUTPUT_DIR/notary-log.json"
DIRECT_DISTRIBUTION_ENTITLEMENTS_PATH="$WORK_DIR/direct-distribution.entitlements"

if [[ "${CLOUDFLARE2_CODESIGN_IDENTITY:-}" == Developer\ ID\ Application:* ]]; then
  cat > "$DIRECT_DISTRIBUTION_ENTITLEMENTS_PATH" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
EOF
fi

XCODEBUILD_ARGS=(
  -project "$PROJECT_PATH"
  -scheme "$SCHEME"
  -configuration "$CONFIGURATION"
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE_PATH"
  archive
)

if [[ -n "${CLOUDFLARE2_CODESIGN_IDENTITY:-}" ]]; then
  XCODEBUILD_ARGS+=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=$CLOUDFLARE2_CODESIGN_IDENTITY"
    PROVISIONING_PROFILE_SPECIFIER=
  )
fi

if [[ -f "$DIRECT_DISTRIBUTION_ENTITLEMENTS_PATH" ]]; then
  XCODEBUILD_ARGS+=("CODE_SIGN_ENTITLEMENTS=$DIRECT_DISTRIBUTION_ENTITLEMENTS_PATH")
fi

if [[ -n "${CLOUDFLARE2_TEAM_ID:-}" ]]; then
  XCODEBUILD_ARGS+=("DEVELOPMENT_TEAM=$CLOUDFLARE2_TEAM_ID")
fi

if [[ -n "${CLOUDFLARE2_BUNDLE_ID:-}" ]]; then
  XCODEBUILD_ARGS+=("PRODUCT_BUNDLE_IDENTIFIER=$CLOUDFLARE2_BUNDLE_ID")
fi

if [[ -n "$MARKETING_VERSION_OVERRIDE" ]]; then
  XCODEBUILD_ARGS+=("MARKETING_VERSION=$MARKETING_VERSION_OVERRIDE")
fi

if [[ -n "$BUILD_NUMBER_OVERRIDE" ]]; then
  XCODEBUILD_ARGS+=("CURRENT_PROJECT_VERSION=$BUILD_NUMBER_OVERRIDE")
fi

if [[ "$ALLOW_PROVISIONING_UPDATES" -eq 1 ]]; then
  XCODEBUILD_ARGS+=( -allowProvisioningUpdates )
fi

echo "Archiving $PRODUCT_NAME $VERSION"
xcodebuild "${XCODEBUILD_ARGS[@]}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "Archive did not produce app bundle: $APP_PATH" >&2
  exit 1
fi

SIGNING_IDENTITY="$(developer_id_identity)"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "Unable to determine Developer ID signing identity for Sparkle re-signing." >&2
  exit 1
fi

resign_sparkle_bundle "$SIGNING_IDENTITY"

echo "Verifying code signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Creating notarization zip"
ditto -c -k --keepParent "$APP_PATH" "$SUBMISSION_ZIP_PATH"

echo "Submitting for notarization"
submit_for_notarization

SUBMISSION_ID="$(/usr/libexec/PlistBuddy -c 'Print :id' "$NOTARY_RESULT_PATH")"
STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' "$NOTARY_RESULT_PATH")"

if [[ "$STATUS" != "Accepted" ]]; then
  echo "Notarization failed with status: $STATUS" >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    xcrun notarytool log --keychain-profile "$NOTARY_PROFILE" "$SUBMISSION_ID" "$NOTARY_LOG_PATH" || true
    echo "Notary log: $NOTARY_LOG_PATH" >&2
  fi
  exit 1
fi

echo "Stapling app"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"
spctl --assess --type execute --verbose=4 "$APP_PATH"

echo "Creating final distribution zip"
ditto -c -k --keepParent "$APP_PATH" "$FINAL_ZIP_PATH"

if [[ -n "$SUBMISSION_ID" ]]; then
  xcrun notarytool log --keychain-profile "$NOTARY_PROFILE" "$SUBMISSION_ID" "$NOTARY_LOG_PATH" || true
fi

if [[ "$PUBLISH_GITHUB" -eq 1 ]]; then
  require_command gh
  if [[ -z "$REPO" ]]; then
    REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
  fi

  GH_ARGS=( --repo "$REPO" )

  if gh release view "$TAG" "${GH_ARGS[@]}" >/dev/null 2>&1; then
    echo "Uploading asset to existing GitHub release $TAG"
    gh release upload "$TAG" "$FINAL_ZIP_PATH#$ASSET_NAME" --clobber "${GH_ARGS[@]}"
    EDIT_ARGS=( "$TAG" --title "$TITLE" )
    if [[ -n "$RELEASE_NOTES_FILE" ]]; then
      EDIT_ARGS+=( --notes-file "$RELEASE_NOTES_FILE" )
    fi
    gh release edit "${EDIT_ARGS[@]}" "${GH_ARGS[@]}"
  else
    echo "Creating GitHub release $TAG"
    CREATE_ARGS=( "$TAG" "$FINAL_ZIP_PATH#$ASSET_NAME" --title "$TITLE" )
    if [[ "$DRAFT_RELEASE" -eq 1 ]]; then
      CREATE_ARGS+=( --draft )
    fi
    if [[ -n "$RELEASE_NOTES_FILE" ]]; then
      CREATE_ARGS+=( --notes-file "$RELEASE_NOTES_FILE" )
    fi
    gh release create "${CREATE_ARGS[@]}" "${GH_ARGS[@]}"
  fi
fi

echo
echo "Version: $VERSION"
echo "Tag: $TAG"
echo "Title: $TITLE"
echo "Artifact: $FINAL_ZIP_PATH"
echo "Notary result: $NOTARY_RESULT_PATH"
if [[ -f "$NOTARY_LOG_PATH" ]]; then
  echo "Notary log: $NOTARY_LOG_PATH"
fi
