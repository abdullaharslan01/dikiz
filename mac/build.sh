#!/bin/bash
# Dikiz.app (+ Dikiz Kamera sanal kamera eklentisi) derler, imzalar ve paketler → dist/Dikiz.dmg
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
  -archivePath "$TMP/Dikiz.xcarchive" -derivedDataPath "$TMP/dd" -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO archive -quiet

mkdir -p "$OUT"
rm -rf "$OUT/Dikiz.app" "$OUT/Dikiz.dmg" "$OUT/Dikiz-Kur.command"

if [ "${DIKIZ_DEV:-0}" = "1" ]; then
  # Yalnızca bu Mac için hızlı geliştirme imzası (başka Mac'te açılmaz).
  cp -R "$TMP/Dikiz.xcarchive/Products/Applications/Dikiz.app" "$TMP/Dikiz.app"
else
  # Developer ID imzası + Apple onayı (notarization): her Mac'te uyarısız açılır.
  # Xcode'da oturum açık hesabın "Cloud Managed Developer ID Certificate" yetkisi olmalı.
  cat > "$TMP/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$TEAM</string>
<key>signingStyle</key><string>automatic</string>
<key>destination</key><string>upload</string>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath "$TMP/Dikiz.xcarchive" -exportOptionsPlist "$TMP/export.plist" \
    -exportPath "$TMP/export" -allowProvisioningUpdates >/dev/null
  echo "• Apple onayı bekleniyor…"
  for i in $(seq 1 60); do
    xcodebuild -exportNotarizedApp -archivePath "$TMP/Dikiz.xcarchive" -exportPath "$TMP/notarized" >/dev/null 2>&1 && break
    sleep 15
  done
  [ -d "$TMP/notarized/Dikiz.app" ] || { echo "✗ Apple onayı tamamlanmadı" >&2; exit 1; }
  cp -R "$TMP/notarized/Dikiz.app" "$TMP/Dikiz.app"
  spctl -a "$TMP/Dikiz.app" && echo "✓ Apple onaylı (Developer ID)"
fi

# Sürükle-bırak kurulum: dist/Dikiz.dmg (Dikiz → Uygulamalar). Gevşek .app bırakmayız:
# Mac'te birden fazla Dikiz kopyası görünmesin.
# dmgbuild yoksa: python3 -m venv <yer> && <yer>/bin/pip install dmgbuild; DMGBUILD=<yer>/bin/dmgbuild
DMGBUILD="${DMGBUILD:-$(command -v dmgbuild || true)}"
swift make-dmg-bg.swift "$TMP/dmg-bg.png" >/dev/null
if [ -n "$DMGBUILD" ]; then
  "$DMGBUILD" -s dmg-settings.py -D app="$TMP/Dikiz.app" -D bg="$TMP/dmg-bg.png" "Dikiz" "$OUT/Dikiz.dmg" >/dev/null
else
  hdiutil create -volname Dikiz -srcfolder "$TMP/Dikiz.app" -ov -format UDZO "$OUT/Dikiz.dmg" >/dev/null
fi
echo "✓ $OUT/Dikiz.dmg"

# Gradle derleme klasörü başka bir yere yönlendirilmişse DIKIZ_APK ile ver.
APK="${DIKIZ_APK:-../app/build/outputs/apk/release/app-release.apk}"
if [ -f "$APK" ]; then
  cp "$APK" "$OUT/Dikiz.apk" && echo "✓ $OUT/Dikiz.apk"
else
  echo "• APK bulunamadı ($APK). Önce: ./gradlew assembleRelease"
fi
