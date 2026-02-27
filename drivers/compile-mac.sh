#!/bin/bash

# Script to compile mac.swift into a universal binary (Intel + Apple Silicon)
# This allows the driver to work on Macs without Swift/Xcode installed

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWIFT_FILE="$SCRIPT_DIR/mac.swift"
OUTPUT_ARM64="$SCRIPT_DIR/mac-arm64"
OUTPUT_X86="$SCRIPT_DIR/mac-x86_64"
OUTPUT_UNIVERSAL="$SCRIPT_DIR/mac"
NOTARIZE_ZIP="$SCRIPT_DIR/mac-notarize.zip"

# Load .env file if present
ENV_FILE="$SCRIPT_DIR/../.env"
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
fi

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

# Sign the universal binary
echo "  -> Signing universal binary..."
ENTITLEMENTS_PLIST="$SCRIPT_DIR/entitlements.plist"

if [ -n "$CODESIGN_IDENTITY" ]; then
    # Full Developer ID signing for notarization
    codesign --deep --force --options runtime \
        --entitlements "$ENTITLEMENTS_PLIST" \
        -s "$CODESIGN_IDENTITY" \
        "$OUTPUT_UNIVERSAL"
else
    # Ad-hoc signing for local development
    echo "  -> (APPLE_ID/APPLE_APP_PASSWORD/TEAM_ID not set, using ad-hoc signing)"
    codesign -s - --force --entitlements "$ENTITLEMENTS_PLIST" "$OUTPUT_UNIVERSAL"
fi

# Verify the signature
echo "  -> Verifying signature..."
if codesign --verify --strict "$OUTPUT_UNIVERSAL" 2>&1; then
    echo "  -> Signature verified successfully."
else
    echo "Error: Signature verification failed."
    exit 1
fi

# Notarize if credentials are available
if [ -n "$APPLE_ID" ] && [ -n "$APPLE_APP_PASSWORD" ] && [ -n "$TEAM_ID" ] && [ -n "$CODESIGN_IDENTITY" ]; then
    echo "  -> Creating zip for notarization..."
    ditto -c -k --keepParent "$OUTPUT_UNIVERSAL" "$NOTARIZE_ZIP"

    echo "  -> Submitting for notarization (this may take a few minutes)..."
    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_APP_PASSWORD" \
        --team-id "$TEAM_ID" \
        --wait

    rm -f "$NOTARIZE_ZIP"

    echo "  -> Stapling notarization ticket..."
    if xcrun stapler staple "$OUTPUT_UNIVERSAL" 2>&1; then
        echo "  -> Ticket stapled successfully."
    else
        echo "  -> Warning: stapling failed (expected for plain binaries — Gatekeeper will verify online)."
    fi

    echo "  -> Notarization complete."
else
    echo "  -> Skipping notarization (APPLE_ID, APPLE_APP_PASSWORD, TEAM_ID or CODESIGN_IDENTITY not set)."
fi

# Make the binary executable
chmod +x "$OUTPUT_UNIVERSAL"

echo "Done! Universal binary created at: $OUTPUT_UNIVERSAL"
echo ""
echo "The binary supports both Intel (x86_64) and Apple Silicon (arm64) Macs."
