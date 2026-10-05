#!/bin/bash
# build_android.sh — Genera el APK/AAB de PESA Tablet
# Requiere: Flutter SDK >= 3.22, Android SDK, JDK 17
# Uso: chmod +x pesa_flutter/build_android.sh && ./pesa_flutter/build_android.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
echo ""
echo "==================================================="
echo "  Servicios PESA — Build Android (APK/AAB)"
echo "==================================================="

# Verificar Flutter
if ! command -v flutter &> /dev/null; then
    echo "[ERROR] Flutter no encontrado. Instala desde https://flutter.dev/docs/get-started/install"
    exit 1
fi

cd "$SCRIPT_DIR"

echo "[INFO] Obteniendo dependencias..."
flutter pub get

echo "[INFO] Compilando APK release (arm64)..."
flutter build apk --release \
    --target-platform android-arm64 \
    --split-per-abi

echo "[INFO] Generando AAB para distribución MDM/internal..."
flutter build appbundle --release

echo ""
echo "[OK] Archivos generados:"
echo "     APK: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
echo "     AAB: build/app/outputs/bundle/release/app-release.aab"
echo ""
echo "[INSTALAR en tablet via ADB]:"
echo "  adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
echo ""