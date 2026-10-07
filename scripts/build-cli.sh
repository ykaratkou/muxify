#!/bin/sh
set -eu
destination="${1:?Usage: build-cli.sh <destination> [debug|release]}"
configuration="${2:-debug}"
swift build -c "$configuration" --product muxify
binary_directory=$(swift build -c "$configuration" --show-bin-path)
mkdir -p "$destination"
# Replace the inode so macOS cannot reuse a cached signature for an older build.
cp "$binary_directory/muxify" "$destination/muxify.new"
codesign --force --sign - "$destination/muxify.new"
mv -f "$destination/muxify.new" "$destination/muxify"
# Older builds distributed the Simulator as a separate helper executable.
rm -f -- "$destination/muxify-simulator"
