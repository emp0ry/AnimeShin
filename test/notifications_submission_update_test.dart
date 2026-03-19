import 'package:animeshin/feature/notification/notifications_model.dart';
import 'package:animeshin/feature/viewer/persistence_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Submission update notifications', () {
    test('parses media submission update notification', () {
      final notification = SiteNotification.maybe(
        {
          'id': 1,
          'type': 'MEDIA_SUBMISSION_UPDATE',
          'createdAt': 1000,
          'status': 'accepted',
          'notes': 'Looks good',
          'submittedTitle': 'Submitted title',
          'media': {
            'id': 42,
            'title': {'userPreferred': 'Media title'},
            'coverImage': {
              'extraLarge': 'cover-xl',
              'large': 'cover-lg',
              'medium': 'cover-md',
            },
          },
        },
        ImageQuality.veryHigh,
      );

      expect(notification, isA<MediaSubmissionUpdateNotification>());
      final item = notification as MediaSubmissionUpdateNotification;
      expect(item.itemId, 42);
      expect(item.imageUrl, 'cover-xl');
      expect(item.notes, 'Looks good');
      expect(item.texts.join(), contains('Submitted title'));
      expect(item.texts.join(), contains('accepted'));
    });

    test('uses person image fallback for character/staff updates', () {
      final character = SiteNotification.maybe(
        {
          'id': 2,
          'type': 'CHARACTER_SUBMISSION_UPDATE',
          'createdAt': 1001,
          'status': 'pending',
          'notes': 'Character note',
          'character': {
            'id': 99,
            'name': {'userPreferred': 'Character name'},
            'image': {
              'large': 'char-lg',
              'medium': 'char-md',
            },
          },
        },
        ImageQuality.veryHigh,
      );

      expect(character, isA<CharacterSubmissionUpdateNotification>());
      final characterItem = character as CharacterSubmissionUpdateNotification;
      expect(characterItem.itemId, 99);
      expect(characterItem.imageUrl, 'char-lg');

      final staff = SiteNotification.maybe(
        {
          'id': 3,
          'type': 'STAFF_SUBMISSION_UPDATE',
          'createdAt': 1002,
          'status': 'rejected',
          'notes': 'Staff note',
          'staff': {
            'id': 77,
            'name': {'userPreferred': 'Staff name'},
            'image': {
              'large': 'staff-lg',
              'medium': 'staff-md',
            },
          },
        },
        ImageQuality.veryHigh,
      );

      expect(staff, isA<StaffSubmissionUpdateNotification>());
      final staffItem = staff as StaffSubmissionUpdateNotification;
      expect(staffItem.itemId, 77);
      expect(staffItem.imageUrl, 'staff-lg');
    });
  });
}
