#!/usr/bin/env bash
# Builds a Developer ID-signed, notarized Clinic.app (ADR-010). Requires:
#   - Local.xcconfig with DEVELOPMENT_TEAM
#   - a "Developer ID Application" certificate in the login keychain (Xcode > Settings > Accounts > Manage Certificates)
#   - notarytool credentials stored once:  xcrun notarytool store-credentials clinic-notary --apple-id <id> --team-id <team> --password <app-specific-password>
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
VERSION="${1:-$(sed -nE 's/.*MARKETING_VERSION: "([^"]+)".*/\1/p' project.yml | head -1)}"
OUT="$ROOT/build/release"
rm -rf "$OUT"; mkdir -p "$OUT"
[ -f Local.xcconfig ] || { echo "error: Local.xcconfig missing (copy Local.xcconfig.example)" >&2; exit 1; }
[ -d Packages/GhosttyBridge/GhosttyKit.xcframework ] || scripts/build-ghostty.sh
xcodegen generate >/dev/null
xcodebuild -project Clinic.xcodeproj -scheme Clinic -configuration Release -skipPackagePluginValidation -skipMacroValidation -archivePath "$OUT/Clinic.xcarchive" archive | tail -5
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
ZIP="$OUT/Clinic-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile clinic-notary --wait
xcrun stapler staple "$APP"
rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
spctl -a -vv "$APP" 2>&1 | tail -2
echo "release artifact: $ZIP"
