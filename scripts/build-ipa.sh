#!/usr/bin/env bash
# Builds an unsigned IPA for sideloading (AltStore, SideStore, Sideloadly).
#
# Usage: scripts/build-ipa.sh [version] [build-number]
#   version       marketing version, e.g. 0.2.0 (default: value in the Xcode project)
#   build-number  CFBundleVersion (default: 1)
# Output: build/ipa/JellyfinClient-<version>-unsigned.ipa (path is printed on the last line)
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-}"
BUILD_NUMBER="${2:-1}"
DERIVED="build/release"
OUT="build/ipa"

overrides=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
if [[ -n "$VERSION" ]]; then
  overrides+=(MARKETING_VERSION="$VERSION")
fi

xcodebuild \
  -project JellyfinClient.xcodeproj \
  -scheme JellyfinClient \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -quiet \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  "${overrides[@]}" \
  build

APP="$DERIVED/Build/Products/Release-iphoneos/JellyfinClient.app"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$APP/Info.plist")"
IPA_NAME="JellyfinClient-${APP_VERSION}-unsigned.ipa"

rm -rf "$OUT"
mkdir -p "$OUT/Payload"
cp -R "$APP" "$OUT/Payload/"
(cd "$OUT" && zip -qry "$IPA_NAME" Payload && rm -rf Payload)

shasum -a 256 "$OUT/$IPA_NAME" | awk '{print $1}' > "$OUT/$IPA_NAME.sha256"
echo "$OUT/$IPA_NAME"
