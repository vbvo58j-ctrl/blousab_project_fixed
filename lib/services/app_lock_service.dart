import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'storage_ports.dart';

enum LockCheck { ok, wrong, lockedOut }

class LockResult {
  const LockResult(this.check, {this.remaining = Duration.zero});
  final LockCheck check;

  /// المدة المتبقية للقفل المؤقت بعد محاولات فاشلة متكررة.
  final Duration remaining;
}

/// قفل التطبيق برمز PIN.
///
/// * لا يُخزَّن الرمز نفسه، بل PBKDF2-HMAC-SHA256 بملح عشوائي في Android Keystore.
/// * بعد [freeAttempts] محاولات فاشلة يُقفل التطبيق مؤقتًا بمدة تتضاعف حتى ساعة.
/// * هذا قفل داخل التطبيق وليس تشفيرًا لبيانات التطبيق على القرص.
class AppLockService {
  AppLockService({required SecretVault vault, int Function()? clock, int iterations = 60000})
      : _vault = vault,
        _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _iterations = iterations;

  static final AppLockService instance = AppLockService(vault: SecureStorageVault());

  static const int freeAttempts = 5;
  static const String _hashKey = 'blousab_lock_hash_v1';
  static const String _saltKey = 'blousab_lock_salt_v1';
  static const String _failKey = 'blousab_lock_fails_v1';
  static const String _untilKey = 'blousab_lock_until_v1';
  static const String legacyPrefKey = 'blousab_app_lock_pin';

  final SecretVault _vault;
  final int Function() _clock;
  final int _iterations;

  Future<bool> isSet() async => (await _vault.read(_hashKey))?.isNotEmpty ?? false;

  static bool isValidPin(String pin) => RegExp(r'^\d{4,8}$').hasMatch(pin);

  Future<List<int>> _derive(String pin, List<int> salt) async {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: _iterations,
      bits: 256,
    );
    final key = await pbkdf2.deriveKeyFromPassword(password: pin, nonce: salt);
    return key.extractBytes();
  }

  Future<void> setPin(String pin) async {
    if (!isValidPin(pin)) throw ArgumentError('الرمز يجب أن يكون من 4 إلى 8 أرقام.');
    final random = Random.secure();
    final salt = List<int>.generate(16, (_) => random.nextInt(256));
    final hash = await _derive(pin, salt);
    await _vault.write(_saltKey, base64Encode(salt));
    await _vault.write(_hashKey, base64Encode(hash));
    await _vault.write(_failKey, '0');
    await _vault.write(_untilKey, '0');
  }

  Future<void> clear() async {
    await _vault.delete(_hashKey);
    await _vault.delete(_saltKey);
    await _vault.delete(_failKey);
    await _vault.delete(_untilKey);
  }

  Future<LockResult> verify(String pin) async {
    final now = _clock();
    final until = int.tryParse(await _vault.read(_untilKey) ?? '0') ?? 0;
    if (until > now) {
      return LockResult(LockCheck.lockedOut, remaining: Duration(milliseconds: until - now));
    }
    final storedHash = await _vault.read(_hashKey);
    final storedSalt = await _vault.read(_saltKey);
    if (storedHash == null || storedSalt == null) return const LockResult(LockCheck.ok);

    final candidate = await _derive(pin, base64Decode(storedSalt));
    final expected = base64Decode(storedHash);
    var diff = candidate.length ^ expected.length;
    for (var i = 0; i < candidate.length && i < expected.length; i++) {
      diff |= candidate[i] ^ expected[i];
    }
    if (diff == 0) {
      await _vault.write(_failKey, '0');
      await _vault.write(_untilKey, '0');
      return const LockResult(LockCheck.ok);
    }

    final fails = (int.tryParse(await _vault.read(_failKey) ?? '0') ?? 0) + 1;
    await _vault.write(_failKey, '$fails');
    if (fails >= freeAttempts) {
      final steps = fails - freeAttempts; // 0,1,2,...
      final seconds = min(3600, 30 * (1 << min(steps, 7)));
      final lockedUntil = now + seconds * 1000;
      await _vault.write(_untilKey, '$lockedUntil');
      return LockResult(LockCheck.lockedOut, remaining: Duration(seconds: seconds));
    }
    return const LockResult(LockCheck.wrong);
  }

  /// ترحيل الرمز القديم (نص صريح في SharedPreferences) إلى تجزئة مملّحة ثم حذفه.
  Future<void> migrateLegacy(KeyValueStore prefs) async {
    final legacy = await prefs.getString(legacyPrefKey);
    if (legacy == null || legacy.isEmpty) return;
    if (isValidPin(legacy) && !await isSet()) {
      await setPin(legacy);
    }
    await prefs.remove(legacyPrefKey);
  }
}
