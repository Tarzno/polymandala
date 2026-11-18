#!/bin/zsh
# Builds the arm64 (Apple silicon) Polymandala screensaver bundle:
# dist/PolymandalaSaver.saver. The saver shares the app's engine sources and is
# compiled directly with swiftc (SwiftPM has no loadable-bundle product type).
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCES=(
    Sources/Polymandala/Model/Operations.swift
    Sources/Polymandala/Engine/SymmetryEngine.swift
    Sources/Polymandala/Engine/FloodFill.swift
    Sources/Polymandala/Engine/RasterLayer.swift
    Sources/Polymandala/Engine/PolymandalaGenerator.swift
    Saver/PolymandalaSaverView.swift
)

BUILD=".build/saver"
mkdir -p "$BUILD"
swiftc -O -parse-as-library \
    -module-name PolymandalaSaver \
    -target arm64-apple-macos13 \
    -framework ScreenSaver \
    -emit-library -o "$BUILD/PolymandalaSaver" \
    "${SOURCES[@]}"

SAVER="dist/PolymandalaSaver.saver"
rm -rf "$SAVER"
mkdir -p "$SAVER/Contents/MacOS"
cp Support/Info-Saver.plist "$SAVER/Contents/Info.plist"
cp "$BUILD/PolymandalaSaver" "$SAVER/Contents/MacOS/PolymandalaSaver"
codesign --force --sign - "$SAVER"
echo -n "Architectures: "
lipo -archs "$SAVER/Contents/MacOS/PolymandalaSaver"
echo "Built $SAVER"
