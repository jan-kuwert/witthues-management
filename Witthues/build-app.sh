#!/bin/zsh
# Builds "Witthüs.app" and "Witthüs.dmg" into ./dist. Run on an Apple Silicon Mac with Xcode 26 or newer.
# The .dmg is the file to AirDrop or copy to another Mac; see README.md, "Installing on another Mac".
# VERSION=12 ./build-app.sh stamps version 12 and also writes dist/Witthues.zip, the file the in-app updater
# downloads; the release workflow (.github/workflows/release.yml) does this. Without VERSION the build is version 0,
# which the app treats as older than every release.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product Witthues
BIN="$(swift build -c release --show-bin-path)/Witthues"

APP="dist/Witthüs.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Witthues"
cp Resources/Info.plist "$APP/Contents/Info.plist"
VERSION="${VERSION:-0}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# App icon: render the SVG at every size macOS wants, then pack it into an .icns.
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
cat > "$ICONSET/../render.swift" <<'EOF'
import AppKit
let args = CommandLine.arguments
let image = NSImage(contentsOfFile: args[1])!
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(size)x\(size).png" : "icon_\(size)x\(size)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]).appendingPathComponent(name))
    }
}
EOF
swift "$ICONSET/../render.swift" Resources/AppIcon.svg "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# Releases are signed with the certificate from make-signing-key.sh (SIGN_IDENTITY, set by release.yml), so every
# version has the same signature and keeps its keychain access. Without it: an ad-hoc signature, which macOS runs
# locally but treats as a new app after each build.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    KEYCHAIN_ARGS=()
    [[ -n "${SIGN_KEYCHAIN:-}" ]] && KEYCHAIN_ARGS=(--keychain "$SIGN_KEYCHAIN")
    codesign --force --deep --sign "$SIGN_IDENTITY" "${KEYCHAIN_ARGS[@]}" "$APP"
else
    codesign --force --deep --sign - "$APP"
fi
echo "Built $APP"

# Disk image with the app and a link to /Applications, so installing is one drag.
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Witthüs" -srcfolder "$STAGE" -ov -format UDZO "dist/Witthüs.dmg"
rm -rf "$STAGE"
echo "Built dist/Witthüs.dmg"

if [[ "$VERSION" != 0 ]]; then
    rm -f dist/Witthues.zip
    ditto -c -k --keepParent "$APP" dist/Witthues.zip
    echo "Built dist/Witthues.zip (version $VERSION)"
fi
