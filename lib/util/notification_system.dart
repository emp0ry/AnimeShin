import 'dart:io';
import 'package:animeshin/feature/collection/collection_models.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:timezone/timezone.dart' as tz;

class NotificationSystem {
  NotificationSystem._();

  static final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();

  /// Generates a safe file name for images.
  static String safeFileName(String base, int episode) {
    final cleaned = base.replaceAll(RegExp(r'[^\w\d]+'), '_');
    return '${cleaned}_ep$episode.png';
  }

  /// Downloads image from url, saves to documents directory, returns local file path.
  static Future<String?> downloadAndSaveFile(String url, String fileName) async {
    try {
      final directory = await getApplicationDocumentsDirectory();
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
    String imageUrl,
  ) async {
    final safeName = safeFileName(animeTitle, episodeNumber);

    // Download image only once (bigPicture and largeIcon use same file)
    final String? imagePath = await downloadAndSaveFile(imageUrl, safeName);

    final tzDateTime = tz.TZDateTime.from(airingAt, tz.local);

    await _plugin.zonedSchedule(
      (animeTitle + episodeNumber.toString()).hashCode,
      'New episode released!',
      '$animeTitle — Episode $episodeNumber aired!',
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
                  contentTitle: 'New episode released!',
                  summaryText: '$animeTitle — Episode $episodeNumber is now available!',
                )
              : null,
          importance: Importance.high,
          priority: Priority.high,
          playSound: true,
        ),
        iOS: DarwinNotificationDetails(
          attachments: imagePath != null
              ? [DarwinNotificationAttachment(imagePath)]
              : null,
        ),
      ),
      payload: '$animeTitle-$episodeNumber',
      matchDateTimeComponents: DateTimeComponents.dateAndTime,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    );
  }

  /// Cancels scheduled notification for episode (if any).
  static Future<void> cancelEpisodeNotification(String animeTitle, int episodeNumber) async {
    await _plugin.cancel((animeTitle + episodeNumber.toString()).hashCode);
  }

  /// Batch schedules notifications for all entries.
  static Future<void> scheduleNotificationsForAll(List<Entry> entries) async {
    for (final entry in entries) {
      try {
        if ((entry.listStatus == ListStatus.current || entry.listStatus == ListStatus.planning) &&
            entry.airingAt != null &&
            entry.nextEpisode != null) {
          await NotificationSystem.scheduleEpisodeNotification(
            entry.airingAt!,
            entry.titles[0],
            entry.nextEpisode!,
            entry.imageUrl,
          );
          print('Scheduled notification for ${entry.titles[0]} episode ${entry.nextEpisode}');
        } else {
          await NotificationSystem.cancelEpisodeNotification(entry.titles[0], entry.nextEpisode ?? 1);
        }
      } catch (e) {
        print('Failed to schedule notification: $e');
      }
    }
  }
}
