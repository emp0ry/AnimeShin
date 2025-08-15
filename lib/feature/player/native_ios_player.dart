import 'dart:io' show Platform;
import 'package:flutter/services.dart';

class NativeIosPlayer {
  static const _channel = MethodChannel('native_ios_player');

  static Future<void> present({
    required String url,
    double positionSeconds = 0.0,
    double rate = 1.0,
  }) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('present', {
        'url': url,
        'position': positionSeconds,
        'rate': rate,
      });
    } catch (_) {}
  }
}
