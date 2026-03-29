#!/usr/bin/env bash
set -euo pipefail

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  NC='\033[0m'
else
  RED=''
  GREEN=''
  YELLOW=''
  NC=''
fi

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
GO_BUILD_DIR="$BUILD_DIR/go"
BRIDGE_DIR="$PROJECT_ROOT/Sources/Bridge"
ARCHIVE_PATH="$BUILD_DIR/VKTurnProxy.xcarchive"
IPA_PATH="$BUILD_DIR/VKTurnProxy.ipa"

error() {
  printf "%b\n" "${RED}ERROR:${NC} $1" >&2
  exit 1
}

info() {
  printf "%b\n" "${GREEN}[INFO]${NC} $1"
}

warn() {
  printf "%b\n" "${YELLOW}[WARN]${NC} $1"
}

require_cmd() {
  local cmd="$1"
  local help="$2"
  command -v "$cmd" >/dev/null 2>&1 || error "$cmd is not installed. $help"
}

version_ge() {
  local got="$1"
  local min="$2"

  local got_major got_minor min_major min_minor
  got_major="${got%%.*}"
  got_minor="${got#*.}"; got_minor="${got_minor%%.*}"
  min_major="${min%%.*}"
  min_minor="${min#*.}"; min_minor="${min_minor%%.*}"

  [[ "$got_major" =~ ^[0-9]+$ ]] || return 1
  [[ "$got_minor" =~ ^[0-9]+$ ]] || return 1

  if [ "$got_major" -gt "$min_major" ]; then
    return 0
  fi
  if [ "$got_major" -lt "$min_major" ]; then
    return 1
  fi
  [ "$got_minor" -ge "$min_minor" ]
}

info "VKTurnProxy unsigned IPA build (expected time: 2-5 minutes)"
info "Step 1/8: Checking prerequisites"

require_cmd xcodebuild "Install full Xcode.app from the App Store, then run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
XCODEBUILD_VERSION="$(xcodebuild -version 2>/dev/null || true)"
[ -n "$XCODEBUILD_VERSION" ] || error "xcodebuild is not usable. Install/launch Xcode.app once and accept licenses."

XCODE_DEV_PATH="$(xcode-select -p 2>/dev/null || true)"
[ -n "$XCODE_DEV_PATH" ] || error "xcode-select path is not configured. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"

if [[ "$XCODE_DEV_PATH" == *"CommandLineTools"* ]]; then
  error "Only Command Line Tools are selected. Full Xcode.app is required for iphoneos SDK. Run: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
fi

if [[ "$XCODE_DEV_PATH" != *"Xcode.app"* ]]; then
  warn "xcode-select path does not include Xcode.app explicitly: $XCODE_DEV_PATH"
  warn "Continuing because xcodebuild is available, but full Xcode.app is still required."
fi

require_cmd go "Install Go 1.25+ from https://go.dev/dl/ or brew install go"
GO_VERSION_RAW="$(go version 2>/dev/null || true)"
GO_VERSION="$(printf '%s' "$GO_VERSION_RAW" | sed -E 's/.*go([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/')"
[ -n "$GO_VERSION" ] || error "Unable to parse Go version from: $GO_VERSION_RAW"
version_ge "$GO_VERSION" "1.25" || error "Go $GO_VERSION detected; Go 1.25+ is required. Upgrade with: brew install go"

require_cmd xcodegen "Install XcodeGen with: brew install xcodegen"
XCODEGEN_VERSION="$(xcodegen --version 2>/dev/null || true)"
[ -n "$XCODEGEN_VERSION" ] || error "xcodegen is not usable. Reinstall with: brew install xcodegen"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64) info "Host architecture: Apple Silicon ($ARCH)" ;;
  x86_64) info "Host architecture: Intel ($ARCH)" ;;
  *) info "Host architecture: $ARCH" ;;
esac

info "Xcode: $(printf '%s' "$XCODEBUILD_VERSION" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g')"
info "Go: $GO_VERSION_RAW"
info "XcodeGen: $XCODEGEN_VERSION"

