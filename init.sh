#!/bin/zsh
# Project health check: build the app and run the full test suite.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"

source "$ROOT_DIR/script/xcode-env.sh"

PROJECT="$ROOT_DIR/FRED-Ultra.xcodeproj"
SCHEME="FRED-Ultra"
DERIVED_DATA_DIR="$ROOT_DIR/.build/DerivedData"

echo "==> Using $(basename "$(dirname "$(dirname "$DEVELOPER_DIR")")") ($("$XCODEBUILD" -version | head -1))"

echo "==> Building FRED-Ultra"
"$XCODEBUILD" \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -destination 'platform=macOS' \
  build

echo "==> Running unit tests"
"$XCODEBUILD" \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -destination 'platform=macOS' \
  -only-testing:FRED-UltraTests \
  test

# The UI test target drives the real app through XCUITest, which requires the test
# runner to hold Accessibility authorization. That cannot be granted from a script, and
# without it the runner fails with "Authentication canceled" before any test executes.
# It is therefore opt-in rather than silently skipped, so a green default run always
# means the tests it claims to have run actually ran.
if [[ "${1:-}" == "--with-ui-tests" ]]; then
  echo "==> Running UI tests (requires Accessibility authorization for the test runner)"
  "$XCODEBUILD" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -destination 'platform=macOS' \
    -only-testing:FRED-UltraUITests \
    test
else
  echo "==> Skipping UI tests (pass --with-ui-tests to include them)"
fi

echo "==> OK: build and tests passed"
