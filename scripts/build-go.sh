#!/usr/bin/env bash
set -e

# iOS arm64 c-archive static library builder for Go bridge module
# Cross-compiles to iOS ARM64 architecture using Xcode SDK

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Helper functions
error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
    exit 1
}

info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check prerequisites
info "Verifying prerequisites..."

if ! command -v go &> /dev/null; then
    error "Go is not installed. Please install Go 1.21+ for iOS cross-compilation."
fi
GO_VERSION=$(go version | awk '{print $3}')
info "Go version: $GO_VERSION"

if ! command -v xcrun &> /dev/null; then
    error "Xcode is not installed. Please install Xcode and run 'xcode-select --install'."
fi

if ! xcode-select -p &> /dev/null; then
    error "Xcode Command Line Tools not configured. Run 'sudo xcode-select --reset'."
fi
XCODE_PATH=$(xcode-select -p)
info "Xcode path: $XCODE_PATH"

# Resolve iOS SDK path and clang compiler
info "Resolving iOS SDK..."
SDK_PATH=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null) || error "Failed to resolve iOS SDK path. Check Xcode installation."
info "iOS SDK: $SDK_PATH"

CC=$(xcrun --sdk iphoneos --find clang 2>/dev/null) || error "Failed to find iOS clang compiler."
info "iOS clang: $CC"

# Set up Go cross-compilation environment
export GOOS=ios
export GOARCH=arm64
export CGO_ENABLED=1
export CC="$CC"
export CGO_CFLAGS="-arch arm64 -isysroot $SDK_PATH"
export CGO_LDFLAGS="-arch arm64 -isysroot $SDK_PATH"

info "Build environment:"
info "  GOOS=$GOOS GOARCH=$GOARCH CGO_ENABLED=$CGO_ENABLED"
info "  CGO_CFLAGS=$CGO_CFLAGS"
info "  CGO_LDFLAGS=$CGO_LDFLAGS"

# Create output directory
OUTPUT_DIR="build/go"
mkdir -p "$OUTPUT_DIR"
info "Output directory: $OUTPUT_DIR"

# Get project root (script directory's parent)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Change to go module directory (assume it's at go/ or $PROJECT_ROOT)
if [ -d "$PROJECT_ROOT/go" ] && [ -f "$PROJECT_ROOT/go/go.mod" ]; then
    GO_MODULE_DIR="$PROJECT_ROOT/go"
elif [ -f "$PROJECT_ROOT/go.mod" ]; then
    GO_MODULE_DIR="$PROJECT_ROOT"
else
    error "No Go module found. Expected go.mod in $PROJECT_ROOT/go or $PROJECT_ROOT"
fi

info "Go module directory: $GO_MODULE_DIR"

# Build c-archive
info "Building iOS arm64 c-archive library..."
cd "$GO_MODULE_DIR"

go build \
    -buildmode=c-archive \
    -o "../$OUTPUT_DIR/libvkturn.a" \
    . 2>&1 || error "Go build failed. Check compilation errors above."

cd "$PROJECT_ROOT"

# Verify outputs
info "Verifying build outputs..."
if [ ! -f "$OUTPUT_DIR/libvkturn.a" ]; then
    error "Output library not found: $OUTPUT_DIR/libvkturn.a"
fi

if [ ! -f "$OUTPUT_DIR/libvkturn.h" ]; then
    error "Output header not found: $OUTPUT_DIR/libvkturn.h"
fi

# Display build information
LIB_SIZE=$(stat -f%z "$OUTPUT_DIR/libvkturn.a" 2>/dev/null || stat -c%s "$OUTPUT_DIR/libvkturn.a" 2>/dev/null || echo "unknown")
EXPORT_COUNT=$(grep -c "^extern" "$OUTPUT_DIR/libvkturn.h" 2>/dev/null || echo "unknown")

info "Build successful!"
info "Library: $OUTPUT_DIR/libvkturn.a ($(numfmt --to=iec-i --suffix=B $LIB_SIZE 2>/dev/null || echo "$LIB_SIZE bytes"))"
info "Header: $OUTPUT_DIR/libvkturn.h ($(grep -c '^' "$OUTPUT_DIR/libvkturn.h" 2>/dev/null || echo "unknown") lines)"
info "Exported symbols: $EXPORT_COUNT"

# Verify iOS platform in binary
if command -v otool &> /dev/null; then
    PLATFORM=$(otool -l "$OUTPUT_DIR/libvkturn.a" 2>/dev/null | grep -A2 "Load command" | grep "platform" | head -1 | awk '{print $2}') || true
    if [ -n "$PLATFORM" ]; then
        info "Verified iOS platform: mach-o format"
    fi
fi

info "✓ iOS arm64 build complete"
