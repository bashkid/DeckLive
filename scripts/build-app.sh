#!/bin/bash
# Builds DeckLive as a release-configured macOS .app bundle, ready to be
# dropped into /Applications.  Uses only built-in tools (swift, sips,
# iconutil, plutil) — no third-party deps.
#
# Output:  dist/DeckLive.app
#
# Then run scripts/build-dmg.sh to wrap it in a distributable .dmg.

set -euo pipefail

# -------------------------------------------------------------------- paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
ROOT_DIR="$( cd "$SCRIPT_DIR/.." && pwd )"
cd "$ROOT_DIR"

# Force Xcode's developer dir so SPM finds the FoundationModels macros
# (Command Line Tools' Swift toolchain ships without those macro plugins,
# which makes the AI quiz module fail to compile under `swift build`).
if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
SWIFT="xcrun swift"

APP_NAME="DeckLive"
BUNDLE_ID="com.decklive.app"
APP_VERSION="1.0.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
LOGO_PNG="$ROOT_DIR/Sources/Images/decklive_logo.png"

# ---------------------------------------------------------------- preflight
if [[ ! -f "$LOGO_PNG" ]]; then
  echo "ERROR: source logo not found at $LOGO_PNG"
  exit 1
fi

echo "==> Cleaning previous build…"
rm -rf "$DIST_DIR/$APP_NAME.app"
mkdir -p "$DIST_DIR"

# ---------------------------------------------------------------- build bin
# Prefer a universal (arm64 + x86_64) binary when xcbuild is available,
# otherwise fall back to a single-arch native build.
echo "==> Building DeckLive in release mode (this may take a minute)…"

BIN_PATH=""
if $SWIFT build -c release --arch arm64 --arch x86_64 --show-bin-path >/dev/null 2>&1; then
  $SWIFT build -c release --arch arm64 --arch x86_64 \
    && BIN_PATH="$($SWIFT build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME"
fi

if [[ -z "$BIN_PATH" || ! -f "$BIN_PATH" ]]; then
  echo "  (universal build unavailable — falling back to native arch)"
  $SWIFT build -c release
  BIN_PATH="$($SWIFT build -c release --show-bin-path)/$APP_NAME"
fi

if [[ ! -f "$BIN_PATH" ]]; then
  echo "ERROR: built binary not found at $BIN_PATH"
  exit 1
fi
UNIVERSAL_BIN="$BIN_PATH"

# ---------------------------------------------------------------- bundle layout
echo "==> Laying out $APP_NAME.app bundle…"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Drop the universal binary in.
cp "$UNIVERSAL_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy SPM-bundled resources (the runtime logo, etc.) into the .app so
# Bundle.module still resolves at runtime.
BIN_DIR="$(dirname "$UNIVERSAL_BIN")"
SPM_RESOURCES_BUNDLE="$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$SPM_RESOURCES_BUNDLE" ]]; then
  cp -R "$SPM_RESOURCES_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
fi

# ---------------------------------------------------------------- icon
echo "==> Generating AppIcon.icns from $LOGO_PNG …"
ICON_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICON_DIR"

# Pad the logo onto a 1024×1024 transparent canvas using a small
# AppKit-based helper (sips can't preserve alpha when padding). The
# original artwork already carries its own rounded shape, so this gives
# the dock + Launchpad the bare silhouette to render — no surrounding
# white box, which is what made the icon look off before.
PADDED_PNG="$(mktemp).png"
swift "$SCRIPT_DIR/make-square-icon.swift" "$LOGO_PNG" "$PADDED_PNG" 1024

# Standard macOS icon sizes (1× and 2× for each).
for size in 16 32 128 256 512; do
  sips -z "$size"   "$size"   "$PADDED_PNG" --out "$ICON_DIR/icon_${size}x${size}.png"      >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" "$PADDED_PNG" --out "$ICON_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil --convert icns --output "$APP_BUNDLE/Contents/Resources/AppIcon.icns" "$ICON_DIR"
rm -rf "$(dirname "$ICON_DIR")"

# ---------------------------------------------------------------- Info.plist
echo "==> Writing Info.plist…"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>             <string>en</string>
    <key>CFBundleDisplayName</key>                   <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>                    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>                      <string>AppIcon</string>
    <key>CFBundleIdentifier</key>                    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>         <string>6.0</string>
    <key>CFBundleName</key>                          <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>                   <string>APPL</string>
    <key>CFBundleShortVersionString</key>            <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>                       <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>                <string>13.0</string>
    <key>LSApplicationCategoryType</key>             <string>public.app-category.education</string>
    <key>NSHighResolutionCapable</key>               <true/>
    <key>NSPrincipalClass</key>                      <string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key>        <true/>
    <key>NSSupportsSuddenTermination</key>           <true/>

    <!-- Required for the .pptx → PDF conversion flow which drives
         Microsoft PowerPoint via AppleScript. Without this key macOS
         refuses the Automation grant silently and the user sees
         "not authorized to send Apple events to Microsoft PowerPoint". -->
    <key>NSAppleEventsUsageDescription</key>
    <string>DeckLive uses Microsoft PowerPoint in the background to convert .pptx and .ppt files to PDF for rendering.</string>

    <!-- TCC usage descriptions for protected user folders. Without these
         macOS prompts on every launch instead of remembering the grant. -->
    <key>NSDocumentsFolderUsageDescription</key>
    <string>DeckLive needs to read your Documents folder to open your PDF and PowerPoint files.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>DeckLive needs to read your Downloads folder to open decks you've saved there.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>DeckLive needs to read your Desktop to open decks you've saved there.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>DeckLive needs to read external drives to open decks stored on them.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>DeckLive needs to read network volumes to open decks stored on them.</string>
    <key>NSFileProviderDomainUsageDescription</key>
    <string>DeckLive needs to read iCloud and other cloud-synced folders to open decks stored there.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>              <string>PDF Document</string>
            <key>CFBundleTypeRole</key>              <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.adobe.pdf</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>              <string>PowerPoint Presentation</string>
            <key>CFBundleTypeRole</key>              <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.openxmlformats.presentationml.presentation</string>
                <string>com.microsoft.powerpoint.ppt</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

# ---------------------------------------------------------------- code signing (ad-hoc)
echo "==> Ad-hoc signing the bundle…"
codesign --force --deep --sign - "$APP_BUNDLE" 2>&1 | grep -v "replacing existing signature" || true

# ---------------------------------------------------------------- done
echo
echo "Done. App bundle is at:"
echo "  $APP_BUNDLE"
echo
echo "Drop it into /Applications, or run:"
echo "  open \"$APP_BUNDLE\""
echo
echo "To produce a distributable .dmg:"
echo "  scripts/build-dmg.sh"
