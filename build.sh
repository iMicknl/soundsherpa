#!/bin/bash

echo "Building SoundSherpa..."
swift build -c release

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

echo "Creating app bundle..."

APP_NAME="SoundSherpa"
APP_BUNDLE="$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

# Clean up old bundle
rm -rf "$APP_BUNDLE"

# Create directory structure
mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

# Copy executable
cp ".build/release/$APP_NAME" "$MACOS/$APP_NAME"

# Copy Info.plist
cp Info.plist "$CONTENTS/Info.plist"

# Create PkgInfo
echo -n "APPL????" > "$CONTENTS/PkgInfo"

echo "Build successful!"
echo "App bundle created: $APP_BUNDLE"
echo ""
echo "To run: open $APP_BUNDLE"
echo "Or: ./$APP_BUNDLE/Contents/MacOS/$APP_NAME"
echo ""
echo "Note: You may need to grant Bluetooth permissions in System Preferences > Privacy & Security > Bluetooth"
