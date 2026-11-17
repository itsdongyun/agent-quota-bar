#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AgentQuotaBar"
BUNDLE_DIR="$ROOT_DIR/dist/${APP_NAME}.app"
CONTENTS_DIR="$BUNDLE_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$ROOT_DIR"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${APP_NAME}"
RESOURCE_BUNDLE="$(swift build -c release --show-bin-path)/agent-quota-bar_${APP_NAME}.bundle"

rm -rf "$BUNDLE_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/${APP_NAME}"
cp "$ROOT_DIR/Sources/${APP_NAME}/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"

if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

codesign --force --sign - "$BUNDLE_DIR"

echo "Built $BUNDLE_DIR"
