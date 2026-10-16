#!/bin/sh
# Builds the Go helper (ternd) as a universal macOS binary into ternd/bin/ternd.
# Xcode copies that file into Tern.app/Contents/MacOS so it is signed with the app.
set -e
cd "$(dirname "$0")/../ternd"
mkdir -p bin
OUT="$(pwd)/bin"
export CGO_ENABLED=0
GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o "$OUT/ternd-arm64" .
GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o "$OUT/ternd-amd64" .
lipo -create -output "$OUT/ternd" "$OUT/ternd-arm64" "$OUT/ternd-amd64"
rm "$OUT/ternd-arm64" "$OUT/ternd-amd64"
echo "ternd -> $OUT/ternd ($(du -h "$OUT/ternd" | cut -f1))"
