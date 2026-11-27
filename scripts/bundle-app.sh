#!/usr/bin/env bash
set -euo pipefail

# Usage: scripts/bundle-app.sh [--dev]
#   --dev  Builds "Agent Quota Bar Dev.app" with its own bundle ID, UserDefaults,
#          Application Support folder, and login item, so it can run beside another build.

VARIANT="release"
for arg in "$@"; do
  case "$arg" in
    --dev) VARIANT="dev" ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="AgentQuotaBar"
BUNDLE_NAME="Agent Quota Bar"
BUNDLE_ID="com.agentquotabar.app"
SUPPORT_DIR_NAME=""
if [ "$VARIANT" = "dev" ]; then
  BUNDLE_NAME="Agent Quota Bar Dev"
  BUNDLE_ID="com.agentquotabar.app.dev"
  SUPPORT_DIR_NAME="AgentQuotaBar-Dev"
fi
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
cp "$ROOT_DIR/Sources/${APP_NAME}/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

if [ "$VARIANT" = "dev" ]; then
  PLIST="$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $BUNDLE_NAME" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $BUNDLE_NAME" "$PLIST"
  /usr/libexec/PlistBuddy -c "Add :AgentQuotaBarSupportDirectoryName string $SUPPORT_DIR_NAME" "$PLIST"
fi

if [ -d "$RESOURCE_BUNDLE" ]; then
  cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/"
fi

codesign --force --sign - "$BUNDLE_DIR"

echo "Built $BUNDLE_DIR ($BUNDLE_ID)"
