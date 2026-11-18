#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AgentQuotaBar"
BUNDLE_NAME="Agent Quota Bar"
BUNDLE_DIR="$ROOT_DIR/dist/${BUNDLE_NAME}.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MACOS_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"

cd "$ROOT_DIR"
# Clang uses -isysroot to record the SDK version macOS uses for system UI compatibility.
swift build -c release \
  -Xswiftc -Xclang-linker -Xswiftc -isysroot \
  -Xswiftc -Xclang-linker -Xswiftc "$MACOS_SDK_PATH"

BUILD_DIR="$(swift build -c release --show-bin-path)"
BIN_PATH="$BUILD_DIR/${APP_NAME}"
RESOURCE_BUNDLE="$BUILD_DIR/agent-quota-bar_${APP_NAME}.bundle"

rm -rf "$BUNDLE_DIR" "$ROOT_DIR/dist/${APP_NAME}.app"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/${APP_NAME}"
cp "$ROOT_DIR/Sources/${APP_NAME}/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

codesign --force --sign - "$BUNDLE_DIR"

echo "Built $BUNDLE_DIR"
