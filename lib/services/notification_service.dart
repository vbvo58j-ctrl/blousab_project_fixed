import 'dart:collection';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// Local notifications for social activity and incoming messages.
/// Social alerts are separate from chat alerts and use their own Android channels.
class NotificationService with WidgetsBindingObserver {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  static String? activeConversationId;
  static bool appInForeground = true;

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  final Set<String> _shownIds = <String>{};
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    const android = AndroidInitializationSettings('@android:drawable/sym_def_app_icon');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(settings);
    WidgetsBinding.instance.addObserver(this);
    _initialized = true;
  }

  Future<void> requestPermission() async {
    if (!_initialized) await initialize();
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    appInForeground = state == AppLifecycleState.resumed;
  }

  Future<void> handleIncomingPayload(String raw, {required String currentUserId}) async {
    try {
      final dynamic value = jsonDecode(raw);
      if (value is! Map) return;
      final type = value['type']?.toString() ?? '';
      if (type == 'profile_card' || type == 'profile_update' || type == 'hello' || type == 'hello_ack') return;
      if (type == 'friend_request') {
        final recipientId = value['recipientId']?.toString() ?? '';
        final senderId = value['senderId']?.toString() ?? '';
        if (recipientId != currentUserId || senderId.isEmpty || senderId == currentUserId) return;
        final requestId = value['requestId']?.toString() ?? '${senderId}_${value['createdAt']}';
        final id = 'friend_request_$requestId';
        if (!_shownIds.add(id)) return;
        final senderName = value['senderName']?.toString().trim();
        await _plugin.show(
          id.hashCode & 0x7fffffff,
          'طلب صداقة جديد',
          '${senderName?.isNotEmpty == true ? senderName : 'أحد المستخدمين'} أرسل إليك طلب صداقة',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'blousab_social',
              'النشاط الاجتماعي',
              channelDescription: 'طلبات الصداقة والتفاعلات على المنشورات والحالات، دون رسائل المحادثات',
              importance: Importance.high,
              priority: Priority.high,
              icon: '@android:drawable/sym_def_app_icon',
            ),
          ),
          payload: 'friend_requests',
        );
        return;
      }
      if (type == 'post_like' || type == 'post_comment') {
        final ownerId = value['postOwnerId']?.toString() ?? value['ownerId']?.toString() ?? '';
        final senderId = value['senderId']?.toString() ?? '';
        if (ownerId != currentUserId || senderId.isEmpty || senderId == currentUserId) return;
        final contentId = value['postId']?.toString() ?? value['id']?.toString() ?? '';
        final id = '${type}_${contentId}_$senderId';
        if (!_shownIds.add(id)) return;
        final senderName = value['senderName']?.toString().trim();
        final isLike = type == 'post_like';
        await _plugin.show(
          id.hashCode & 0x7fffffff,
          isLike ? 'إعجاب جديد بمنشورك' : 'تعليق جديد على منشورك',
          '${senderName?.isNotEmpty == true ? senderName : 'أحد المستخدمين'} ${isLike ? 'أعجب بمنشورك' : 'علّق على منشورك'}',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'blousab_social',
              'النشاط الاجتماعي',
              channelDescription: 'طلبات الصداقة والتفاعلات على المنشورات والحالات، دون رسائل المحادثات',
              importance: Importance.high,
              priority: Priority.high,
              icon: '@android:drawable/sym_def_app_icon',
            ),
          ),
          payload: contentId,
        );
        return;
      }
      if (type == 'story_like') {
        final ownerId = value['storyOwnerId']?.toString() ?? '';
        if (ownerId != currentUserId) return;
        final senderId = value['senderId']?.toString() ?? '';
        if (senderId.isEmpty || senderId == currentUserId) return;
        final storyId = value['storyId']?.toString() ?? '';
        final id = 'story_like_${storyId}_$senderId';
        if (!_shownIds.add(id)) return;
        final senderName = value['senderName']?.toString().trim();
        await _plugin.show(
          id.hashCode & 0x7fffffff,
          'إعجاب جديد بقصتك ❤️',
          '${senderName?.isNotEmpty == true ? senderName : 'أحد المستخدمين'} أعجب بقصتك',
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'blousab_social',
              'النشاط الاجتماعي',
              channelDescription: 'طلبات الصداقة والتفاعلات على المنشورات والحالات، دون رسائل المحادثات',
              importance: Importance.high,
              priority: Priority.high,
              icon: '@android:drawable/sym_def_app_icon',
            ),
          ),
          payload: storyId,
        );
        return;
      }
      if (type != 'chat' && type != 'file' && type != 'text') return;
      final senderId = value['senderId']?.toString() ?? '';
      if (senderId.isEmpty || senderId == currentUserId) return;
      final conversationId = value['conversationId']?.toString() ?? '';
      if (appInForeground && activeConversationId != null && activeConversationId == conversationId) return;
      final id = value['id']?.toString() ?? '${senderId}_${value['sentAt']}_${value['text']}';
      if (!_shownIds.add(id)) return;
      if (_shownIds.length > 500) _shownIds.remove(_shownIds.first);
      final senderName = value['senderName']?.toString().trim();
      final title = (senderName == null || senderName.isEmpty) ? 'رسالة جديدة' : senderName;
      final body = type == 'file' ? '📎 أرسل ملفًا' : (value['text']?.toString() ?? 'رسالة جديدة');
      final notificationId = id.hashCode & 0x7fffffff;
      await _plugin.show(
        notificationId,
        title,
        body.isEmpty ? 'رسالة جديدة' : body,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            'blousab_messages',
            'رسائل بلوساب',
            channelDescription: 'إشعارات الرسائل الجديدة في بلوساب',
            importance: Importance.max,
            priority: Priority.high,
            category: AndroidNotificationCategory.message,
            icon: '@android:drawable/sym_def_app_icon',
          ),
        ),
        payload: conversationId,
      );
    } catch (_) {
      // A malformed packet should never interrupt message reception.
    }
  }
}
