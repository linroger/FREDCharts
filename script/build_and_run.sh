#!/bin/zsh
# Build FRED-Ultra and launch it, optionally streaming logs or verifying the launch.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

source "$ROOT_DIR/script/xcode-env.sh"

APP_NAME="FRED-Ultra"
SCHEME="FRED-Ultra"
PROJECT="$ROOT_DIR/FRED-Ultra.xcodeproj"
DERIVED_DATA_DIR="$ROOT_DIR/.build/DerivedData"
APP_PATH="$DERIVED_DATA_DIR/Build/Products/Debug/${APP_NAME}.app"

usage() {
  cat <<'MSG'
Usage: script/build_and_run.sh [option]

  (no option)  Build and launch the app.
  --verify     Build, launch, and confirm the process is running.
  --logs       Build, launch, and stream unified logs for the app.
  --build-only Build without launching.
  --help       Show this message.
MSG
}

kill_existing() {
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    pkill -x "$APP_NAME" || true
    sleep 1
  fi
}

build_app() {
  "$XCODEBUILD" \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    -destination 'platform=macOS' \
    build
}

launch_app() {
  if [[ ! -d "$APP_PATH" ]]; then
    echo "error: built app not found at $APP_PATH" >&2
    exit 1
  fi
  /usr/bin/open -n "$APP_PATH"
}

verify_launch() {
  local attempt=0
  while (( attempt < 20 )); do
    if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
      echo "$APP_NAME launched successfully."
      return 0
    fi
    sleep 0.5
    (( attempt += 1 ))
  done

  echo "error: $APP_NAME did not appear to launch." >&2
  exit 1
}

main() {
  local mode="${1:-}"

  case "$mode" in
    --help|-h)
      usage
      return 0
      ;;
    --build-only)
      kill_existing
      build_app
      return 0
      ;;
    ""|--verify|--logs|--telemetry)
      ;;
    *)
      echo "error: unknown option: $mode" >&2
      usage >&2
      exit 1
      ;;
  esac

  kill_existing
  build_app
  launch_app

  case "$mode" in
    --logs|--telemetry)
      /usr/bin/log stream --style compact --predicate "process == \"$APP_NAME\""
      ;;
    --verify)
      verify_launch
      ;;
  esac
}

main "$@"
