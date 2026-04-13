#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

echo "==> Building FRED-Ultra"
xcodebuild -project FRED-Ultra.xcodeproj -scheme FRED-Ultra -sdk macosx build

echo "==> Running tests"
xcodebuild -project FRED-Ultra.xcodeproj -scheme FRED-Ultra -sdk macosx test
