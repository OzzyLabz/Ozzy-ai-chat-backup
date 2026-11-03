#!/bin/zsh
# Сборка универсальной программы (Intel + Apple Silicon) без Xcode-проекта.
set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="${TMPDIR:-/tmp}/backup-ai-build"
APP_DIR="$PROJECT_DIR/dist/Бэкап ИИ.app"
CONTENTS="$APP_DIR/Contents"

SOURCES=(
    "$PROJECT_DIR/Sources/Store.swift"
    "$PROJECT_DIR/Sources/Exporter.swift"
    "$PROJECT_DIR/Sources/Readers.swift"
    "$PROJECT_DIR/Sources/Archive.swift"
    "$PROJECT_DIR/Sources/System.swift"
    "$PROJECT_DIR/Sources/App.swift"
)

rm -rf "$APP_DIR"
mkdir -p "$BUILD_DIR/x64-cache" "$BUILD_DIR/arm64-cache" "$CONTENTS/MacOS" "$CONTENTS/Resources/Fonts" "$CONTENTS/Helpers" "$CONTENTS/Resources/Licenses"

for arch in x86_64 arm64; do
    xcrun swiftc -parse-as-library -swift-version 5 -target "$arch-apple-macos13.0" \
        -module-cache-path "$BUILD_DIR/$arch-cache" -O \
        -framework AppKit -framework SwiftUI -framework ServiceManagement -framework UserNotifications -lsqlite3 \
        "${SOURCES[@]}" -o "$BUILD_DIR/BackupAI-$arch"
done
lipo -create "$BUILD_DIR/BackupAI-x86_64" "$BUILD_DIR/BackupAI-arm64" -output "$CONTENTS/MacOS/BackupAI"

cp -p "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS/Info.plist"
cp -p "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS/Resources/"
for img in mascot menubar oleg car sloth apple; do
    cp -p "$PROJECT_DIR/Resources/$img.png" "$CONTENTS/Resources/"
done
cp -p "$PROJECT_DIR/Resources/Fonts/"* "$CONTENTS/Resources/Fonts/"
cp -p "$PROJECT_DIR/Resources/Licenses/"* "$CONTENTS/Resources/Licenses/"
# Встроенный распаковщик zstd (официальные исходники facebook/zstd 1.5.7, лицензия BSD) — для сжатых сессий Codex и DSH.
cp -p "$PROJECT_DIR/Resources/Helpers/zstd" "$CONTENTS/Helpers/zstd"
codesign --force --sign - "$CONTENTS/Helpers/zstd" >/dev/null

codesign --force --deep --sign - "$APP_DIR" >/dev/null
echo "Создано: $APP_DIR"
lipo -archs "$CONTENTS/MacOS/BackupAI"
