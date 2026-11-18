#!/bin/zsh
# Builds "Invoice Inbox.app" into ./dist. Run on a Mac with Xcode 26 or newer.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product InvoiceInbox
BIN="$(swift build -c release --show-bin-path)/InvoiceInbox"

APP="dist/Invoice Inbox.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/InvoiceInbox"
cp Resources/Info.plist "$APP/Contents/Info.plist"

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

# Ad-hoc signature so macOS runs it locally; use a Developer ID to give it to others without warnings.
codesign --force --deep --sign - "$APP"
echo "Built $APP"
