<p align="center">
  <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/icons/about.png?raw=true" width="160" alt="AnimeShin Logo">
</p>

<h1 align="center">AnimeShin</h1>
<p align="center">
  A modern, unofficial AniList companion application.
  <br>
  Track anime & manga, manage your library, and optionally open media using user-configured extensions.
</p>

<p align="center">
  <a href="https://github.com/emp0ry/AnimeShin/releases/latest">
    <img src="https://img.shields.io/github/v/release/emp0ry/AnimeShin?logo=github&color=5865F2" alt="Latest Release">
  </a>
  <a href="https://github.com/emp0ry/AnimeShin/actions/workflows/build-all-no-linux.yml">
    <img src="https://github.com/emp0ry/AnimeShin/actions/workflows/build-all-no-linux.yml/badge.svg" alt="Build (bundle)">
  </a>
  <a href="https://img.shields.io/github/downloads/emp0ry/AnimeShin/total?color=ff6d00&label=Total%20Downloads">
    <img src="https://img.shields.io/github/downloads/emp0ry/AnimeShin/total?color=ff6d00&label=Total%20Downloads" alt="Total Downloads">
  </a>
  <a href="https://flutter.dev">
    <img src="https://img.shields.io/badge/Flutter-3.0%2B-44D1FD?logo=flutter" alt="Flutter Version">
  </a>
  <a href="LICENSE">
    <img src="https://img.shields.io/github/license/emp0ry/AnimeShin?color=00C853" alt="License: GNU">
  </a>
</p>

---

## ✨ Features

- **🎮 AniList Sync**  
  Full AniList integration for tracking anime and manga.

- **🏠 Russian Titles & Search**  
  Displays Russian titles from Shikimori and supports Russian searching.

- **📚 Library Management**  
  Update progress with gestures, rate entries, and attach personal notes.

- **📁 Export Lists**
  Export your anime or manga list in MyAnimeList or Shikimori format.

- **🔗 Extra Links**  
  Quickly open related pages in external services.

- **👆 Swipe-Based Progress**  
  Swipe left/right on covers to update episode or chapter progress instantly.

- **🔔 Notifications**  
  Optional notifications about airing schedule changes.

- **🔒 Secure Authentication**  
  OAuth-based login with AniList. Credentials are never stored.

- **▶️ Media Player**
  Built-in generic player capable of opening media provided by user-configured external extensions.

- **🧩 Optional Extensions**
  Users may configure third-party extensions that connect directly to external services.

- **💻 Multi-Platform**  
  Android, iOS, macOS, Windows.

- **📝 Personal Notes & Scores**  
  Rate entries and attach personal notes right in your list.

- **⚙️ Settings**  
  Toggle options for Russian title visibility and scheduled new episode air notifications.

---

## ⚠️ Legal Notice

AnimeShin does **not** provide, host, distribute, or store any media content.

The application is primarily an AniList client and media library manager.  
It includes a generic player that can open media supplied by external services configured by the user.

No content sources are included with the application.

The developer does not operate, control, maintain, or endorse third-party services or extensions.  
Users are solely responsible for the sources they configure and access.

---

## 📸 Preview

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
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/7.PNG?raw=true" width="32%">
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/8.PNG?raw=true" width="32%">
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/9.PNG?raw=true" width="32%">
  </p>
  <hr>
  <p align="center">An example of what the player looks like</p>
  <p align="center">
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/10.PNG?raw=true" width="48%">
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/11.PNG?raw=true" width="48%">
  </p>
</details>

---

## 📈 Roadmap

- Improved UI performance
- Widgets
- Additional localization

---

## 💖 Support

If you love AnimeShin - fuel development with a coffee!  

[![Buy Me a Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/emp0ry)  

---

## 📦 Release Builds

Use these commands to produce a release locally.

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

## 🪟 Windows

Download the Windows build from Assets below.
* File: `AnimeShin-win-vX.Y.Z.zip`

### Install

Download → Extract → Run AnimeShin.exe

✅ No installation required  
✅ Portable (can be moved anywhere)

> If Windows SmartScreen appears, click **More info → Run anyway**

---

## 🍎 macOS

Download the macOS build from Assets below.
* File: `AnimeShin-macos-vX.Y.Z.dmg`

### Install

Open dmg → Drag to Applications

First launch: Right click → Open

---

## 🍏 iOS

Download the iOS build from Assets below.
* File: `AnimeShin-ios-vX.Y.Z.ipa`

### Install options

iOS requires sideloading (AltStore / SideStore / Sideloadly). No jailbreak required.
* [SideStore](https://sidestore.io/) + [LiveContainer](https://github.com/LiveContainer/LiveContainer) (recommended)
* Xcode
* AltStore
* Sideloadly
* Fastlane / codesign

---

## 🤖 Android

Download the Android build from Assets below.
* File: `AnimeShin-android-vX.Y.Z.apk`

You can install the APK normally.

---

## ❓ Troubleshooting

**App does not open on macOS**

* Use **Right-click → Open** the first time

**Android APK won’t install**

* If installation fails: enable “Install unknown apps” in system settings.

---

## 🙏 Credits

Special thanks to [@lotusprey](https://github.com/lotusprey) for [Otraku](https://github.com/lotusprey/otraku) - the inspiration for AnimeShin.  
Thanks to [Sora](https://github.com/cranci1) for the source ecosystem and compatibility inspiration.  
Thanks to [Shikimori](https://shikimori.one/) for Russian titles & metadata.

## 🔒 Privacy & Legal

AnimeShin does not collect personal data.

- Privacy Policy: [PRIVACY_POLICY.md](PRIVACY_POLICY.md)
- Legal Notice: [LEGAL_NOTICE.md](LEGAL_NOTICE.md)

---

Made with ❤️ by [emp0ry](https://github.com/emp0ry)