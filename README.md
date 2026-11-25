# 👁 Dikiz

**Android telefonunu Mac'te kamera olarak kullan.**

- **Uzaktan izle:** Telefonu istediğin yere koy, gördüğünü Mac ekranında canlı izle. Görüntü ters gelmez, sesle yönetebilirsin.
- **Toplantıda web kamerası:** Meet, Zoom, Teams ve FaceTime'da **“Dikiz Kamera”** olarak seçilir.

Telefon ve Mac aynı Wi‑Fi'de olsun, yeter. Kablo, hesap ya da bulut yok; görüntü evinin ağından çıkmaz.

## Kurulum

**1. Telefon (Android 8+)**
[Releases](../../releases/latest) sayfasından `Dikiz.apk` dosyasını indir ve telefona kur.

**2. Mac (macOS 13+), isteğe bağlı**
Sadece görüntüyü izlemek istiyorsan Mac'e bir şey kurmana gerek yok: telefonda yazan adresi tarayıcıda aç.
Sesli komut, ön ayna ve toplantı kamerası için Mac uygulamasını derle (aşağıda).

## Kullanım

1. Telefonda **Dikiz**'i aç.
2. Mac'te **Dikiz**'i aç. Menü çubuğunda 👁 belirir ve görüntü açılır.
3. İlk seferde iki soru gelir: *görüntü düz mü?* ve *sağ elin hangi tarafta?* Bundan sonra sağ hep sağdır.
4. Toplantıda kamera olarak **Dikiz Kamera**'yı seç. Ters ya da yan görünürse 👁 menüsünden düzelt.

## Neler var

- 🧭 **Yön ayarı:** iki soruda doğru yön
- 🎤 **Sesli komut:** *dondur, devam, yakınlaş, uzaklaş, sol, sağ, ışık, fotoğraf…*
- 💻 **Ön ayna:** Mac kamerası yanda ayna gibi açılır, arka ve ön aynı anda görünür
- 📐 **Çizgiler ve simetri:** düz bir hat ve iki tarafı karşılaştırmak için
- 🔭 **Lens seçimi:** geniş, ana ve tele lensler tek tuşla
- 🎯 **Odak ve ışık:** tıkla-odakla, pozlama kilidi, telefon feneri, 60 fps
- 📹 **Dikiz Kamera:** macOS sanal kamerası, menüden ayna / çevir / döndür
- 🔒 **Telefon kilitlense de** yayın sürer

### Kısayollar

| Tuş | İşlev | Tuş | İşlev |
|---|---|---|---|
| `V` | Sesli komut | `Boşluk` | Dondur |
| `W` | Ön ayna | `S` | Fotoğraf kaydet |
| `M` | Ayna | `L` | Çizgiler |
| `R` | Döndür | `Y` | Simetri |
| `1` `2` `3` | Arka / sol / sağ görünüm | `T` | Işık |
| Tekerlek | Yakınlaştır | Tıkla | Odakla |

## Kendin derle

**Android**, gerekenler: JDK 17+ ve Android SDK (Android Studio ile gelir)

```bash
./gradlew assembleRelease
# → app/build/outputs/apk/release/app-release.apk
```

**Mac**, gerekenler: Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) ve Xcode'da oturum açılmış **ücretli** bir Apple geliştirici hesabı (sanal kamera bir sistem eklentisi olduğu için).

```bash
brew install xcodegen
DIKIZ_TEAM=<Apple ekip kimliğin> ./mac/build.sh
# → dist/Dikiz.app  (Uygulamalar klasörüne taşı ve aç)
```

İlk açılışta **Sistem Ayarları → Genel → Giriş Öğeleri ve Uzantılar → Kamera Uzantıları** altında Dikiz'e izin ver.

## Nasıl çalışır

Telefon görüntüyü Wi‑Fi'de MJPEG olarak yayınlar ve kendini Bonjour ile duyurur. Mac uygulaması telefonu bulur, görüntüyü `127.0.0.1` üzerinden tarayıcıya ve sanal kameraya verir. Tarayıcı ancak bu sayede mikrofonu ve Mac kamerasını kullanabiliyor.

```
app/                  Android uygulaması (Kotlin, CameraX, Compose)
app/src/main/assets/  izleme arayüzü (tek HTML dosyası)
mac/                  menü çubuğu uygulaması (Swift)
mac/camera/           Dikiz Kamera, CoreMediaIO sanal kamera eklentisi
```

## Teşekkürler

İkonlar: [Tabler Icons](https://github.com/tabler/tabler-icons) (MIT)
