#!/bin/bash

# Script to compile mac.swift into a universal binary (Intel + Apple Silicon)
# This allows the driver to work on Macs without Swift/Xcode installed

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_FILE="$SCRIPT_DIR/mac.swift"
OUTPUT_ARM64="$SCRIPT_DIR/mac-arm64"
OUTPUT_X86="$SCRIPT_DIR/mac-x86_64"
OUTPUT_UNIVERSAL="$SCRIPT_DIR/mac"

echo "Compiling Swift driver for macOS..."

# Check if swiftc is available
if ! command -v swiftc &> /dev/null; then
    echo "Error: Swift compiler (swiftc) not found."
    echo "Please install Xcode or Xcode Command Line Tools."
    exit 1
fi

# Compile for Apple Silicon (arm64)
echo "  -> Compiling for arm64..."
swiftc -O -target arm64-apple-macosx11.0 -o "$OUTPUT_ARM64" "$SWIFT_FILE"

# Compile for Intel (x86_64)
echo "  -> Compiling for x86_64..."
swiftc -O -target x86_64-apple-macosx10.15 -o "$OUTPUT_X86" "$SWIFT_FILE"

# Create universal binary using lipo
echo "  -> Creating universal binary..."
lipo -create -output "$OUTPUT_UNIVERSAL" "$OUTPUT_ARM64" "$OUTPUT_X86"

# Clean up architecture-specific binaries
rm -f "$OUTPUT_ARM64" "$OUTPUT_X86"

# Make the binary executable
chmod +x "$OUTPUT_UNIVERSAL"

echo "Done! Universal binary created at: $OUTPUT_UNIVERSAL"
echo ""
echo "The binary supports both Intel (x86_64) and Apple Silicon (arm64) Macs."
