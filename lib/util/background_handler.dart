import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:animeshin/feature/viewer/persistence_model.dart';
import 'package:animeshin/feature/viewer/persistence_provider.dart';
import 'package:animeshin/feature/viewer/repository_provider.dart';
import 'package:animeshin/util/routes.dart';
import 'package:animeshin/feature/notification/notifications_model.dart';
import 'package:animeshin/util/graphql.dart';
import 'package:workmanager/workmanager.dart';
import 'package:animeshin/platform/platform_flags.dart';

final _notificationPlugin = FlutterLocalNotificationsPlugin();

class BackgroundHandler {
  BackgroundHandler._();

  static Future<void> init(StreamController<String> notificationCtrl) async {
    if (!notificationsSupported) return;
    // Darwin (iOS & macOS) init settings — request alert/badge/sound on first run.
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _notificationPlugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('notification_icon'),
        iOS: darwin,
        macOS: darwin,
        linux: LinuxInitializationSettings(defaultActionName: 'Open'),
        windows: WindowsInitializationSettings(
          appName: 'AnimeShin',
          appUserModelId: 'com.animeshin',
          guid: 'b9726c14-67c1-4b3d-bf27-d28a33ae824e',
          iconPath: 'notification_icon',
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        final payload = response.payload;
        if (payload != null) notificationCtrl.add(payload);
      },
    );

    // Forward payload if app was launched from a notification.
    final launchDetails = await _notificationPlugin.getNotificationAppLaunchDetails();
    final payload = launchDetails?.notificationResponse?.payload;
    if (payload != null) notificationCtrl.add(payload);

    // (Optional) Explicit permission request; safe to call after initialize.
    await requestPermissionForNotifications();

    // Background fetch only on Android/iOS (Workmanager Apple handles iOS, not macOS).
    if (Platform.isAndroid || Platform.isIOS) {
      await Workmanager().initialize(_fetch);
    }
    if (Platform.isAndroid) {
      await Workmanager().registerPeriodicTask(
        '0',
        'notifications',
        constraints: Constraints(networkType: NetworkType.connected),
      );
    }
  }

  /// Requests a notifications permission, if not already granted.
  static Future<void> requestPermissionForNotifications() async {
    if (!notificationsSupported) return;
    if (Platform.isAndroid) {
      final android = _notificationPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return;
      if (await android.areNotificationsEnabled() ?? false) return;
      await android.requestNotificationsPermission();
      return;
    }

    if (Platform.isIOS) {
      final ios = _notificationPlugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      await ios?.requestPermissions(alert: true, badge: true, sound: true);
      return;
    }

    if (Platform.isMacOS) {
      final mac = _notificationPlugin
          .resolvePlatformSpecificImplementation<MacOSFlutterLocalNotificationsPlugin>();
      await mac?.requestPermissions(alert: true, badge: true, sound: true);
      return;
    }
  }

  /// Clears device notifications.
  static void clearNotifications() {
    if (!notificationsSupported) return;
    _notificationPlugin.cancelAll();
  }
}

