# 📜 Privacy Policy for AnimeShin

*Last updated: **August 21, 2025***

## 1. Introduction

AnimeShin (“the App”) is an **unofficial AniList client** developed by **emp0ry**.
This Privacy Policy explains what information is (and isn’t) collected when you use the App.

## 2. Data We Collect

* **No Personal Data Collected by the App**: AnimeShin does not collect, store, or sell your personal information.
* **App Preferences**: Settings such as language, dub options, and UI preferences are stored **locally on your device** only.
* **Playback Caching (local only)**: The App may cache artwork or media metadata locally to improve performance. This cache never leaves your device.

## 3. Third-Party Services

AnimeShin integrates with the following services to provide content and features.
**Requests to these services are made directly from your device** and may expose your **IP address, user agent, and other standard HTTP headers** to the respective service.

* **AniList API** — Used for authentication and syncing your anime/manga list (OAuth2). Your AniList account data is handled by AniList.  
  Policy: [AniList Privacy Policy](https://anilist.co/terms)
* **Shikimori** — Used to fetch Russian titles and additional metadata.  
  Policy: [Shikimori Privacy Policy](https://shikimori.one/terms)
* **Sora sources (scripts)** — AnimeShin can load community “source” scripts (Sora-compatible) to search and play content.
  These scripts run locally in the app and typically make network requests directly to the configured third-party sites.
  Credit: https://github.com/cranci1

> **Note:** When you play video from any third-party source, media segments are streamed **directly from that source’s servers**. The App does **not** proxy, log, or re-route your traffic through its own servers. (In some builds the App may use a **local, on-device** HLS helper strictly to fix headers/compatibility; it does not transmit data to any server controlled by the App.)

## 4. Analytics

The **GitHub Pages** site for AnimeShin may use **Google Analytics** to understand visits and improve the project’s visibility.
**The App itself contains no analytics and does not collect personally identifiable information.**

## 5. Security

* Authentication with AniList uses **OAuth2**.
* The App does not store your AniList credentials; only the issued **access token** is kept **locally on your device** to enable syncing.

## 6. Children’s Privacy

AnimeShin does not knowingly collect personal data from children under 13.

## 7. Your Choices

* You may clear local caches and preferences in the App or via your OS settings.
* You may revoke AnimeShin’s access to your AniList account from your AniList security settings at any time.

## 8. Changes to This Policy

This Privacy Policy may be updated from time to time. Updates will be published on the GitHub repository and project website.

## 9. Contact

For questions, issues, or concerns about privacy, please contact:  
**GitHub:** [emp0ry](https://github.com/emp0ry)
