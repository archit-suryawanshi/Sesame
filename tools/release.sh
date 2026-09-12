#!/bin/bash
#
# Builds, signs, notarizes and staples a distributable Sesame.dmg.
#
# Prerequisites, both one-time:
#
#   1. A "Developer ID Application" certificate. Xcode > Settings > Apple Accounts >
#      Manage Certificates > + > Developer ID Application. The Apple Development and Apple
#      Distribution certificates cannot notarize; only Developer ID can.
#
#   2. Notarization credentials stored in the keychain, so nothing secret lands in this script,
#      the repo, or a shell history:
#
#        xcrun notarytool store-credentials "Sesame" \
#          --apple-id "you@example.com" --team-id UG9NU2M9J3 --password <app-specific-password>
#
#      An app-specific password is generated at appleid.apple.com, not your Apple ID password.
#      Alternatively use --key/--key-id/--issuer for an App Store Connect API key.
#
# Usage:  tools/release.sh [keychain-profile]
#         SKIP_NOTARIZE=1 tools/release.sh     # build and sign only, no submission
#
set -euo pipefail

PROFILE="${1:-Sesame}"
SCHEME="Sesame"
APP="Sesame.app"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build/release"
DMG="$BUILD/Sesame.dmg"

cd "$ROOT"

say() { printf "\n\033[1m==> %s\033[0m\n" "$1"; }

say "Checking for a Developer ID Application certificate"
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  cat >&2 <<'MSG'
No "Developer ID Application" certificate found.

Notarization requires one; Apple Development and Apple Distribution certificates will not do.
Create it in Xcode > Settings > Apple Accounts > Manage Certificates > + > Developer ID Application,
then run this again. The option only appears for the team's Account Holder.
MSG
  exit 1
fi
security find-identity -v -p codesigning | grep "Developer ID Application"

say "Archiving"
rm -rf "$BUILD"
mkdir -p "$BUILD"
xcodebuild -project Sesame.xcodeproj -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$BUILD/Sesame.xcarchive" \
  -allowProvisioningUpdates \
  archive

say "Exporting with Developer ID"
cat > "$BUILD/ExportOptions.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>UG9NU2M9J3</string>
	<key>signingStyle</key>
	<string>automatic</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
  -archivePath "$BUILD/Sesame.xcarchive" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -exportPath "$BUILD/export" \
  -allowProvisioningUpdates

say "Building the disk image"
STAGE="$BUILD/stage"
mkdir -p "$STAGE"
cp -R "$BUILD/export/$APP" "$STAGE/"
# A symlink to /Applications makes the window a drag-and-drop install.
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Sesame" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

say "Signing the disk image"
# The DMG is signed too: notarization staples to the container, and an unsigned container makes
# Gatekeeper fall back to quarantine prompts even when the app inside is fine.
IDENTITY="$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

if [ "${SKIP_NOTARIZE:-0}" = "1" ]; then
  say "SKIP_NOTARIZE=1 — stopping with a signed but un-notarized disk image"
  echo "$DMG"
  echo
  echo "Gatekeeper will still warn on this one. To finish it, store credentials once:"
  echo "  xcrun notarytool store-credentials \"$PROFILE\" --apple-id <your-apple-id> --team-id UG9NU2M9J3 --password <app-specific-password>"
  echo "then re-run without SKIP_NOTARIZE."
  exit 0
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  cat >&2 <<MSG

No notarization credentials stored under the keychain profile "$PROFILE".

Create an app-specific password at appleid.apple.com (Sign-In and Security > App-Specific
Passwords) — not your Apple ID password — then run, once:

  xcrun notarytool store-credentials "$PROFILE" \\
    --apple-id <your-apple-id> --team-id UG9NU2M9J3 --password <app-specific-password>

That writes the credential into your login keychain. Nothing is stored in this repo.
MSG
  exit 1
fi

say "Submitting for notarization (this waits for Apple, usually a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

say "Stapling the ticket"
xcrun stapler staple "$DMG"

say "Verifying as Gatekeeper sees it"
xcrun stapler validate "$DMG"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

say "Done"
echo "$DMG"
