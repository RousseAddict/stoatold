#!/bin/bash
# build.sh — Full build + IPA pipeline for stoatold on SERV2
# Produces: stoatold_ios6.ipa  — iOS 6/7 compatible (dylib surgery + vtool patches)
# Usage: ./build.sh

set -e

SERV="srv-admin@SERV2.local"
PASS="rousse"

echo "==> [iOS 6/7] Building stoatold on SERV2..."

sshpass -p "$PASS" ssh -o IdentitiesOnly=yes -o PubkeyAuthentication=no -o StrictHostKeyChecking=no "$SERV" bash <<'REMOTE'
set -e

PROJECT_DIR=~/Documents/ios6-app/stoatold/stoatold
IPA_DIR=~/Documents/ios6-app/stoatold/build
TOOLCHAIN_515=/Library/Developer/Toolchains/swift-5.1.5-RELEASE.xctoolchain/usr/lib/swift/iphoneos

# ── 1. Build ────────────────────────────────────────────────────────────────
echo "[1/6] xcodebuild..."
cd "$PROJECT_DIR"
xcodebuild \
  -project stoatold.xcodeproj \
  -scheme stoatold \
  -sdk iphoneos \
  -configuration Debug \
  -toolchain org.swift.563202208261a \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  2>&1 | grep -E "(error:|warning: .*error|BUILD SUCCEEDED|BUILD FAILED|CompileSwift )" | tail -20

# ── Locate .app in DerivedData (hash-agnostic) ───────────────────────────────
APP=$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 5 -name "stoatold.app" -path "*/Debug-iphoneos/*" 2>/dev/null | head -1)
if [ -z "$APP" ]; then
  echo "ERROR: stoatold.app not found in DerivedData after build"
  exit 1
fi
FWDIR="$APP/Frameworks"
echo "    App: $APP"

# ── 1.5. Embed WebRTC.framework into app bundle ──────────────────────────────
echo "[1.5/6] Embedding WebRTC.framework..."
WEBRTC_SRC="$PROJECT_DIR/stoatold/ThirdParty/WebRTC/WebRTC.framework"
mkdir -p "$FWDIR/WebRTC.framework"
cp -r "$WEBRTC_SRC/" "$FWDIR/WebRTC.framework/"

# ── 2. Remove Metal dylib (Metal = iOS 8+) ──────────────────────────────────
echo "[2/6] Removing libswiftMetal.dylib..."
rm -f "$FWDIR/libswiftMetal.dylib"

# ── 3. Swap dylibs with Swift 5.1.5 runtime ─────────────────────────────────
echo "[3/6] Replacing dylibs with 5.1.5 runtime..."
for f in "$FWDIR"/*.dylib; do
  name=$(basename "$f")
  [ -f "$TOOLCHAIN_515/$name" ] && cp "$TOOLCHAIN_515/$name" "$f"
done

# ── 4. Patch LC_VERSION_MIN_IPHONEOS to 6.0 ─────────────────────────────────
echo "[4/6] Patching version min to iOS 6.0..."
for f in "$FWDIR"/*.dylib; do
  vtool -set-version-min ios 6.0 6.0 -output "$f" "$f" 2>/dev/null
done
# Patch WebRTC.framework binary
vtool -set-version-min ios 6.0 6.0 -output "$FWDIR/WebRTC.framework/WebRTC" "$FWDIR/WebRTC.framework/WebRTC" 2>/dev/null || true
vtool -set-version-min ios 6.0 6.0 -output "$APP/stoatold" "$APP/stoatold"
/usr/libexec/PlistBuddy -c "Set :MinimumOSVersion 6.0" "$APP/Info.plist"

# ── 4.5. Inject logo + iOS-6 icon loose files into bundle ───────────────────
XCASSETS="$PROJECT_DIR/stoatold/Assets.xcassets/AppIcon.appiconset"
SRC_PROJ="$PROJECT_DIR/stoatold"

# Login screen logo (UIImage(named:"stoatold_logo") finds loose PNGs on all iOS)
for suffix in "" "@2x" "@3x"; do
  f="$SRC_PROJ/stoatold_logo${suffix}.png"
  [ -f "$f" ] && cp "$f" "$APP/stoatold_logo${suffix}.png"
done

# App icon loose files for iOS 6 (asset catalog icons aren't readable on iOS 6)
cp "$XCASSETS/icon-57.png"  "$APP/Icon.png"        2>/dev/null || true
cp "$XCASSETS/icon-114.png" "$APP/Icon@2x.png"     2>/dev/null || true
cp "$XCASSETS/icon-120.png" "$APP/Icon-60@2x.png"  2>/dev/null || true
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFiles" "$APP/Info.plist" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles array"                "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles:0 string Icon.png"       "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles:1 string Icon@2x.png"    "$APP/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles:2 string Icon-60@2x.png" "$APP/Info.plist"
echo "    Icons + logo injected into bundle"

# ── 5. Ad-hoc sign ───────────────────────────────────────────────────────────
echo "[5/6] Ad-hoc signing..."
for f in "$FWDIR"/*.dylib; do
  codesign --force --sign - "$f"
done
codesign --force --sign - "$FWDIR/WebRTC.framework/WebRTC"
codesign --force --sign - "$APP"

# ── 6. Package IPA ───────────────────────────────────────────────────────────
echo "[6/6] Packaging IPA..."
rm -rf "$IPA_DIR" && mkdir -p "$IPA_DIR/Payload"
cp -r "$APP" "$IPA_DIR/Payload/"
cd "$IPA_DIR"
zip -r stoatold_ios6.ipa Payload > /dev/null && rm -rf Payload
ls -lh "$IPA_DIR/stoatold_ios6.ipa"

echo "Done. IPA at: ~/Documents/ios6-app/stoatold/build/stoatold_ios6.ipa"
REMOTE

echo "==> Copying IPA to ~/Desktop/stoatold_ios6.ipa..."
sshpass -p "$PASS" scp \
  "$SERV:~/Documents/ios6-app/stoatold/build/stoatold_ios6.ipa" \
  ~/Desktop/stoatold_ios6.ipa
echo "==> Done: ~/Desktop/stoatold_ios6.ipa"
