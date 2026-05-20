#!/bin/bash
set -e

echo "🔧 ScreenSnagger project setup"
echo ""

# Check for Xcode
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ Xcode not found. Install Xcode from the App Store first."
    exit 1
fi
echo "✓ Xcode found: $(xcodebuild -version | head -1)"

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    echo "❌ Homebrew not found. Install from https://brew.sh"
    exit 1
fi
echo "✓ Homebrew found"

# Install XcodeGen if missing
if ! command -v xcodegen &> /dev/null; then
    echo "⏳ Installing XcodeGen..."
    brew install xcodegen
else
    echo "✓ XcodeGen found"
fi

# Generate Xcode project
echo "⏳ Generating ScreenSnagger.xcodeproj..."
cd "$(dirname "$0")"
xcodegen generate

echo ""
echo "✅ Done! You can now:"
echo "   • Open ScreenSnagger.xcodeproj in Xcode and hit ⌘R"
echo "   • Or build from CLI: xcodebuild -project ScreenSnagger.xcodeproj -scheme ScreenSnagger build"
echo ""
