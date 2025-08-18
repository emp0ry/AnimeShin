<p align="center">
  <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/icons/about.png?raw=true" width="160" alt="AnimeShin Logo">
</p>

<h1 align="center">AnimeShin</h1>
<p align="center">
  A modern, unofficial AniList client with Russian titles, AniLiberty voice-over tracking, and episode watching for AniLiberty dubs.
  <br>
  Track anime & manga, update progress with gestures, watch dubbed episodes, and get notified about new releases and dubs — all in one place.
</p>

<p align="center">
  <a href="https://github.com/emp0ry/AnimeShin/releases/latest">
    <img src="https://img.shields.io/github/v/release/emp0ry/AnimeShin?logo=github&color=5865F2" alt="Latest Release">
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

- **🗣 AniLiberty Dub Checker**  
  Indicates whether the latest episode is dubbed directly in your library.

- **▶️ AniLiberty Watch**  
  Watch AniLiberty-dubbed episodes directly from the app.

- **🔗 Extra Links**  
  Direct links to Shikimori and AniLiberty release pages.

- **👆 Swipe-Based Progress**  
  Swipe left/right on covers to update episode or chapter progress instantly.

- **🔔 Notifications**  
  - New episode aired  
  - (Planned) New AniLiberty voice-over release

- **📝 Personal Notes & Scores**  
  Rate entries and attach personal notes right in your list.

- **🔒 Secure Authentication**  
  OAuth-based login with AniList.

- **💻 Multi-Platform**  
  Android, iOS, Windows — macOS & Linux planned.

- **⚙️ Settings**  
  Toggle options for AniLiberty dub display, AniLiberty watch button, Russian title visibility, and scheduled new episode air notifications.

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
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/7.PNG?raw=true" width="48%">
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/8.PNG?raw=true" width="48%">
  </p>
</details>

---

## 📈 Roadmap

- Full stable anime player  
- macOS & Linux support  
- Notifications for new AniLiberty dubs  
- Import/export of watchlist and progress  
- Home screen widgets  
- Full Russian UI localization  

---

## 💖 Support

If you love AnimeShin — fuel development with a coffee!  

[![Buy Me a Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/emp0ry)  

---

## 🧪 Development

```bash
# Windows
flutter run -d windows

# Android
flutter emulators --launch <your_emulator_name>
flutter run --flavor dev

# iOS
flutter run -d ios
```

---

## 📦 Release Builds

**Android (split by ABI):**

```bash
flutter build apk --flavor dev --split-per-abi
```

**iOS (no code signing):**

```bash
flutter build ios --no-codesign
```

**Windows:**

```bash
flutter build windows
```

---

## 🙏 Credits

Special thanks to [@lotusprey](https://github.com/lotusprey) for [Otraku](https://github.com/lotusprey/otraku) — the inspiration for AnimeShin.  
Thanks to [AniLiberty](https://aniliberty.pro/) for providing voice-over releases and [Shikimori](https://shikimori.one/) for Russian titles & metadata.

## 🔒 Privacy & Policy

AnimeShin respects your privacy. The app **does not collect personal data**, and all settings are stored locally on your device.  

For details on data usage, third-party services (AniList, AniLiberty, Shikimori), and security measures, please read the full [Privacy Policy](PRIVACY_POLICY.md).

---

Made with ❤️ by [emp0ry](https://github.com/emp0ry)