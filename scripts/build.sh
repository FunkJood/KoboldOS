#!/bin/bash

# Build script for KoboldOS
VERSION="0.2.3"
echo "Building KoboldOS v${VERSION}..."

# Clean previous builds
rm -rf dist/KoboldOSv${VERSION}.app
rm -f dist/KoboldOSv${VERSION}.dmg
rm -f dist/KoboldOS-${VERSION}.dmg
rm -rf dist/dmg_staging

# Build the project
echo "Compiling..."
swift build -c release

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

# Create app bundle structure
echo "Creating app bundle..."
mkdir -p dist/KoboldOSv${VERSION}.app/Contents/MacOS
mkdir -p dist/KoboldOSv${VERSION}.app/Contents/Resources

# Copy the built executable
cp .build/release/KoboldOSControlPanel dist/KoboldOSv${VERSION}.app/Contents/MacOS/KoboldOS
cp .build/release/kobold dist/KoboldOSv${VERSION}.app/Contents/MacOS/

# Copy AppIcon
if [ -f "Sources/KoboldOSControlPanel/AppIcon.icns" ]; then
    cp Sources/KoboldOSControlPanel/AppIcon.icns dist/KoboldOSv${VERSION}.app/Contents/Resources/
    echo "AppIcon copied."
else
    echo "Warning: AppIcon.icns not found in Sources/KoboldOSControlPanel/"
fi

# Copy bundle resources if present
if [ -d ".build/release/KoboldOS_KoboldOSControlPanel.bundle" ]; then
    cp -r .build/release/KoboldOS_KoboldOSControlPanel.bundle dist/KoboldOSv${VERSION}.app/Contents/Resources/
fi

# Create Info.plist
cat > dist/KoboldOSv${VERSION}.app/Contents/Info.plist << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>KoboldOS</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.koboldos.controlpanel</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>KoboldOS</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>20260222</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (c) 2026 KoboldOS. All rights reserved.</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSCalendarsUsageDescription</key>
    <string>KoboldOS benoetigt Zugriff auf deinen Kalender um Termine zu erstellen, lesen und verwalten.</string>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>KoboldOS benoetigt vollen Kalender-Zugriff um Termine zu erstellen und zu verwalten.</string>
    <key>NSRemindersUsageDescription</key>
    <string>KoboldOS benoetigt Zugriff auf Erinnerungen um Aufgaben zu erstellen und zu verwalten.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>KoboldOS benoetigt vollen Zugriff auf Erinnerungen um sie zu erstellen und zu verwalten.</string>
    <key>NSContactsUsageDescription</key>
    <string>KoboldOS benoetigt Zugriff auf deine Kontakte um Namen, Nummern und E-Mail-Adressen zu finden.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>KoboldOS benoetigt AppleScript-Zugriff um macOS-Apps wie Mail, Messages, Safari und Finder zu steuern.</string>
    <key>NSAppleScriptEnabled</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>KoboldOS benoetigt lokalen Netzwerkzugriff fuer den Daemon-Server und die WebApp-Fernsteuerung.</string>
</dict>
</plist>
EOF

# Copy entitlements if needed
if [ -f "Sources/KoboldOSControlPanel/KoboldOS.entitlements" ]; then
    cp Sources/KoboldOSControlPanel/KoboldOS.entitlements dist/KoboldOSv${VERSION}.app/Contents/
fi

# Make executable
chmod +x dist/KoboldOSv${VERSION}.app/Contents/MacOS/KoboldOS
chmod +x dist/KoboldOSv${VERSION}.app/Contents/MacOS/kobold

echo "Build complete! App bundle created in dist/KoboldOSv${VERSION}.app"

# LOC count
echo ""
echo "Lines of Code:"
find Sources Tests -name "*.swift" | xargs wc -l | tail -1
echo ""

# Create DMG with documentation and Applications symlink
if command -v hdiutil &> /dev/null; then
    echo "Creating DMG with documentation..."
    DMG_STAGING="dist/dmg_staging"
    mkdir -p "$DMG_STAGING"

    # 1. Copy the app
    cp -R "dist/KoboldOSv${VERSION}.app" "$DMG_STAGING/KoboldOS.app"

    # 2. Create Applications symlink (drag-to-install)
    ln -s /Applications "$DMG_STAGING/Applications"

    # 3. Copy documentation (.txt format)
    if [ -f "dist/README.txt" ]; then
        cp dist/README.txt "$DMG_STAGING/"
    fi
    if [ -f "dist/CHANGELOG.txt" ]; then
        cp dist/CHANGELOG.txt "$DMG_STAGING/"
    fi
    if [ -f "dist/DOKUMENTATION.txt" ]; then
        cp dist/DOKUMENTATION.txt "$DMG_STAGING/"
    fi

    # 4. Create DMG
    hdiutil create \
        -volname "KoboldOS Alpha v${VERSION}" \
        -srcfolder "$DMG_STAGING" \
        -ov -format UDZO \
        "dist/KoboldOS-${VERSION}.dmg"

    echo "DMG created at dist/KoboldOS-${VERSION}.dmg"

    # Clean up staging
    rm -rf "$DMG_STAGING"

    # Copy to Desktop for easy access
    cp dist/KoboldOS-${VERSION}.dmg ~/Desktop/KoboldOS-${VERSION}.dmg
    echo "Copied to ~/Desktop/KoboldOS-${VERSION}.dmg"
else
    echo "hdiutil not found, skipping DMG creation"
fi

echo "Done! KoboldOS Alpha v${VERSION}"
