#!/bin/sh
set -eu
# Run from the project root after SwiftPM has resolved the pinned dependencies.
destination="${1:?Usage: bundle-simulator-notices.sh <destination>}"
mkdir -p "$destination"
install -m 644 Resources/ThirdPartyNotices/Simulator.txt "$destination/Simulator.txt"
for package in swift-nio swift-atomics swift-collections swift-system; do
    install -m 644 ".build/checkouts/$package/LICENSE.txt" "$destination/$package-LICENSE.txt"
done
install -m 644 .build/checkouts/swift-nio/NOTICE.txt "$destination/swift-nio-NOTICE.txt"
install -m 644 .build/checkouts/swift-nio/Sources/CNIOLLHTTP/LICENSE "$destination/llhttp-LICENSE.txt"
