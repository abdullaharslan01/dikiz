#!/bin/bash
# Dikiz — tek tıkla kurulum
#  1) Dikiz.app'i Uygulamalar klasörüne kopyalar
#  2) Telefon USB ile bağlıysa Dikiz.apk'yı telefona kurar
#  3) Her ikisini de başlatır
cd "$(dirname "$0")"
clear
echo "👁  Dikiz kurulumu"
echo "──────────────────"

# 1) Mac uygulaması
if [ -d "Dikiz.app" ]; then
  pkill -x Dikiz 2>/dev/null
  rm -rf /Applications/Dikiz.app
  cp -R Dikiz.app /Applications/ && xattr -dr com.apple.quarantine /Applications/Dikiz.app 2>/dev/null
  echo "✓ Mac uygulaması Uygulamalar klasörüne kuruldu"
fi

# 2) Telefon uygulaması (adb varsa)
ADB=$(command -v adb)
for c in "$ANDROID_HOME/platform-tools/adb" "$HOME/Library/Android/sdk/platform-tools/adb" /Volumes/*/Android/sdk/platform-tools/adb; do
  [ -z "$ADB" ] && [ -x "$c" ] && ADB="$c"
done

if [ -z "$ADB" ]; then
  echo
  echo "• Telefon kurulumu: Dikiz.apk dosyasını telefona gönder (Telegram, Drive, kablo…) ve aç."
else
  echo
  echo "Telefonu USB ile tak. (Ayarlar → Geliştirici seçenekleri → USB hata ayıklama + USB üzerinden yükle açık olmalı)"
  export ADB_LIBUSB=1   # macOS'ta bazı telefonlarla (ör. Xiaomi) daha kararlı
  "$ADB" kill-server >/dev/null 2>&1
  "$ADB" start-server >/dev/null 2>&1
  SERIAL=""
  for i in $(seq 1 30); do
    SERIAL=$("$ADB" devices | awk 'NR>1 && $2=="device"{print $1; exit}')
    [ -n "$SERIAL" ] && break
    [ $i -eq 3 ] && echo "…telefon bekleniyor (telefonda 'USB hata ayıklamaya izin ver' çıkarsa İzin ver de)"
    sleep 1
  done
  if [ -z "$SERIAL" ]; then
    echo "✗ Telefon görünmedi. Dikiz.apk dosyasını telefona elle de kurabilirsin."
  else
    echo "Telefon bulundu ($SERIAL), kuruluyor… (telefonda onay sorarsa 'Yükle'ye bas)"
    "$ADB" -s "$SERIAL" push Dikiz.apk /data/local/tmp/Dikiz.apk >/dev/null
    if "$ADB" -s "$SERIAL" shell pm install -r /data/local/tmp/Dikiz.apk | grep -q Success; then
      echo "✓ Telefon uygulaması kuruldu"
      "$ADB" -s "$SERIAL" shell am start -n app.dikiz/.MainActivity >/dev/null 2>&1
    else
      echo "✗ Telefona kurulamadı. Dikiz.apk dosyasını telefona elle kur."
    fi
    "$ADB" -s "$SERIAL" shell rm -f /data/local/tmp/Dikiz.apk >/dev/null 2>&1
  fi
fi

echo
echo "Son adım: telefonu Mac ile aynı Wi‑Fi'ye bağla, telefonda Dikiz'i aç."
echo "Mac'te menü çubuğunda 👁 belirir, görüntü kendiliğinden açılır."
open /Applications/Dikiz.app
echo
read -n 1 -s -r -p "Kapatmak için bir tuşa bas…"
