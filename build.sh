#!/bin/zsh
# Сборка универсальной программы (Intel + Apple Silicon) без Xcode-проекта.
#   ./build.sh                 — проверочная сборка «Бэкап ИИ (тест).app»: настоящие данные только читаются,
#                                свои настройки — в «~/Library/Application Support/Бэкап ИИ (тест)», расписание не трогается
#   DEMO=1 ./build.sh          — демо с вымышленными данными (меню «Тест»)
#   RELEASE=1 ./build.sh       — настоящая программа «AI Chat Backup.app» с лентой обновлений на GitHub
# Версия: VERSION=2.0 BUILD=200; папка результата: OUT=…
set -euo pipefail

PROJECT_DIR="${0:A:h}"
BUILD_DIR="${TMPDIR:-/tmp}/backup-ai-test-build"
VERSION="${VERSION:-2.0}"
BUILD="${BUILD:-200}"
OUT="${OUT:-$PROJECT_DIR/dist}"
DEMO="${DEMO:-0}"
RELEASE="${RELEASE:-0}"

if [[ "$RELEASE" == "1" ]]; then
    NAME="AI Chat Backup"; BUNDLE_ID="com.ozzy.backup-ai"
    FEED="https://raw.githubusercontent.com/OzzyLabz/Ozzy-ai-chat-backup/main/appcast.xml"
    FLAGS=()
else
    NAME="Бэкап ИИ (тест)"; BUNDLE_ID="com.ozzy.backup-ai.test"
    FEED="http://127.0.0.1:8765/appcast.xml"
    FLAGS=(); [[ "$DEMO" == "1" ]] && FLAGS=(-D DEMO)
fi
APP_DIR="$OUT/$NAME.app"
CONTENTS="$APP_DIR/Contents"

SOURCES=(
    "$PROJECT_DIR/Sources/Store.swift"
    "$PROJECT_DIR/Sources/Exporter.swift"
    "$PROJECT_DIR/Sources/Readers.swift"
    "$PROJECT_DIR/Sources/Archive.swift"
    "$PROJECT_DIR/Sources/System.swift"
    "$PROJECT_DIR/Sources/App.swift"
    "$PROJECT_DIR/Sources/Kit.swift"
    "$PROJECT_DIR/Sources/Demo.swift"
    "$PROJECT_DIR/Sources/Lang.swift"
    "$PROJECT_DIR/Sources/Updater.swift"
)
[[ -f "$PROJECT_DIR/Sources/Skills.swift" ]] && SOURCES+=("$PROJECT_DIR/Sources/Skills.swift")
[[ -f "$PROJECT_DIR/Sources/ArchiveLang.swift" ]] && SOURCES+=("$PROJECT_DIR/Sources/ArchiveLang.swift")

rm -rf "$APP_DIR"
mkdir -p "$BUILD_DIR/x64-cache" "$BUILD_DIR/arm64-cache" "$CONTENTS/MacOS" "$CONTENTS/Resources/Fonts" "$CONTENTS/Helpers" "$CONTENTS/Resources/Licenses"

for arch in x86_64 arm64; do
    xcrun swiftc -parse-as-library -swift-version 5 -target "$arch-apple-macos13.0" \
        -module-cache-path "$BUILD_DIR/$arch-cache" -O "${FLAGS[@]}" \
        -F "$PROJECT_DIR/Vendor/Sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
        -framework AppKit -framework SwiftUI -framework ServiceManagement -framework UserNotifications -lsqlite3 \
        "${SOURCES[@]}" -o "$BUILD_DIR/BackupAI-$arch"
done
lipo -create "$BUILD_DIR/BackupAI-x86_64" "$BUILD_DIR/BackupAI-arm64" -output "$CONTENTS/MacOS/BackupAI"

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" -e "s/__NAME__/$NAME/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/" -e "s#__FEED__#$FEED#" \
    "$PROJECT_DIR/Resources/Info.plist" > "$CONTENTS/Info.plist"
# Местная лента нужна только проверке; в настоящей программе разрешение на сеть внутри Mac не нужно.
[[ "$RELEASE" == "1" ]] && plutil -remove NSAppTransportSecurity "$CONTENTS/Info.plist"
mkdir -p "$CONTENTS/Frameworks"
ditto "$PROJECT_DIR/Vendor/Sparkle/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"
cp -p "$PROJECT_DIR/Resources/AppIcon.icns" "$CONTENTS/Resources/"
for img in mascot menubar oleg car sloth apple; do
    cp -p "$PROJECT_DIR/Resources/$img.png" "$CONTENTS/Resources/"
done
cp -p "$PROJECT_DIR/Resources/Fonts/"*.ttf "$PROJECT_DIR/Resources/Fonts/"*.txt "$CONTENTS/Resources/Fonts/"
mkdir -p "$CONTENTS/Resources/Lang"
cp -p "$PROJECT_DIR/Resources/Lang/"*.json "$CONTENTS/Resources/Lang/"
cp -p "$PROJECT_DIR/Resources/Licenses/"* "$CONTENTS/Resources/Licenses/"
# Название программы на языке системы (Finder, Dock, Launchpad): ru, en, zh-Hans, ja, hi.
cp -Rp "$PROJECT_DIR/Resources/"*.lproj "$CONTENTS/Resources/"
if [[ "$RELEASE" != "1" ]]; then
    # Проверка и демо: к названию на каждом языке добавляется «(тест)», чтобы не спутать с настоящей программой.
    typeset -A SUFFIX=(ru " (тест)" en " (test)" zh-Hans "（测试）" ja "（テスト）" hi " (टेस्ट)")
    for l in ${(k)SUFFIX}; do
        f="$CONTENTS/Resources/$l.lproj/InfoPlist.strings"
        sed -i '' 's/";$/'"${SUFFIX[$l]}"'";/' "$f"
    done
fi
# Встроенный распаковщик zstd (официальные исходники facebook/zstd 1.5.7, лицензия BSD) — для сжатых сессий Codex и DSH.
cp -p "$PROJECT_DIR/Resources/Helpers/zstd" "$CONTENTS/Helpers/zstd"
# Служебные файлы Finder (значки папок «Icon», атрибуты) мешают подписи — убираем из программы.
find "$APP_DIR" -name $'Icon\r' -delete
xattr -cr "$APP_DIR"
codesign --force --sign - "$CONTENTS/Helpers/zstd" >/dev/null

# Sparkle.framework уже подписан своими авторами — его подпись не трогаем, подписываем саму программу.
codesign --force --sign - "$APP_DIR" >/dev/null
echo "Создано: $APP_DIR"
lipo -archs "$CONTENTS/MacOS/BackupAI"
