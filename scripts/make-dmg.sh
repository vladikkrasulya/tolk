#!/bin/bash
# Packs build/Tolk.app into build/Tolk-<version>.dmg: the app, an Applications shortcut and a Russian how-to.
# Usage: scripts/build-app.sh && scripts/make-dmg.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Tolk.app"
[ -d "$APP" ] || { echo "No $APP — run scripts/build-app.sh first." >&2; exit 1; }
VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="$ROOT/build/Tolk-$VER.dmg"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/Tolk.app"
ln -s /Applications "$STAGE/Программы"
cat > "$STAGE/Как установить.txt" <<TXT
Tolk $VER — переводчик для Mac

1. Перетащите Tolk в папку «Программы» (рядом в этом окне).
2. Откройте «Программы» и запустите Tolk.
   Mac скажет, что не может проверить разработчика, — нажмите «Готово».
3. Откройте «Системные настройки» → «Конфиденциальность и безопасность»,
   прокрутите вниз и нажмите «Всё равно открыть» рядом с Tolk (спросит пароль).
   Это нужно один раз.
4. Разрешите Tolk «Универсальный доступ» — без этого не работает перевод по двойному ⌘C.
   Для перевода области экрана (⌥⇧S) Mac один раз попросит «Запись экрана»,
   после этого перезапустите Tolk.

Как пользоваться:
• Выделите текст и дважды быстро нажмите ⌘C — рядом появится перевод.
• ⌥⇧S — выделить область экрана (например, фото страницы) и перевести.
• Фото страниц можно просто перетащить в окно Tolk → «Фото и скриншоты».
• Иконка Tolk в строке меню сверху — настройки, глоссарий, выход.

Дома переводит модель на домашнем сервере, вне дома — Google.
TXT

rm -f "$OUT"
hdiutil create -volname "Tolk $VER" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
codesign --force --sign "${TOLK_SIGN_ID:-Tolk Local Signing}" "$OUT" 2>/dev/null || true
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
