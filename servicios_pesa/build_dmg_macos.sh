#!/usr/bin/env bash
# Empaqueta Servicios PESA para macOS: PyInstaller (.app) + hdiutil (.dmg)
set -euo pipefail
cd "$(dirname "$0")"

PYI="../.venv/bin/pyinstaller"
APP="dist/Servicios_PESA.app"
OUT_DIR="Ejecutables/macOS"
DMG="$OUT_DIR/Servicios_PESA_macOS.dmg"
STAGE="build/dmg_staging"

echo "==> PyInstaller"
"$PYI" --noconfirm Servicios_PESA_mac.spec

[ -d "$APP" ] || { echo "ERROR: no se generó $APP"; exit 1; }

echo "==> Preparando staging"
rm -rf "$STAGE"
mkdir -p "$STAGE" "$OUT_DIR"
ditto "$APP" "$STAGE/Servicios_PESA.app"
ln -s /Applications "$STAGE/Applications"

echo "==> hdiutil create"
rm -f "$DMG"
hdiutil create -volname "Servicios PESA" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

echo "==> hdiutil verify"
hdiutil verify "$DMG"

rm -rf "$STAGE"
ls -lh "$DMG"
