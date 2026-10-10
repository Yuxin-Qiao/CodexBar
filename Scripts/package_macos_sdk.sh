#!/usr/bin/env bash

codexbar_configure_macos_sdk() {
  CODEXBAR_MACOS_MINIMUM_VERSION="$1"
  if ! CODEXBAR_MACOS_SDK_PATH=$(xcrun --sdk macosx --show-sdk-path); then
    echo "ERROR: Cannot resolve the selected macOS SDK path." >&2
    return 1
  fi
  if [[ ! -d "$CODEXBAR_MACOS_SDK_PATH" ]]; then
    echo "ERROR: Selected macOS SDK directory does not exist: $CODEXBAR_MACOS_SDK_PATH" >&2
    return 1
  fi
  if ! CODEXBAR_MACOS_SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version); then
    echo "ERROR: Cannot resolve the selected macOS SDK version." >&2
    return 1
  fi
  local version
  for version in "$CODEXBAR_MACOS_MINIMUM_VERSION" "$CODEXBAR_MACOS_SDK_VERSION"; do
    if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
      echo "ERROR: Invalid macOS deployment or SDK version: $version" >&2
      return 1
    fi
  done

  # SwiftBuild can record the deployment target as the linked SDK even when it
  # compiles against the selected SDK. Supply both versions to the linker.
  CODEXBAR_MACOS_BUILD_ARGS=(
    --sdk "$CODEXBAR_MACOS_SDK_PATH"
    -Xlinker -platform_version
    -Xlinker macos
    -Xlinker "$CODEXBAR_MACOS_MINIMUM_VERSION"
    -Xlinker "$CODEXBAR_MACOS_SDK_VERSION"
  )
}

codexbar_build_macos_products() {
  swift build "${CODEXBAR_MACOS_BUILD_ARGS[@]}" "$@"
}
