#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/Scripts/package_macos_sdk.sh"
source "$ROOT/Scripts/package_product_paths.sh"

TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/codexbar-package-sdk.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT
SDK_PATH="$TEMP_DIR/SDK with spaces.sdk"
SDK_VERSION=27.0
SDK_PATH_STATUS=0
SDK_VERSION_STATUS=0
mkdir -p "$SDK_PATH"

xcrun() {
  case "$*" in
    '--sdk macosx --show-sdk-path') printf '%s\n' "$SDK_PATH"; return "$SDK_PATH_STATUS" ;;
    '--sdk macosx --show-sdk-version') printf '%s\n' "$SDK_VERSION"; return "$SDK_VERSION_STATUS" ;;
    *) echo "Unexpected xcrun invocation: $*" >&2; return 1 ;;
  esac
}

codexbar_configure_macos_sdk 14.0
swift() {
  local actual=("$@")
  local expected=(build --sdk "$SDK_PATH"
    -Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker 27.0
    -c release --arch arm64)
  [[ "${#actual[@]}" == "${#expected[@]}" ]]
  local i
  for ((i=0; i<${#expected[@]}; i++)); do
    [[ "${actual[$i]}" == "${expected[$i]}" ]]
  done
}
codexbar_build_macos_products -c release --arch arm64

# The query has eight arguments, independent of spaces in the SDK path.
# Keep failures observable even though SwiftPM is called in a command substitution.
swift() {
  [[ "$#" == 8 ]]
  [[ "$1" == build && "$2" == --show-bin-path && "$3" == -c && "$4" == release ]]
  [[ "$5" == --sdk && "$6" == "$SDK_PATH" && "$7" == --arch && "$8" == arm64 ]]
  printf '%s\n' "$TEMP_DIR/products"
}
[[ "$(codexbar_swiftpm_bin_path release arm64)" == "$TEMP_DIR/products" ]]

assert_configuration_fails() {
  if codexbar_configure_macos_sdk "$1" >"$TEMP_DIR/output" 2>"$TEMP_DIR/error"; then
    echo "ERROR: Invalid SDK configuration was accepted." >&2
    exit 1
  fi
  grep -Fq ERROR "$TEMP_DIR/error"
}

SDK_PATH_STATUS=1
assert_configuration_fails 14.0
SDK_PATH_STATUS=0
SDK_VERSION_STATUS=1
assert_configuration_fails 14.0
SDK_VERSION_STATUS=0
SDK_VERSION='27.0 unexpected'
assert_configuration_fails 14.0
SDK_VERSION=''
assert_configuration_fails 14.0
SDK_VERSION=27.0
assert_configuration_fails invalid
SDK_PATH="$TEMP_DIR/missing.sdk"
assert_configuration_fails 14.0

python3 - "$ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
package = (root / "Scripts/package_app.sh").read_text()
assert "codexbar_configure_macos_sdk 14.0" in package
assert "swift build -c" not in package
assert 'codexbar_build_macos_products -c "$CONF" --arch "$ARCH"' in package
assert 'Scripts/check_macos_sdk.py' in package
assert '<key>LSMinimumSystemVersion</key><string>14.0</string>' in package
assert '.macOS(.v14)' in (root / 'Package.swift').read_text()
PY

echo "macOS SDK packaging tests passed."
