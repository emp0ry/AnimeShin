<p align="center">
  <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/icons/about.png?raw=true" width="160" alt="AnimeShin Logo">
</p>

<h1 align="center">AnimeShin</h1>
<p align="center">
  A modern, unofficial AniList client with Russian titles and community sources (Sora-compatible).
  <br>
  Track anime & manga, update progress with gestures, watch episodes, and get notifications - all in one place.
</p>

<p align="center">
  <a href="https://github.com/emp0ry/AnimeShin/releases/latest">
    <img src="https://img.shields.io/github/v/release/emp0ry/AnimeShin?logo=github&color=5865F2" alt="Latest Release">
  </a>
  <a href="https://github.com/emp0ry/AnimeShin/actions/workflows/build-all.yml">
    <img src="https://github.com/emp0ry/AnimeShin/actions/workflows/build-all.yml/badge.svg" alt="Build All (bundle)">
  </a>
  <a href="https://img.shields.io/github/downloads/emp0ry/AnimeShin/total?color=ff6d00&label=Total%20Downloads">
    <img src="https://img.shields.io/github/downloads/emp0ry/AnimeShin/total?color=ff6d00&label=Total%20Downloads" alt="Total Downloads">
  </a>
  <a href="https://flutter.dev">
    <img src="https://img.shields.io/badge/Flutter-3.0%2B-44D1FD?logo=flutter" alt="Flutter Version">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/github/license/emp0ry/AnimeShin?color=00C853" alt="License: MIT">
  </a>
</p>

---

## ✨ Features

- **🎮 AniList Sync**  
  Full AniList integration for tracking anime and manga.

- **🏠 Russian Titles & Search**  
  Automatically displays Russian titles from Shikimori.  
  Supports **search by Russian titles** in your library.

- **▶️ Watch (Sora sources)**  
  Watch episodes using community sources (Sora-compatible).

- **📁 Export Anime/Manga list**
  Export your anime or manga list in MyAnimeList or Shikimori format.
  Export button in the top-right corner of your profile page.

- **🔗 Extra Links**  
  Direct links to Shikimori pages.

- **👆 Swipe-Based Progress**  
  Swipe left/right on covers to update episode or chapter progress instantly.

- **🔔 Notifications**  
  - New episode aired  

- **📝 Personal Notes & Scores**  
  Rate entries and attach personal notes right in your list.

- **🔒 Secure Authentication**  
  OAuth-based login with AniList.

- **💻 Multi-Platform**  
  Android, iOS, Windows - macOS & Linux planned.

- **⚙️ Settings**  
  Toggle options for Russian title visibility and scheduled new episode air notifications.

---

## 📸 Preview (outdated)

<p align="center">
  <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/1.PNG?raw=true" width="32%">
  <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/2.PNG?raw=true" width="32%">
  <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/3.PNG?raw=true" width="32%">
</p>

<details>
  <summary>See more screenshots</summary>
  <p align="center">
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/4.PNG?raw=true" width="32%">
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/5.PNG?raw=true" width="32%">
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/6.PNG?raw=true" width="32%">
  </p>
  <p align="center">
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/7.PNG?raw=true" width="48%">
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/8.PNG?raw=true" width="48%">
  </p>
</details>

---

## 📈 Roadmap

- Full stable anime player  
- Linux support  
- Apple widgets  
- Full Russian UI localization  

---

## 💖 Support

If you love AnimeShin - fuel development with a coffee!  

[![Buy Me a Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/emp0ry)  

---

## 📦 Release Builds

Use these commands to produce release locally.

**Android (split by ABI):**

```bash
flutter build apk --release --flavor dev --split-per-abi
```

**iOS (no code signing):**

```bash
flutter build ios --no-codesign
```

**macOS:**

```bash
flutter build macos
```

**Windows:**

```bash
flutter build windows --release
```

**Linux:**

```bash
flutter build linux --release
```

---

# Installation Guide

This guide explains how to install **AnimeShin** on different operating systems.

---

## 🪟 Windows

### Download

* File: `AnimeShin-win-vX.Y.Z.zip`

### Install

1. Download the `.zip` file
2. Right-click → **Extract All**
3. Open the extracted folder
4. Run **AnimeShin.exe**

✅ No installation required  
✅ Portable (can be moved anywhere)

> If Windows SmartScreen appears, click **More info → Run anyway**

---

## 🐧 Linux (Ubuntu, Debian, Arch, Fedora, etc.)

### Option 1 (Recommended): AppImage

#### Download

* File: `AnimeShin-linux-vX.Y.Z.AppImage`

#### Install & Run

```bash
chmod +x AnimeShin-linux-vX.Y.Z.AppImage
./AnimeShin-linux-vX.Y.Z.AppImage
```

Or:

* Right-click → **Properties**
* Enable **Allow executing file as program**
* Double-click to run

✅ Works on most Linux distributions  
✅ No installation needed

---

### Option 2: Portable tar.gz

#### Download

* File: `AnimeShin-linux-vX.Y.Z.tar.gz`

#### Install & Run

```bash
tar -xzf AnimeShin-linux-vX.Y.Z.tar.gz
cd AnimeShin
./AnimeShin
```

⚠️ May require system libraries:

```bash
sudo apt install libgtk-3-0 liblzma5
```

---

## 🍎 macOS

### Download

* File: `AnimeShin-macos-vX.Y.Z.dmg`

### Install

1. Open the `.dmg` file
2. Drag **AnimeShin** into **Applications**
3. Open **Applications → AnimeShin**

⚠️ First launch warning:

* Right-click **AnimeShin**
* Click **Open**
* Confirm **Open**

(Apple Gatekeeper limitation — normal for unsigned apps)

---

## 🤖 Android

### Download

* File: `AnimeShin-android-vX.Y.Z.apk`

### Important

⚠️ This APK is **unsigned**  
You must **sign it before installing**, or install using a custom installer.

### Install (after signing)

```bash
adb install AnimeShin-android-vX.Y.Z.apk
```

Or install via file manager if your device allows unsigned APKs.

---

## 🍏 iOS

### Download

* File: `AnimeShin-ios-vX.Y.Z.ipa`

### Important

⚠️ This IPA is **NOT signed**  
You must sign it manually before installation.

### Install options

* [SideStore](https://sidestore.io/) + [LiveContainer](https://github.com/LiveContainer/LiveContainer) (recommended)
* Xcode
* AltStore
* Sideloadly
* Fastlane / codesign

---

## ❓ Troubleshooting

**App does not open on macOS**

* Use **Right-click → Open** the first time

**Android APK won’t install**

* APK must be signed
* Enable “Install unknown apps”

**Linux AppImage doesn’t start**

```bash
chmod +x AnimeShin-linux-vX.Y.Z.AppImage
```

---

## 🙏 Credits

Special thanks to [@lotusprey](https://github.com/lotusprey) for [Otraku](https://github.com/lotusprey/otraku) - the inspiration for AnimeShin.  
Thanks to [Sora](https://github.com/cranci1) for the source ecosystem and compatibility inspiration.  
Thanks to [Shikimori](https://shikimori.one/) for Russian titles & metadata.

## 🔒 Privacy & Policy

AnimeShin respects your privacy. The app **does not collect personal data**, and all settings are stored locally on your device.  

For details on data usage, third-party services (AniList, Shikimori, Sora sources), and security measures, please read the full [Privacy Policy](PRIVACY_POLICY.md).

---

Made with ❤️ by [emp0ry](https://github.com/emp0ry)