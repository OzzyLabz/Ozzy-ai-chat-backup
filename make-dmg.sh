#!/bin/bash
# Собирает красивый DMG: ./make-dmg.sh → dist/<OUT_NAME>
# Finder при первом запуске попросит разрешение на управление.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"

# --- Настройки этой программы ---
APP="$ROOT/../Бэкап ИИ/dist/Бэкап ИИ.app"
VOL="Бэкап ИИ"
OUT_NAME="Ozzy-AI-Chat-Backup-1.0.dmg"
ICON_Y=300
EXTRA=""
# --------------------------------

LINK="Программы"
BG="$ROOT/dmg/background.png"
OUT="$ROOT/dist/$OUT_NAME"
[ -d "$APP" ] || { echo "Нет программы: $APP"; exit 1; }
[ -f "$BG" ] || { echo "Нет фона: $BG"; exit 1; }
[ -d "/Volumes/$VOL" ] && { echo "Сначала извлеките образ «$VOL»"; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/make-dmg.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"; mkdir -p "$STAGE/.background"
APP_NAME="$(basename "$APP")"
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/$LINK"
EXTRA_NAME=""
if [ -n "$EXTRA" ]; then
  EXTRA_NAME="$(basename "$EXTRA")"
  ditto "$EXTRA" "$STAGE/$EXTRA_NAME"
  find "$STAGE/$EXTRA_NAME" -name $'Icon\r' -delete
fi
sips -z 545 900 "$BG" --out "$WORK/bg1.png" >/dev/null
cp "$BG" "$WORK/bg2.png"
tiffutil -cathidpicheck "$WORK/bg1.png" "$WORK/bg2.png" -out "$STAGE/.background/background.tiff" 2>/dev/null

# Finder с вкладками меняет размер текущего окна: запоминаем его и возвращаем в конце
SAVED=$(osascript -e 'tell application "Finder" to if (count of Finder windows) > 0 then get {bounds, sidebar width} of front Finder window' 2>/dev/null | tr -d ' ' || true)

SIZE=$(( $(du -sm "$STAGE" | cut -f1) + 60 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size ${SIZE}m -ov "$WORK/rw.dmg" >/dev/null
hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen >/dev/null
osascript - "$VOL" "$APP_NAME" "$LINK" "$ICON_Y" "$EXTRA_NAME" <<'OSA'
on run argv
  set volName to item 1 of argv
  set appName to item 2 of argv
  set linkName to item 3 of argv
  set iconY to (item 4 of argv) as integer
  set extraName to item 5 of argv
  tell application "Finder"
    tell disk volName
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set bounds of container window to {200, 120, 1100, 693}
      set opts to the icon view options of container window
      set arrangement of opts to not arranged
      set icon size of opts to 144
      set text size of opts to 13
      set shows item info of opts to false
      set shows icon preview of opts to true
      set background picture of opts to file ".background:background.tiff"
      set position of item appName of container window to {270, iconY}
      set position of item linkName of container window to {630, iconY}
      if extraName is not "" then set position of item extraName of container window to {270, 700}
      update without registering applications
      delay 3
      close
      open
      delay 2
      close
    end tell
  end tell
end run
OSA
sync
rm -rf "/Volumes/$VOL/.fseventsd" 2>/dev/null || true
hdiutil detach "/Volumes/$VOL" >/dev/null
mkdir -p "$ROOT/dist"
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$OUT" >/dev/null
hdiutil verify "$OUT" 2>&1 | tail -1

# Проверка: программа внутри совпадает с исходной
MNT="$WORK/check"; mkdir "$MNT"
hdiutil attach "$OUT" -nobrowse -readonly -noautoopen -mountpoint "$MNT" >/dev/null
diff -rq "$MNT/$APP_NAME" "$APP" && echo "Программа в образе совпадает с исходной"
hdiutil detach "$MNT" >/dev/null

if [ -n "$SAVED" ]; then
  IFS=, read -r X1 Y1 X2 Y2 SW <<<"$SAVED"
  osascript -e "tell application \"Finder\" to if (count of Finder windows) > 0 then set bounds of front Finder window to {$X1, $Y1, $X2, $Y2}" -e "tell application \"Finder\" to if (count of Finder windows) > 0 then set sidebar width of front Finder window to $SW" >/dev/null 2>&1 || true
fi
ls -la "$OUT"
echo "ГОТОВО: $OUT"
