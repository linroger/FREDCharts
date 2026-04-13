#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA_DIR="$ROOT_DIR/.build/DerivedData"
APP_NAME="FRED-Ultra"
SCHEME="FRED-Ultra"
PROJECT="$ROOT_DIR/FRED-Ultra.xcodeproj"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/Debug/${APP_NAME}.app"

kill_existing() {
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    pkill -x "$APP_NAME"
    sleep 1
  fi
}

build_app() {
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -sdk macosx \
    build
}

launch_app() {
  if [[ ! -d "$APP_PATH" ]]; then
    echo "Built app not found at $APP_PATH" >&2
    exit 1
  fi

  /usr/bin/open -n "$APP_PATH"
}

stream_logs() {
  /usr/bin/log stream --style compact --predicate "process == \"$APP_NAME\""
}

verify_launch() {
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "$APP_NAME launched successfully."
  else
    echo "$APP_NAME did not appear to launch." >&2
    exit 1
  fi
}

main() {
  local mode="${1:-}"

  cd "$ROOT_DIR"
  kill_existing
  build_app
  launch_app

  case "$mode" in
    --logs|--telemetry)
      stream_logs
      ;;
    --verify)
      sleep 2
      verify_launch
      ;;
    --debug)
      echo "Use Xcode or lldb directly for interactive debugging. This script built and launched the app." >&2
      ;;
    "")
      ;;
    *)
      echo "Unknown option: $mode" >&2
      echo "Supported options: --logs, --telemetry, --verify, --debug" >&2
      exit 1
      ;;
  esac
}

main "$@"
