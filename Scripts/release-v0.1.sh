#!/usr/bin/env bash
# release-v0.1.sh — Pixelbay v0.1 ship pipeline (skeleton).
#
# Drives the codesign + notarize + staple + DMG + appcast steps end-to-end.
# Every action that needs Apple-side secrets is env-var-gated, so the script
# is safe to run in dry-run mode with stub env (no Apple cert, no Sparkle key)
# — those steps log the would-be command and skip. Real signing is human-gated.
#
# Env vars (all optional in dry-run; required for a real ship):
#   CODESIGN_IDENTITY    "Developer ID Application: ..." — codesign + dmg sign
#   NOTARY_PROFILE       keychain profile name for `notarytool --keychain-profile`
#   SPARKLE_KEY_PATH     path to the Sparkle EdDSA private key (for sign_update)
#   RELEASE_VERSION      semver string written into the appcast (defaults to MARKETING_VERSION)
#   RELEASE_NOTES_URL    https URL to per-version release notes (appcast field)
#   APPCAST_DOWNLOAD_URL https URL where the DMG will be hosted (appcast `url=` attr)
#
# Flags:
#   --dry-run            Skip every destructive / network step; log only. Implied
#                        when CODESIGN_IDENTITY is unset.
#   --keep               Keep build/ scratch dir on exit (default: cleaned).
#
# Exits 0 on a successful dry-run with stub env. Exits non-zero on tool error.

set -euo pipefail

# -------- repo paths --------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE="$REPO_ROOT/Pixelbay.xcworkspace"
SCHEME="PixelbayApp"
BUNDLE_ID="com.pixelbay.PixelbayApp"
BUILD_DIR="$REPO_ROOT/build/release-v0.1"
ARCHIVE_PATH="$BUILD_DIR/PixelbayApp.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_VOLNAME="Pixelbay"
DMG_PATH="$BUILD_DIR/Pixelbay.dmg"
APPCAST_PATH="$BUILD_DIR/appcast.xml"

# -------- args --------
DRY_RUN=0
KEEP_BUILD=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --keep)    KEEP_BUILD=1 ;;
    -h|--help)
      sed -n '2,30p' "$0"
      exit 0
      ;;
    *)
      echo "release-v0.1: unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

# CODESIGN_IDENTITY unset implies dry-run — we can't sign without it anyway.
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  DRY_RUN=1
fi

# -------- logging --------
log()  { printf "\033[1;34m[release]\033[0m %s\n" "$*"; }
warn() { printf "\033[1;33m[release]\033[0m %s\n" "$*" >&2; }
err()  { printf "\033[1;31m[release]\033[0m %s\n" "$*" >&2; }

would() {
  # In dry-run, log the command instead of running it.
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "would run: $*"
  else
    log "running: $*"
    "$@"
  fi
}

cleanup() {
  if [[ "$KEEP_BUILD" -eq 1 ]]; then
    log "keeping $BUILD_DIR (--keep)"
    return
  fi
  if [[ -d "$BUILD_DIR" ]]; then
    rm -rf "$BUILD_DIR"
  fi
}
trap cleanup EXIT

# -------- preflight --------
log "repo: $REPO_ROOT"
log "workspace: $WORKSPACE"
log "scheme: $SCHEME"
if [[ "$DRY_RUN" -eq 1 ]]; then
  log "mode: DRY RUN (CODESIGN_IDENTITY unset or --dry-run passed)"
else
  log "mode: REAL (CODESIGN_IDENTITY set)"
fi

mkdir -p "$BUILD_DIR" "$EXPORT_DIR"

resolve_version() {
  if [[ -n "${RELEASE_VERSION:-}" ]]; then
    echo "$RELEASE_VERSION"
    return
  fi
  # Fall back to MARKETING_VERSION in the xcodeproj.
  local pbxproj="$REPO_ROOT/PixelbayApp/PixelbayApp.xcodeproj/project.pbxproj"
  if [[ -f "$pbxproj" ]]; then
    awk -F' = ' '/MARKETING_VERSION/ { gsub(/[;[:space:]]/, "", $2); print $2; exit }' "$pbxproj"
  else
    echo "0.1.0"
  fi
}
VERSION="$(resolve_version)"
log "release version: $VERSION"

