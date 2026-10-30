import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// واجهات تخزين صغيرة تفصل منطق الأمان عن الإضافات (plugins)،
/// فيمكن اختبار المنطق بذاكرة داخلية بدل التخزين الحقيقي.
abstract class KeyValueStore {
  Future<String?> getString(String key);
  Future<void> setString(String key, String value);
  Future<void> remove(String key);
}

/// تخزين للأسرار (مفاتيح خاصة، تجزئة PIN).
abstract class SecretVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class PrefsKeyValueStore implements KeyValueStore {
  const PrefsKeyValueStore();

  @override
  Future<String?> getString(String key) async =>
      (await SharedPreferences.getInstance()).getString(key);

  @override
  Future<void> setString(String key, String value) async {
    await (await SharedPreferences.getInstance()).setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await (await SharedPreferences.getInstance()).remove(key);
  }
}

/// Android Keystore عبر flutter_secure_storage. إذا فشل Keystore على جهاز معيّن
/// (يحدث على بعض الأجهزة بعد استعادة نسخة احتياطية) نرجع إلى SharedPreferences
/// حتى لا يتعطل التطبيق، مع بقاء الأسرار مفصولة بمفتاح مميز.
class SecureStorageVault implements SecretVault {
  SecureStorageVault();

  static const String _fallbackPrefix = 'vault_fallback_';
  final FlutterSecureStorage _secure = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  @override
  Future<String?> read(String key) async {
    try {
      final value = await _secure.read(key: key);
      if (value != null) return value;
    } catch (_) {}
    return (await SharedPreferences.getInstance()).getString('$_fallbackPrefix$key');
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      await _secure.write(key: key, value: value);
      return;
    } catch (_) {}
    await (await SharedPreferences.getInstance()).setString('$_fallbackPrefix$key', value);
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _secure.delete(key: key);
    } catch (_) {}
    await (await SharedPreferences.getInstance()).remove('$_fallbackPrefix$key');
  }
}

/// تنفيذ بالذاكرة للاختبارات.
class MemoryStore implements KeyValueStore, SecretVault {
  final Map<String, String> data = <String, String>{};

  @override
  Future<String?> getString(String key) async => data[key];

  @override
  Future<void> setString(String key, String value) async => data[key] = value;

  @override
  Future<void> remove(String key) async => data.remove(key);

  @override
  Future<String?> read(String key) async => data[key];

  @override
  Future<void> write(String key, String value) async => data[key] = value;

  @override
  Future<void> delete(String key) async => data.remove(key);
}