@pragma('vm:entry-point')
void _fetch() => Workmanager().executeTask((_, __) async {
      final container = ProviderContainer();

      await container.read(persistenceProvider.notifier).init();
      final persistence = container.read(persistenceProvider);

      // No notifications are fetched in guest mode.
      if (persistence.accountGroup.accountIndex == null) return true;

      var appMeta = AppMeta(
        lastBackgroundJob: DateTime.now(),
        lastNotificationId: persistence.appMeta.lastNotificationId,
        lastAppVersion: persistence.appMeta.lastAppVersion,
      );
      container.read(persistenceProvider.notifier).setAppMeta(appMeta);

      final repository = container.read(repositoryProvider);
      Map<String, dynamic> data;
      try {
        data = await repository.request(
          GqlQuery.notifications,
          const {'withCount': true},
        );
      } catch (_) {
        return true;
      }

      int count = data['Viewer']?['unreadNotificationCount'] ?? 0;
      final List<dynamic> notifications =
          data['Page']?['notifications'] ?? const [];

      if (count > notifications.length) count = notifications.length;
      if (count == 0) return true;

      final lastNotificationId = persistence.appMeta.lastNotificationId;

      appMeta = AppMeta(
        lastNotificationId: notifications[0]['id'] ?? -1,
        lastBackgroundJob: persistence.appMeta.lastBackgroundJob,
        lastAppVersion: persistence.appMeta.lastAppVersion,
      );
      container.read(persistenceProvider.notifier).setAppMeta(appMeta);

      for (int i = 0;
          i < count && notifications[i]['id'] != lastNotificationId;
          i++) {
        final notification = SiteNotification.maybe(
          notifications[i],
          persistence.options.imageQuality,
        );

        if (notification == null) continue;

        (switch (notification.type) {
          NotificationType.following => _show(
              notification,
              'New Follow',
              Routes.user((notification as FollowNotification).userId),
            ),
          NotificationType.activityMention => _show(
              notification,
              'New Mention',
              Routes.activity(
                (notification as ActivityNotification).activityId,
              ),
            ),
          NotificationType.activityMessage => _show(
              notification,
              'New Message',
              Routes.activity(
                (notification as ActivityNotification).activityId,
              ),
            ),
          NotificationType.activityReply => _show(
              notification,
              'New Reply',
              Routes.activity(
                (notification as ActivityNotification).activityId,
              ),
            ),
          NotificationType.activityReplySubscribed => _show(
              notification,
              'New Reply To Subscribed Activity',
              Routes.activity(
                (notification as ActivityNotification).activityId,
              ),
            ),
          NotificationType.activityLike => _show(
              notification,
              'New Activity Like',
              Routes.activity(
                (notification as ActivityNotification).activityId,
              ),
            ),
          NotificationType.acrivityReplyLike => _show(
              notification,
              'New Reply Like',
              Routes.activity(
                (notification as ActivityNotification).activityId,
              ),
            ),
          NotificationType.threadLike => _show(
              notification,
              'New Forum Like',
              Routes.thread((notification as ThreadNotification).threadId),
            ),
          NotificationType.threadCommentReply => _show(
              notification,
              'New Forum Reply',
              Routes.comment(
                (notification as ThreadCommentNotification).commentId,
              ),
            ),
          NotificationType.threadCommentMention => _show(
              notification,
              'New Forum Mention',
              Routes.comment(
                (notification as ThreadCommentNotification).commentId,
              ),
            ),
          NotificationType.threadReplySubscribed => _show(
              notification,
              'New Forum Comment',
              Routes.comment(
                (notification as ThreadCommentNotification).commentId,
              ),
            ),
          NotificationType.threadCommentLike => _show(
              notification,
              'New Forum Comment Like',
              Routes.comment(
                (notification as ThreadCommentNotification).commentId,
              ),
            ),
          NotificationType.airing => _show(
              notification,
              'New Episode',
              Routes.media(
                (notification as MediaReleaseNotification).mediaId,
              ),
            ),
          NotificationType.relatedMediaAddition => _show(
              notification,
              'Added Media',
              Routes.media(
                (notification as MediaReleaseNotification).mediaId,
              ),
            ),
          NotificationType.mediaDataChange => _show(
              notification,
              'Modified Media',
              Routes.media(
                (notification as MediaChangeNotification).mediaId,
              ),
            ),
          NotificationType.mediaMerge => _show(
              notification,
              'Merged Media',
              Routes.media(
                (notification as MediaChangeNotification).mediaId,
              ),
            ),
          NotificationType.mediaDeletion => _show(
              notification,
              'Deleted Media',
              Routes.notifications,
            ),
        });
      }

      return true;
    });

() _show(SiteNotification notification, String title, String payload) {
  if (!notificationsSupported) return ();
  _notificationPlugin.show(
    id: notification.id,
    title: title,
    body: notification.texts.join(),
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        notification.type.name,
        notification.type.label,
        channelDescription: notification.type.label,
      ),
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    ),
    payload: payload,
  );
  return ();
}