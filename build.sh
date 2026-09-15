#!/bin/bash
# Build ClaudeUsage.app from main.swift into a proper .app bundle.
set -e
cd "$(dirname "$0")"

APP="ClaudeUsage.app"
BIN="$APP/Contents/MacOS/ClaudeUsage"

echo "Compiling…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O main.swift -o "$BIN" \
    -framework AppKit -framework SwiftUI -framework ServiceManagement

cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc code sign so the Keychain item is reachable and login-item works.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "Built $APP"
