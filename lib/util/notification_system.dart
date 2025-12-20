import 'dart:io';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:animeshin/util/routes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:timezone/timezone.dart' as tz;

class NotificationSystem {
  NotificationSystem._();

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  static bool _channelsCreated = false;
  static bool _askedIosPerms = false;
  static bool _tzReady = false;

  /// Ensure time zone database is ready.
  static Future<void> _ensureTz() async {
    if (_tzReady) return;
    // Expect that `timezone` package is initialized at app start,
    // but if not, tz.local still works with system local time zone.
    // Mark as ready to avoid re-doing work.
    _tzReady = true;
  }

  /// Create Android channel(s) once.
  static Future<void> _ensureAndroidChannels() async {
    if (_channelsCreated) return;
    if (Platform.isAndroid) {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (android != null) {
        await android.createNotificationChannel(const AndroidNotificationChannel(
          'episode_channel',
          'Episode releases',
          description: 'Notifications about new episode releases',
          importance: Importance.high,
        ));
      }
    }
    _channelsCreated = true;
  }

  /// Ask permissions if needed (iOS/macOS and Android 13+ post-notifications).
  static Future<void> _ensurePermissions() async {
    if (Platform.isIOS || Platform.isMacOS) {
      if (_askedIosPerms) return;
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin>();
      final mac = _plugin
          .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin>();
      await ios?.requestPermissions(alert: true, badge: true, sound: true);
      await mac?.requestPermissions(alert: true, badge: true, sound: true);
      _askedIosPerms = true;
    } else if (Platform.isAndroid) {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      // Android 13+ POST_NOTIFICATIONS
      await android?.requestNotificationsPermission();

      // Exact alarm permission (Android 12+) — optional ask.
      // DO NOT force open settings here; we will detect and fallback.
      // If you do want to ask, uncomment:
      // final exactGranted = await android?.canScheduleExactNotifications() ?? false;
      // if (!exactGranted) {
      //   await android?.requestExactAlarmsPermission();
      // }
    }
  }

  /// Generates a safe file name for images.
  static String safeFileName(String base, int episode) {
    final cleaned = base.replaceAll(RegExp(r'[^\w\d]+'), '_');
    return '${cleaned}_ep$episode.png';
  }

  /// Downloads image from url, saves to documents directory, returns local file path.
  static Future<String?> downloadAndSaveFile(String url, String fileName) async {
    try {
      final directory = await getTemporaryDirectory();
      final filePath = '${directory.path}/$fileName';

      // Delete previous if exists (to avoid duplicates)
      final file = File(filePath);
      if (await file.exists()) {
        await file.delete();
      }

      final response = await http.get(Uri.parse(url));
      if (response.statusCode == 200) {
        await file.writeAsBytes(response.bodyBytes);
        return filePath;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Schedules a local notification about new episode release with image (if available).
  static Future<void> scheduleEpisodeNotification(
    DateTime airingAt,
    String animeTitle,
    int episodeNumber,
    int mediaId,
    String imageUrl,
  ) async {
    await _ensureTz();
    await _ensurePermissions();
    await _ensureAndroidChannels();
    
    final safeName = safeFileName(animeTitle, episodeNumber);

    // Download image only once (bigPicture and largeIcon use same file)
    final String? imagePath = await downloadAndSaveFile(imageUrl, safeName);

    final tzDateTime = tz.TZDateTime.from(airingAt, tz.local);

    await _plugin.zonedSchedule(
      (animeTitle + episodeNumber.toString()).hashCode,
      animeTitle,
      'Episode $episodeNumber is now available!',
      tzDateTime,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'episode_channel',
          'Episode releases',
          channelDescription: 'Notifications about new episode releases',
          styleInformation: imagePath != null
              ? BigPictureStyleInformation(
                  FilePathAndroidBitmap(imagePath),
                  largeIcon: FilePathAndroidBitmap(imagePath),
                  contentTitle: animeTitle,
                  summaryText: 'Episode $episodeNumber is now available!',
                )
              : null,
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          // subtitle: 'Episode $episodeNumber',
          attachments: imagePath != null
              ? [DarwinNotificationAttachment(imagePath)]
              : null,
        ),
      ),
      payload: Routes.media(mediaId, imageUrl),
      matchDateTimeComponents: DateTimeComponents.dateAndTime,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  /// Cancels scheduled notification for episode (if any).
  static Future<void> cancelEpisodeNotification(String animeTitle, int episodeNumber) async {
    await _plugin.cancel((animeTitle + episodeNumber.toString()).hashCode);
  }

  /// Schedules or cancels a notification for a single anime entry.
  static Future<void> scheduleNotificationForEntry(Entry entry) async {
    try {
      if ((entry.listStatus == ListStatus.current || entry.listStatus == ListStatus.planning) &&
          entry.airingAt != null &&
          entry.nextEpisode != null) {
        await scheduleEpisodeNotification(
          entry.airingAt!,
          entry.titles[0],
          entry.nextEpisode!,
          entry.mediaId,
          entry.imageUrl,
        );
      } else {
        await cancelEpisodeNotification(entry.titles[0], entry.nextEpisode ?? 1);
      }
    } catch (e) {
      debugPrint('Failed to schedule notification for entry: $e');
    }
  }

  /// Batch schedules notifications for all entries (uses per-entry function).
  static Future<void> scheduleNotificationsForAll(List<Entry> entries) async {
    for (final entry in entries) {
      await scheduleNotificationForEntry(entry);
    }
  }

  /// Cancels all scheduled notifications (episodes or others)
  static Future<void> cancelAllScheduledNotifications() async {
    await _plugin.cancelAll();
  }
}
