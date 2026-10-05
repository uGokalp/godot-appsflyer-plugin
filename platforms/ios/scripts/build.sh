#!/bin/bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$IOS_DIR/../.." && pwd)"
HEADERS="$IOS_DIR/include/godot"
VENDOR="$IOS_DIR/vendor"
OUT="$IOS_DIR/bin"
DEST="$ROOT/platforms/godot_editor/ios/plugins/appsflyer"
PRODUCT="AppsFlyerGodotPlugin"
MIN_IOS="14.0"

[ -d "$HEADERS" ] || "$IOS_DIR/scripts/fetch_godot_headers.sh"
[ -d "$VENDOR/AppsFlyerLib.xcframework" ] || "$IOS_DIR/scripts/fetch_appsflyer_sdk.sh"

compile() {
	local sdk="$1" slice="$2" defines="$3" output="$4"
	shift 4
	local arch_flags=() arch
	for arch in "$@"; do arch_flags+=(-arch "$arch"); done
	local target_flag="-mios-version-min=$MIN_IOS"
	[ "$sdk" = iphonesimulator ] && target_flag="-mios-simulator-version-min=$MIN_IOS"

	xcrun -sdk "$sdk" clang++ -c "$IOS_DIR/src/$PRODUCT.mm" -o "$output.o" \
		"${arch_flags[@]}" "$target_flag" \
		-std=gnu++17 -fobjc-arc -fno-exceptions -O2 \
		$defines -DTHREADS_ENABLED -DIOS_ENABLED -DAPPLE_EMBEDDED_ENABLED -DUNIX_ENABLED \
		-I"$HEADERS" -I"$HEADERS/platform/ios" \
		-F"$VENDOR/AppsFlyerLib.xcframework/$slice"
	xcrun libtool -static -o "$output.a" "$output.o"
	rm "$output.o"
}

rm -rf "$OUT"
mkdir -p "$OUT" "$DEST"

for config in debug release; do
	defines="-DNDEBUG"
	[ "$config" = debug ] && defines="-DDEBUG_ENABLED"

	compile iphoneos ios-arm64 "$defines" "$OUT/$config-device" arm64
	compile iphonesimulator ios-arm64_x86_64-simulator "$defines" "$OUT/$config-simulator" arm64 x86_64

	xcodebuild -create-xcframework \
		-library "$OUT/$config-device.a" \
		-library "$OUT/$config-simulator.a" \
		-output "$OUT/$PRODUCT.$config.xcframework" >/dev/null
	rm -rf "$DEST/$PRODUCT.$config.xcframework"
	cp -R "$OUT/$PRODUCT.$config.xcframework" "$DEST/"
done

rm -rf "$DEST/$PRODUCT.xcframework" "$DEST/AppsFlyerLib.xcframework" "$DEST/AppsFlyerLib_Privacy.bundle"
cp -R "$VENDOR/AppsFlyerLib.xcframework" "$VENDOR/AppsFlyerLib_Privacy.bundle" "$DEST/"
cp "$IOS_DIR/$PRODUCT.gdip" "$DEST/"
touch "$DEST/.gdignore"
echo "Plugin -> $DEST"
