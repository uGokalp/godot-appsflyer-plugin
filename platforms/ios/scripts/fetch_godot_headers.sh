#!/bin/bash
set -euo pipefail

GODOT_VERSION="${GODOT_VERSION:-4.7.2}"
IOS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$IOS_DIR/include/godot"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/godot-${GODOT_VERSION}-stable.tar.xz" | tar -xJ -C "$WORK"
SRC="$WORK/godot-${GODOT_VERSION}-stable"

(cd "$SRC" && PYTHONWARNINGS="ignore::SyntaxWarning" scons platform=ios target=template_release \
	core/version_generated.gen.h \
	core/disabled_classes.gen.h \
	core/object/gdvirtual.gen.h \
	core/extension/gdextension_interface.gen.h \
	core/extension/ext_wrappers.gen.h \
	modules/modules_enabled.gen.h >/dev/null)

rm -rf "$DEST"
mkdir -p "$DEST"
rsync -a --prune-empty-dirs --include='*/' --include='*.h' --include='*.inc' --exclude='*' "$SRC/" "$DEST/"
echo "$GODOT_VERSION" > "$DEST.version"
echo "Godot $GODOT_VERSION headers -> $DEST"
