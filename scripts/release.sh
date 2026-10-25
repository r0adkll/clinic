#!/usr/bin/env bash
# Builds a Developer ID-signed, notarized Clinic.app (ADR-010, ADR-153). Requires:
#   - Local.xcconfig with DEVELOPMENT_TEAM
#   - a "Developer ID Application" certificate in the login keychain (Xcode > Settings > Accounts > Manage Certificates)
#   - notarytool credentials stored once:  xcrun notarytool store-credentials clinic-notary --apple-id <id> --team-id <team> --password <app-specific-password>
# The version comes from Version.xcconfig (semver); the build number is the commit count on HEAD.
# Publishing the result (smoke test, tag, GitHub Release, Homebrew cask) is scripts/publish, which runs this.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=version.sh
. scripts/version.sh
OUT="$ROOT/build/release"
rm -rf "$OUT"; mkdir -p "$OUT"
[ -f Local.xcconfig ] || { echo "error: Local.xcconfig missing (copy Local.xcconfig.example)" >&2; exit 1; }
[ -d Packages/GhosttyBridge/GhosttyKit.xcframework ] || scripts/build-ghostty.sh
echo "building Clinic $VERSION ($BUILD)"
xcodegen generate >/dev/null
xcodebuild -project Clinic.xcodeproj -scheme Clinic -configuration Release -skipPackagePluginValidation -skipMacroValidation \
  CURRENT_PROJECT_VERSION="$BUILD" -archivePath "$OUT/Clinic.xcarchive" archive | tail -5
cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/Clinic.xcarchive" -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT/export" | tail -3
APP="$OUT/export/Clinic.app"
built="$(defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString)"
[ "$built" = "$VERSION" ] || { echo "error: built app reports $built, Version.xcconfig says $VERSION" >&2; exit 1; }
if find "$APP" -iname '*shell-integration*' | grep -q .; then echo "error: GPL shell-integration files in the bundle" >&2; exit 1; fi
ZIP="$OUT/Clinic-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile clinic-notary --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
spctl -a -vv "$APP" 2>&1 | tail -2
# The build's debug symbols, published beside the app (ADR-231): a crash report, a MetricKit payload or a crash
# dump from this build can only be read with the dSYM whose UUID matches its binary.
DSYMS="$OUT/Clinic-$VERSION-dSYMs.zip"
app_uuid="$(dwarfdump --uuid "$APP/Contents/MacOS/Clinic" | awk '{print $2}')"
dsym_uuid="$(dwarfdump --uuid "$OUT/Clinic.xcarchive/dSYMs/Clinic.app.dSYM" | awk '{print $2}')"
[ -n "$app_uuid" ] && [ "$app_uuid" = "$dsym_uuid" ] || { echo "error: Clinic.app.dSYM ($dsym_uuid) does not match the exported app ($app_uuid)" >&2; exit 1; }
ditto -c -k --norsrc --noextattr --noacl --keepParent "$OUT/Clinic.xcarchive/dSYMs" "$DSYMS"
echo "release artifact: $ZIP"
echo "debug symbols: $DSYMS (Clinic $app_uuid)"
echo "next: make publish  (walks through the smoke test, tag, GitHub Release and cask; pass --reuse-build to keep this zip)"
