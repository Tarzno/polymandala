#!/bin/zsh
# Builds an arm64 (Apple silicon) release binary and assembles a macOS app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
# Ask SwiftPM where the product landed rather than hardcoding the directory:
# it differs between toolchains and build modes, and a wrong guess silently
# packages whatever stale binary an earlier build left behind.
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Polymandala"

# The License window shows a copy of the license compiled into the binary;
# never ship a bundle whose copy differs from the LICENSE file.
if ! "$BIN" --license | diff -q - LICENSE >/dev/null; then
    echo "error: LICENSE differs from License.text in Sources/Polymandala/UI/LicenseWindowController.swift" >&2
    exit 1
fi

APP="dist/Polymandala.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Support/Info.plist "$APP/Contents/"
cp "$BIN" "$APP/Contents/MacOS/Polymandala"
# Release builds keep debug-map entries with the absolute paths of the build
# machine (object files and source folders, including the user name). The
# shipped binary needs none of them.
strip -S "$APP/Contents/MacOS/Polymandala"
if LC_ALL=C grep -q "$HOME" "$APP/Contents/MacOS/Polymandala"; then
    echo "error: the app binary still contains paths under $HOME" >&2
    exit 1
fi
if [ -f Support/AppIcon.icns ]; then
    cp Support/AppIcon.icns "$APP/Contents/Resources/"
fi
codesign --force --sign - "$APP"
echo -n "Architectures: "
lipo -archs "$APP/Contents/MacOS/Polymandala"
echo "Built $APP"
