import 'dart:io' show Platform;

bool get notificationsSupported => !Platform.isWindows;
