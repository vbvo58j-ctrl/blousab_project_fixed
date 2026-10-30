import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// يتحكم بخدمة أندرويد التي تعمل في المقدمة وتُبقي الاتصالات حيّة في الخلفية.
class BackgroundService {
  BackgroundService._();
  static final BackgroundService instance = BackgroundService._();

  static const MethodChannel _channel = MethodChannel('com.blousab.messenger/service');
  static const String prefKey = 'blousab_background_service';

  Future<bool> isEnabled() async =>
      (await SharedPreferences.getInstance()).getBool(prefKey) ?? false;

  Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, enabled);
    await apply(enabled);
  }

  /// يشغّل الخدمة أو يوقفها حسب الإعداد المحفوظ (يُستدعى عند فتح التطبيق).
  Future<void> syncWithSettings() async => apply(await isEnabled());

  Future<void> apply(bool enabled) async {
    try {
      await _channel.invokeMethod<bool>(enabled ? 'start' : 'stop');
    } catch (_) {
      // على أندرويد 14 قد تفشل الخدمة دون صلاحية البلوتوث؛ يبقى التطبيق يعمل في المقدمة.
    }
  }
}
