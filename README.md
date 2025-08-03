# AnimeShin
An unofficial AniList app integrated with AniLiberty.

<p align='center'>
<img src='https://github.com/emp0ry/AnimeShin/blob/c9d4433d434b2475454ea213bb3c9d28e93dad75/assets/icons/about.png?raw=true' width='200'>
</p>
<h3 align='center'>
Still in development
</h3>

<br>

# My Notes

## Cleaning
`flutter clean`<br>
`flutter pub get`<br>
`flutter run`

## Android Run Debug
1. Build `flutter build apk --flavor dev`
2. Run Emulator `flutter emulators --launch Phone_Name`
3. Run App `flutter run --flavor dev`

## Windows Run Debug
Run `flutter run -d windows`

# Android Build
Run `flutter build apk --flavor dev --split-per-abi`

# iOS Build
1. Run `flutter build ios --no-codesign`
2. Copy `./build/ios/iphoneos/Runner.app` into a `Payload` directory
3. Compress `Payload` and change extension to `.ipa`