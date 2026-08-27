#!/bin/zsh
# Resolves a usable Xcode toolchain and exports DEVELOPER_DIR + XCODEBUILD.
#
# `xcodebuild` fails outright when the active developer directory points at the
# Command Line Tools instead of a full Xcode, which is a common local setup. Rather
# than requiring `sudo xcode-select`, every script sources this and finds Xcode itself.

resolve_xcode() {
  local candidate

  if [[ -n "${DEVELOPER_DIR:-}" && -x "${DEVELOPER_DIR}/usr/bin/xcodebuild" ]]; then
    export XCODEBUILD="${DEVELOPER_DIR}/usr/bin/xcodebuild"
    return 0
  fi

  candidate="$(xcode-select -p 2>/dev/null || true)"
  if [[ -n "$candidate" && -x "${candidate}/usr/bin/xcodebuild" ]]; then
    export DEVELOPER_DIR="$candidate"
    export XCODEBUILD="${candidate}/usr/bin/xcodebuild"
    return 0
  fi

  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app /Applications/Xcode*.app; do
    if [[ -x "${candidate}/Contents/Developer/usr/bin/xcodebuild" ]]; then
      export DEVELOPER_DIR="${candidate}/Contents/Developer"
      export XCODEBUILD="${candidate}/Contents/Developer/usr/bin/xcodebuild"
      return 0
    fi
  done

  cat >&2 <<'MSG'
error: no full Xcode installation was found.

xcodebuild needs Xcode, not just the Command Line Tools. Install Xcode, then either:
  sudo xcode-select -s /Applications/Xcode.app
or run these scripts with an explicit toolchain:
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./init.sh
MSG
  return 1
}

resolve_xcode
