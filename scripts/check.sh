#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
bash -n scripts/build.sh scripts/install.sh scripts/check.sh
python3 -m unittest discover -s tests -v
mkdir -p dist
xcrun --sdk macosx swiftc -O \
  Sources/DeviceConfiguration.swift Sources/Audio.swift Sources/ManagerCore.swift \
  tests/swift/main.swift -framework Cocoa -framework CoreAudio \
  -framework ApplicationServices -o dist/profile-tests
dist/profile-tests
./scripts/build.sh