info "Cleaning previous build artifacts"
rm -rf "$BUILD_DIR/"

info "Step 2/8: Building Go c-archive"
"$PROJECT_ROOT/scripts/build-go.sh"
[ -f "$GO_BUILD_DIR/libvkturn.a" ] || error "Missing Go library: $GO_BUILD_DIR/libvkturn.a"
[ -f "$GO_BUILD_DIR/libvkturn.h" ] || error "Missing Go header: $GO_BUILD_DIR/libvkturn.h"

info "Step 3/8: Copying Go header for Swift bridging"
mkdir -p "$BRIDGE_DIR"
cp "$GO_BUILD_DIR/libvkturn.h" "$BRIDGE_DIR/libvkturn.h"
[ -f "$BRIDGE_DIR/libvkturn.h" ] || error "Failed to copy header to $BRIDGE_DIR/libvkturn.h"

info "Step 4/8: Generating Xcode project"
(cd "$PROJECT_ROOT" && xcodegen generate)
[ -f "$PROJECT_ROOT/VKTurnProxy.xcodeproj/project.pbxproj" ] || error "Xcode project generation failed (missing VKTurnProxy.xcodeproj/project.pbxproj)"

info "Step 5/8: Building unsigned archive"
(cd "$PROJECT_ROOT" && xcodebuild archive \
  -project VKTurnProxy.xcodeproj \
  -scheme VKTurnProxy \
  -archivePath build/VKTurnProxy.xcarchive \
  -configuration Release \
  -sdk iphoneos \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  HEADER_SEARCH_PATHS="$(pwd)/build/go" \
  LIBRARY_SEARCH_PATHS="$(pwd)/build/go")

[ -d "$ARCHIVE_PATH/Products/Applications/VKTurnProxy.app" ] || error "Archive app bundle missing at $ARCHIVE_PATH/Products/Applications/VKTurnProxy.app"

info "Step 6/8: Packaging unsigned IPA (manual Payload zip)"
mkdir -p "$BUILD_DIR/Payload"
cp -R "$ARCHIVE_PATH/Products/Applications/VKTurnProxy.app" "$BUILD_DIR/Payload/"
rm -f "$IPA_PATH"
(cd "$BUILD_DIR" && zip -r VKTurnProxy.ipa Payload >/dev/null)

info "Step 7/8: Verifying IPA structure"
[ -f "$IPA_PATH" ] || error "IPA file was not created: $IPA_PATH"
unzip -l "$IPA_PATH" | grep -q "Payload/VKTurnProxy.app/VKTurnProxy" || error "IPA missing app binary: Payload/VKTurnProxy.app/VKTurnProxy"
unzip -l "$IPA_PATH" | grep -q "Payload/VKTurnProxy.app/Info.plist" || error "IPA missing Info.plist: Payload/VKTurnProxy.app/Info.plist"

IPA_SIZE_BYTES="$(stat -f%z "$IPA_PATH" 2>/dev/null || stat -c%s "$IPA_PATH" 2>/dev/null || echo unknown)"
if command -v numfmt >/dev/null 2>&1; then
  IPA_SIZE_HUMAN="$(numfmt --to=iec-i --suffix=B "$IPA_SIZE_BYTES" 2>/dev/null || echo "$IPA_SIZE_BYTES bytes")"
else
  IPA_SIZE_HUMAN="$IPA_SIZE_BYTES bytes"
fi

info "Step 8/8: Done"
printf "%b\n" "${GREEN}✓ Success! Unsigned IPA is ready.${NC}"
printf "%b\n" "IPA: $IPA_PATH"
printf "%b\n" "Size: $IPA_SIZE_HUMAN"
printf "%b\n" ""
printf "%b\n" "Next steps (AltStore/Sideloadly):"
printf "%b\n" "1) Open AltStore or Sideloadly on your Mac"
printf "%b\n" "2) Select: $IPA_PATH"
printf "%b\n" "3) Install to your iPhone/iPad (AltStore/Sideloadly will sign at install time)"
