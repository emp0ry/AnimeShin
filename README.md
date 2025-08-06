<p align="center">
  <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/icons/about.png?raw=true" width="160" alt="AnimeShin Logo">
</p>

<h1 align="center">AnimeShin</h1>
<p align="center">
  A modern, unofficial AniList client with Russian voice-over tracking via AniLiberty.
  <br>
  Track anime & manga, update progress with gestures, receive notifications when a new episode is aired — all in one place.
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
  Track your anime and manga seamlessly via full AniList integration.

- **🏠 Russian Titles**  
  Displays Russian titles in your user library.

- **🗣 AniLiberty Dub Checker**  
  See which episodes are already dubbed and which are still pending voice-over.

- **👆 Swipe-Based Progress**  
  Swipe left/right on covers to update episode or chapter progress.

- **🔔 Episode Airing Notification**
  Notifying when a new episode has aired. (tested on ios)

- **📝 Personal Notes & Scores**  
  Rate entries and attach personal notes directly in your library.

- **🔒 Secure Authentication**  
  OAuth-based login with AniList ensures security and privacy of your account.

- **🖥 Multi-Platform**  
  Works on Android, iOS, and Windows.  
  Planned: macOS & Linux support.

---

## 📸 Preview

<p align="center">
  <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/1.PNG?raw=true" width="25%">
  <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/2.PNG?raw=true" width="25%">
  <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/3.PNG?raw=true" width="25%">
</p>
<p align="center">
<details>
  <summary>See more screenshots</summary>
  <p align='center'>
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/4.PNG?raw=true" width="25%">
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/5.PNG?raw=true" width="25%">
    <img src="https://github.com/emp0ry/AnimeShin/blob/main/assets/screenshots/6.PNG?raw=true" width="25%">
  </p>
</details>

---

## 📈 Roadmap

- Support for macOS and Linux
- Notifications for new AniLiberty voice-over releases
- Links to AniLiberty anime/episode pages
- Import/export of watchlist and progress
- Home screen widgets
- Full Russian language localization

---

## 💖 Support the Project  

Love AnimeShin? Fuel its development with a coffee!  

[![Buy Me a Coffee](https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png)](https://www.buymeacoffee.com/emp0ry)  

---

## 🧪 Development

Run the app on your platform of choice:

```bash
# Windows
flutter run -d windows

# Android
flutter build apk --flavor dev
flutter emulators --launch <your_emulator_name>
flutter run --flavor dev

# iOS
flutter run -d ios
```

---

## 📦 Release Builds

**Android APK (per ABI):**

```bash
flutter build apk --flavor dev --split-per-abi
```

**iOS (without code signing):**

```bash
flutter build ios --no-codesign
# Create .ipa manually from build/ios/iphoneos/Runner.app
```

**Windows:**

```bash
flutter build windows
```

---

## 🙏 Acknowledgments

Special thanks to [@lotusprey](https://github.com/lotusprey) for the original work on [Otraku](https://github.com/lotusprey/otraku), which served as inspiration for this project.

---

Made with ❤️ by [emp0ry](https://github.com/emp0ry)