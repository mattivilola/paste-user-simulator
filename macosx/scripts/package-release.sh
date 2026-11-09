#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

: "${SIGNING_IDENTITY:?Set the Developer ID Application identity}"
: "${DEVELOPMENT_TEAM:?Set the Apple Developer team ID}"
: "${NOTARY_KEYCHAIN_PROFILE:?Set the notarytool Keychain profile}"
: "${SPARKLE_TOOLS:?Set the absolute path to the Sparkle release bin directory}"
: "${SPARKLE_KEYCHAIN_ACCOUNT:?Set the Sparkle signing Keychain account}"

xcodebuild -project PasteUserSimulator.xcodeproj -scheme PasteUserSimulator \
    -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath .build/xcode -clonedSourcePackagesDirPath .build/packages \
    ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
    CODE_SIGNING_ALLOWED=NO build

app="$PWD/.build/xcode/Build/Products/Release/Paste User Simulator.app"
plist="$app/Contents/Info.plist"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")"
feed="$(/usr/libexec/PlistBuddy -c 'Print SUFeedURL' "$plist")"
public_key="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$plist")"
actual_key="$("$SPARKLE_TOOLS/generate_keys" --account "$SPARKLE_KEYCHAIN_ACCOUNT" -p)"
[[ "$actual_key" == "$public_key" ]]
[[ "$feed" == https://*/releases/latest/download/appcast.xml ]]

output="$PWD/dist/v$version"
[[ ! -e "$output" ]]

# Xcode's ordinary build does not timestamp signatures, and the Sparkle
# Swift package ships its nested tools ad hoc signed. Sign inside out.
framework="$app/Contents/Frameworks/Sparkle.framework/Versions/Current"
for component in "$framework/Autoupdate" "$framework/Updater.app" \
    "$framework"/XPCServices/*.xpc "$framework" "$app"; do
    codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" \
        --preserve-metadata=identifier,entitlements "$component"
done
codesign --verify --deep --strict "$app"
for arch in arm64 x86_64; do
    lipo -verify_arch "$arch" "$app/Contents/MacOS/Paste User Simulator"
done

submission="$(mktemp -d)"
trap 'rm -rf "$submission"' EXIT
ditto -c -k --keepParent "$app" "$submission/submission.zip"
xcrun notarytool submit "$submission/submission.zip" --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait --output-format json > "$submission/notary.json"
if ! jq -e '.status == "Accepted"' "$submission/notary.json" > /dev/null; then
    jq '{id, status, message}' "$submission/notary.json" >&2
    exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
codesign --verify --deep --strict "$app"
spctl --assess --type execute --verbose "$app"

archive="Paste-User-Simulator-v$version-macOS.zip"
mkdir -p dist
mkdir "$output"
ditto -c -k --keepParent "$app" "$output/$archive"
release_url="${feed%/releases/latest/download/appcast.xml}/releases/download/v$version/"
"$SPARKLE_TOOLS/generate_appcast" --account "$SPARKLE_KEYCHAIN_ACCOUNT" \
    --maximum-deltas 0 --download-url-prefix "$release_url" "$output"
printf '\nRelease assets staged in %s\n' "$output"
