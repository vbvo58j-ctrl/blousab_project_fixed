import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

import 'storage_ports.dart';

/// هوية الجهاز التشفيرية.
///
/// * مفتاح Ed25519 للتوقيع (إثبات أن الرسالة من صاحب المعرّف).
/// * مفتاح X25519 لاتفاق المفاتيح (تشفير المحادثات الخاصة).
/// * المفاتيح الخاصة تُحفظ في [SecretVault] (Android Keystore) ولا تغادر الجهاز.
///
/// المعرّف الجديد = "bx" + أول 20 حرفًا من Base32(SHA-256(المفتاح العام)).
/// فلا يمكن لأحد ادعاء معرّف من هذا النوع دون امتلاك المفتاح الخاص.
/// أما المعرّفات القديمة (أرقام زمنية) فتُثبَّت مفاتيحها عند أول اتصال (TOFU).
class IdentityService {
  IdentityService({required SecretVault vault, required KeyValueStore store})
      : _vault = vault,
        _store = store;

  static final IdentityService instance = IdentityService(
    vault: SecureStorageVault(),
    store: const PrefsKeyValueStore(),
  );

  static const String userIdKey = 'wasl_user_id';
  static const String legacyDefaultId = 'blousab-user';

  final SecretVault _vault;
  final KeyValueStore _store;
  final Ed25519 _ed = Ed25519();
  final X25519 _x = X25519();

  SimpleKeyPair? _edPair;
  SimpleKeyPair? _xPair;
  Future<void>? _init;

  List<int> edPublicKey = const <int>[];
  List<int> xPublicKey = const <int>[];
  String userId = '';

  bool get isReady => _edPair != null && userId.isNotEmpty;

  Future<void> ensureInitialized() {
    return _init ??= _load().catchError((Object e) {
      _init = null; // اسمح بمحاولة جديدة بدل تخزين الفشل.
      throw e;
    });
  }

  Future<void> _load() async {
    final edSeed = await _seed('blousab_ed_seed_v1');
    final xSeed = await _seed('blousab_x_seed_v1');
    final edPair = await _ed.newKeyPairFromSeed(edSeed);
    final xPair = await _x.newKeyPairFromSeed(xSeed);
    edPublicKey = (await edPair.extractPublicKey()).bytes;
    xPublicKey = (await xPair.extractPublicKey()).bytes;
    _edPair = edPair;
    _xPair = xPair;

    var id = (await _store.getString(userIdKey))?.trim() ?? '';
    if (id.isEmpty || id == legacyDefaultId) {
      id = await idForPublicKey(edPublicKey);
      await _store.setString(userIdKey, id);
    }
    userId = id;
  }

  Future<List<int>> _seed(String name) async {
    final existing = await _vault.read(name);
    if (existing != null && existing.isNotEmpty) {
      try {
        final bytes = base64Decode(existing);
        if (bytes.length == 32) return bytes;
      } catch (_) {}
    }
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    await _vault.write(name, base64Encode(bytes));
    return bytes;
  }

  Future<List<int>> sign(List<int> data) async {
    await ensureInitialized();
    final signature = await _ed.sign(data, keyPair: _edPair!);
    return signature.bytes;
  }

  static Future<bool> verify(
    List<int> data,
    List<int> signature,
    List<int> publicKey,
  ) async {
    if (signature.length != 64 || publicKey.length != 32) return false;
    try {
      return await Ed25519().verify(
        data,
        signature: Signature(
          signature,
          publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
        ),
      );
    } catch (_) {
      return false;
    }
  }

  /// مفتاح AES-256 مشترك بين هذا الجهاز وجهاز الطرف الآخر للمحادثات الخاصة.
  Future<SecretKey> deriveDirectKey(List<int> peerXPublicKey, String peerId) async {
    await ensureInitialized();
    final shared = await _x.sharedSecretKey(
      keyPair: _xPair!,
      remotePublicKey: SimplePublicKey(peerXPublicKey, type: KeyPairType.x25519),
    );
    final ids = <String>[userId, peerId]..sort();
    return Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(
      secretKey: shared,
      nonce: utf8.encode('blousab-dm-v1'),
      info: utf8.encode(ids.join('|')),
    );
  }

  static const String _b32 = 'abcdefghijklmnopqrstuvwxyz234567';

  static Future<String> idForPublicKey(List<int> publicKey) async {
    final digest = (await Sha256().hash(publicKey)).bytes;
    return 'bx${base32(digest).substring(0, 20)}';
  }

  static String base32(List<int> bytes) {
    final out = StringBuffer();
    var buffer = 0;
    var bits = 0;
    for (final byte in bytes) {
      buffer = (buffer << 8) | (byte & 0xff);
      bits += 8;
      while (bits >= 5) {
        out.write(_b32[(buffer >> (bits - 5)) & 31]);
        bits -= 5;
      }
      buffer &= (1 << bits) - 1;
    }
    if (bits > 0) out.write(_b32[(buffer << (5 - bits)) & 31]);
    return out.toString();
  }
}
