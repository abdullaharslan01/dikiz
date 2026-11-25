#!/bin/bash
# Dikiz.app (+ Dikiz Kamera sanal kamera eklentisi) derler ve imzalar → dist/Dikiz.app
#
# Gerekenler: Xcode, XcodeGen (brew install xcodegen) ve Xcode'da oturum açılmış,
# sistem eklentisi imzalayabilen (ücretli) bir Apple geliştirici hesabı.
#
# Ekip kimliği koda yazılmaz. Şunlardan biriyle ver:
#   DIKIZ_TEAM=ABCDE12345 ./mac/build.sh
#   echo ABCDE12345 > mac/.team      (bu dosya git'e girmez)
set -euo pipefail
cd "$(dirname "$0")"
OUT=../dist
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

TEAM="${DIKIZ_TEAM:-$(cat .team 2>/dev/null || true)}"
if [ -z "$TEAM" ]; then
  echo "Apple ekip kimliği gerekli: DIKIZ_TEAM=XXXXXXXXXX ./mac/build.sh  (ya da mac/.team dosyası)" >&2
  exit 1
fi

# simge
mkdir -p Resources
if [ ! -f Resources/AppIcon.icns ]; then
  swift make-icon.swift "$TMP/icon.png"
  ICONSET="$TMP/AppIcon.iconset"; mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

xcodegen generate --quiet
xcodebuild -project Dikiz.xcodeproj -scheme Dikiz -configuration Release \
  -derivedDataPath "$TMP/dd" -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  DEVELOPMENT_TEAM="$TEAM" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO build -quiet

mkdir -p "$OUT"
rm -rf "$OUT/Dikiz.app"
cp -R "$TMP/dd/Build/Products/Release/Dikiz.app" "$OUT/Dikiz.app"
echo "✓ $OUT/Dikiz.app"

# Kurulum paketi: dist/ içinde Dikiz.app + Dikiz.apk + Dikiz-Kur.command
cp Dikiz-Kur.command "$OUT/Dikiz-Kur.command"
chmod +x "$OUT/Dikiz-Kur.command"
# Gradle derleme klasörü başka bir yere yönlendirilmişse DIKIZ_APK ile ver.
APK="${DIKIZ_APK:-../app/build/outputs/apk/release/app-release.apk}"
if [ -f "$APK" ]; then
  cp "$APK" "$OUT/Dikiz.apk" && echo "✓ $OUT/Dikiz.apk"
else
  echo "• APK bulunamadı ($APK). Önce: ./gradlew assembleRelease"
fi
