import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

FlutterSecureStorage buildSecureStorage() {
  if (Platform.isMacOS) {
    // No accessGroup on macOS
    return const FlutterSecureStorage(mOptions: MacOsOptions());
  } else if (Platform.isIOS) {
    // Optional: nicer behavior on device restart
    return const FlutterSecureStorage(
      iOptions: IOSOptions(
        accessibility: KeychainAccessibility.first_unlock,
      ),
    );
  } else if (Platform.isAndroid) {
    return const FlutterSecureStorage(
      aOptions: AndroidOptions(),
    );
  }
  return const FlutterSecureStorage();
}