#!/bin/bash
set -e

echo "🔨 Gerando release..."
flutter build apk --release

APK_PATH="build/app/outputs/flutter-apk/app-release.apk"

if [ ! -f "$APK_PATH" ]; then
  echo "❌ Erro: APK não encontrado em $APK_PATH"
  exit 1
fi

echo "📲 Instalando no usuário principal (0)..."
adb install --user 0 "$APK_PATH"

echo "✅ Release instalada com sucesso!"
