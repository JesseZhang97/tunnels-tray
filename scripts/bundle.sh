#!/usr/bin/env bash
# Build Tunnels in release mode and assemble build/Tunnels.app (ad-hoc signed).
#   ./scripts/bundle.sh              native architecture only
#   ./scripts/bundle.sh --universal  arm64 + x86_64
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Tunnels.app"

if [[ "${1:-}" == "--universal" ]]; then
    if swift build -c release --product Tunnels --arch arm64 --arch x86_64; then
        BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Tunnels"
    else
        echo "Universal build failed; building each architecture and merging with lipo." >&2
        for arch in arm64 x86_64; do
            swift build -c release --product Tunnels --triple "$arch-apple-macosx14.0"
        done
        mkdir -p build
        lipo -create -output build/Tunnels-universal \
            "$(swift build -c release --triple arm64-apple-macosx14.0 --show-bin-path)/Tunnels" \
            "$(swift build -c release --triple x86_64-apple-macosx14.0 --show-bin-path)/Tunnels"
        BIN="build/Tunnels-universal"
    fi
else
    swift build -c release --product Tunnels
    BIN="$(swift build -c release --show-bin-path)/Tunnels"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tunnels"
cp Support/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "Built $(pwd)/$APP"