# -------- step 1: archive --------
log "step 1/6: xcodebuild archive"
ARCHIVE_CMD=(xcodebuild
  -workspace "$WORKSPACE"
  -scheme "$SCHEME"
  -configuration Release
  -destination "generic/platform=macOS"
  -archivePath "$ARCHIVE_PATH"
  archive
  CODE_SIGN_STYLE=Manual
  ENABLE_HARDENED_RUNTIME=YES)   # notarization requires it; never inherit a local NO
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  ARCHIVE_CMD+=(CODE_SIGN_IDENTITY="$CODESIGN_IDENTITY")
fi
would "${ARCHIVE_CMD[@]}"

# -------- step 2: export (codesigned .app) --------
log "step 2/6: xcodebuild -exportArchive"
EXPORT_OPTIONS_PLIST="$BUILD_DIR/ExportOptions.plist"
cat >"$EXPORT_OPTIONS_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>teamID</key>
    <string>${APPLE_TEAM_ID:-TEAMID0000}</string>
</dict>
</plist>
PLIST
would xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

APP_PATH="$EXPORT_DIR/PixelbayApp.app"

# -------- step 3: notarize --------
log "step 3/6: notarize"
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
  warn "NOTARY_PROFILE unset — skipping notarytool. Real ship needs:"
  warn "  xcrun notarytool submit \"$APP_PATH\" --keychain-profile <profile> --wait"
else
  NOTARIZE_ZIP="$BUILD_DIR/PixelbayApp-notarize.zip"
  would /usr/bin/ditto -c -k --keepParent "$APP_PATH" "$NOTARIZE_ZIP"
  would xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait
fi

# -------- step 4: staple --------
log "step 4/6: staple"
if [[ "$DRY_RUN" -eq 1 || -z "${NOTARY_PROFILE:-}" ]]; then
  log "would run: xcrun stapler staple \"$APP_PATH\""
else
  would xcrun stapler staple "$APP_PATH"
  would xcrun stapler validate "$APP_PATH"
fi

# -------- step 5: DMG --------
log "step 5/6: package DMG"
# Use hdiutil (ships with macOS, no Homebrew dep). create-dmg is nicer but
# optional — fall back if present.
if command -v create-dmg >/dev/null 2>&1; then
  would create-dmg \
    --volname "$DMG_VOLNAME" \
    --app-drop-link 480 170 \
    --window-size 720 380 \
    "$DMG_PATH" \
    "$EXPORT_DIR"
else
  log "create-dmg not found — using hdiutil"
  would hdiutil create \
    -volname "$DMG_VOLNAME" \
    -srcfolder "$EXPORT_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  would codesign --sign "$CODESIGN_IDENTITY" --timestamp "$DMG_PATH"
fi

# -------- step 6: appcast stub --------
log "step 6/6: appcast"
DMG_LENGTH=0
SPARKLE_SIG=""
if [[ -f "$DMG_PATH" ]]; then
  DMG_LENGTH=$(stat -f%z "$DMG_PATH" 2>/dev/null || echo 0)
fi
if [[ -n "${SPARKLE_KEY_PATH:-}" && -f "$DMG_PATH" ]]; then
  if command -v sign_update >/dev/null 2>&1; then
    SPARKLE_SIG=$(sign_update "$DMG_PATH" -f "$SPARKLE_KEY_PATH" 2>/dev/null || echo "")
  else
    warn "sign_update not in PATH — install Sparkle's bin or pass the full path."
  fi
fi

PUBDATE=$(date "+%a, %d %b %Y %H:%M:%S %z")
cat >"$APPCAST_PATH" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Pixelbay</title>
    <link>${APPCAST_DOWNLOAD_URL:-https://example.com/pixelbay/appcast.xml}</link>
    <description>Pixelbay release feed</description>
    <language>en</language>
    <item>
      <title>Version ${VERSION}</title>
      <sparkle:releaseNotesLink>${RELEASE_NOTES_URL:-https://example.com/pixelbay/notes/v${VERSION}.html}</sparkle:releaseNotesLink>
      <pubDate>${PUBDATE}</pubDate>
      <enclosure
        url="${APPCAST_DOWNLOAD_URL:-https://example.com/pixelbay/Pixelbay-${VERSION}.dmg}"
        sparkle:version="${VERSION}"
        sparkle:shortVersionString="${VERSION}"
        length="${DMG_LENGTH}"
        type="application/octet-stream"
        ${SPARKLE_SIG} />
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
    </item>
  </channel>
</rss>
XML
log "appcast written: $APPCAST_PATH"

# -------- done --------
log "release-v0.1 finished ($([[ $DRY_RUN -eq 1 ]] && echo 'dry-run' || echo 'real'))"
log "artifacts (if real run): $DMG_PATH, $APPCAST_PATH"

# Trap cleans BUILD_DIR unless --keep was passed.
