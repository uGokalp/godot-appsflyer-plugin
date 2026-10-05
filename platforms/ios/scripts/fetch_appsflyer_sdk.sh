#!/bin/bash
set -euo pipefail

AF_VERSION="7.0.2"
AF_SHA256="a68a8f23d410963b95dde8d865559cfc731410303ec597a2ffc89ad118338fa3"
IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$IOS_DIR/vendor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/af.zip" "https://github.com/AppsFlyerSDK/AppsFlyerFramework/releases/download/${AF_VERSION}/AppsFlyerLib-Binaries.zip"
echo "$AF_SHA256  $WORK/af.zip" | shasum -a 256 -c -
unzip -q "$WORK/af.zip" -d "$WORK"
FULL="$WORK/binaries/xcframework/full/AppsFlyerLib.xcframework"

rm -rf "$VENDOR"
mkdir -p "$VENDOR/AppsFlyerLib_Privacy.bundle"
xcodebuild -create-xcframework \
	-framework "$FULL/ios-arm64/AppsFlyerLib.framework" \
	-framework "$FULL/ios-arm64_x86_64-simulator/AppsFlyerLib.framework" \
	-output "$VENDOR/AppsFlyerLib.xcframework" >/dev/null
cp "$WORK/binaries/Resources/nonStrict/PrivacyInfo.xcprivacy" "$VENDOR/AppsFlyerLib_Privacy.bundle/"
echo "$AF_VERSION" > "$VENDOR/VERSION"
echo "AppsFlyerLib $AF_VERSION (static, iOS slices only) -> $VENDOR"
