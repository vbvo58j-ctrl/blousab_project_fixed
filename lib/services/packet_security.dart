import 'dart:collection';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import 'community_store.dart';
import 'identity_service.dart';
import 'storage_ports.dart';

/// مفاتيح طرف آخر كما رأيناها في حزمة موقّعة صحيحة.
class PeerKeys {
  const PeerKeys({required this.edPublic, required this.xPublic});
  final List<int> edPublic;
  final List<int> xPublic;
}

abstract class PeerKeyStore {
  Future<PeerKeys?> get(String peerId);
  Future<void> put(String peerId, PeerKeys keys);
}

class KeyValuePeerKeyStore implements PeerKeyStore {
  KeyValuePeerKeyStore(this._store);
  final KeyValueStore _store;
  final Map<String, PeerKeys> _cache = <String, PeerKeys>{};

  String _key(String id) => 'blousab_peerkeys_v1_$id';

  @override
  Future<PeerKeys?> get(String peerId) async {
    final cached = _cache[peerId];
    if (cached != null) return cached;
    final raw = await _store.getString(_key(peerId));
    if (raw == null) return null;
    final parts = raw.split('|');
    if (parts.length != 2) return null;
    try {
      final keys = PeerKeys(
        edPublic: base64Decode(parts[0]),
        xPublic: base64Decode(parts[1]),
      );
      _cache[peerId] = keys;
      return keys;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> put(String peerId, PeerKeys keys) async {
    _cache[peerId] = keys;
    await _store.setString(
      _key(peerId),
      '${base64Encode(keys.edPublic)}|${base64Encode(keys.xPublic)}',
    );
  }
}

class _CachedKey {
  _CachedKey(this.key, this.at);
  final List<int>? key;
  final int at;
}

typedef GroupKeyLookup = Future<List<int>?> Function(String conversationId);

/// نتيجة فحص حزمة واردة.
class OpenedPacket {
  const OpenedPacket({
    required this.plain,
    required this.raw,
    required this.signerId,
    required this.readable,
    required this.timestampMs,
  });

  /// JSON بعد فك التشفير (أو الحزمة الأصلية إذا لم نملك المفتاح).
  final String plain;

  /// الحزمة الموقّعة كما وصلت — هذه هي التي تُمرَّر عبر الوسيط.
  final String raw;
  final String signerId;

  /// false = حزمة سليمة التوقيع لكننا لا نملك مفتاح فك تشفيرها (وسيط فقط).
  final bool readable;
  final int timestampMs;
}

/// توقيع وتشفير الحزم عند حدود النقل.
///
/// الحزمة المرسلة:  { ...الحقول الأصلية, _v, _pk, _xpk, _ts, _sig [, _enc, _ek] }
/// * التوقيع يغطي كل الحقول عدا الحقول المتغيرة عند الترحيل ([mutableKeys]).
/// * لا توقّع الوسطاء الحزم المُمرَّرة؛ توقيع المؤلف الأصلي يبقى كما هو.
/// * حقول المحتوى [encryptedFields] تُشفَّر بـ AES-256-GCM عندما يتوفر مفتاح
///   (مفتاح المجتمع، أو مفتاح X25519 المشترك للمحادثات الخاصة).
class PacketSecurity {
  PacketSecurity({
    required this.identity,
    required this.peerKeys,
    required this.groupKeys,
    int Function()? clock,
  }) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  static final PacketSecurity instance = PacketSecurity(
    identity: IdentityService.instance,
    peerKeys: KeyValuePeerKeyStore(const PrefsKeyValueStore()),
    groupKeys: _communityGroupKey,
  );

  static final Map<String, _CachedKey> _groupKeyCache = <String, _CachedKey>{};

  /// مفتاح المجتمع من التخزين المحلي، مع ذاكرة مؤقتة قصيرة لأن كل حزمة تسأل عنه.
  static Future<List<int>?> _communityGroupKey(String conversationId) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final cached = _groupKeyCache[conversationId];
    if (cached != null && now - cached.at < 10000) return cached.key;
    List<int>? result;
    try {
      final community = await CommunityStore().findById(conversationId);
      final key = community?.groupKey;
      if (key != null && key.isNotEmpty) {
        final bytes = base64Decode(key);
        if (bytes.length == 32) result = bytes;
      }
    } catch (_) {}
    // لا نخزّن الغياب مؤقتًا: العضو الجديد يجب أن يرى مفتاحه فور حفظه.
    if (result != null) _groupKeyCache[conversationId] = _CachedKey(result, now);
    return result;
  }

  /// يُستدعى بعد إنشاء مجتمع أو الانضمام إليه ليظهر المفتاح فورًا.
  static void invalidateGroupKeyCache() => _groupKeyCache.clear();

  static const int version = 1;
  static const int maxPacketChars = 8 * 1024 * 1024;
  static const int maxFutureSkewMs = 60 * 60 * 1000; // ساعة
  static const int maxAgeMs = 3 * 24 * 60 * 60 * 1000; // 3 أيام
  static const int _seenCapacity = 5000;

  /// حقول تتغير أثناء الترحيل ولا يغطيها التوقيع.
  static const Set<String> mutableKeys = <String>{'hops', 'relayPath', '_sig'};

  /// حقول المحتوى التي تُشفَّر.
  static const List<String> encryptedFields = <String>[
    'text',
    'data',
    'fileName',
    'senderPhoto',
    'comment',
  ];

  final IdentityService identity;
  final PeerKeyStore peerKeys;
  final GroupKeyLookup groupKeys;
  final int Function() _clock;
  final AesGcm _aes = AesGcm.with256bits();
  final LinkedHashSet<String> _seenSignatures = LinkedHashSet<String>();

  // ---------------------------------------------------------------- عام

  /// ترتيب مفاتيح ثابت بين الأجهزة، لتوقيع وتحقق متطابقين.
  static String canonicalJson(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k.toString()).toList()..sort();
      final parts = keys.map((k) => '${jsonEncode(k)}:${canonicalJson(value[k])}');
      return '{${parts.join(',')}}';
    }
    if (value is List) {
      return '[${value.map(canonicalJson).join(',')}]';
    }
    return jsonEncode(value);
  }

  /// المعرّفات التي تدّعيها الحزمة لنفسها. يجب أن تساوي كلها معرّف الموقّع.
  static Set<String> claimedIds(Map<dynamic, dynamic> map) {
    final out = <String>{};
    void add(Object? value) {
      final s = value?.toString().trim() ?? '';
      if (s.isNotEmpty) out.add(s);
    }

    add(map['senderId']);
    add(map['ownerId']);
    add(map['requesterId']);
    final post = map['post'];
    if (post is Map) add(post['authorId']);
    final community = map['community'];
    if (community is Map) add(community['ownerId']);
    return out;
  }

  static Map<String, dynamic> _signable(Map<String, dynamic> map) {
    final copy = Map<String, dynamic>.from(map);
    for (final key in mutableKeys) {
      copy.remove(key);
    }
    return copy;
  }

  /// معرّف الطرف الآخر في محادثة خاصة dm_<a>_<b>.
  static String? peerOfDirect(String conversationId, String selfId) {
    if (!conversationId.startsWith('dm_')) return null;
    final ids = conversationId.substring(3).split('_').where((s) => s.isNotEmpty).toList();
    if (!ids.contains(selfId)) return null;
    final others = ids.where((id) => id != selfId).toList();
    return others.isEmpty ? null : others.first;
  }

  static bool _sameBytes(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  // -------------------------------------------------------------- الإرسال

  /// يوقّع (ويشفّر عند الإمكان) حزمة صادرة. الحزمة المُمرَّرة (فيها _sig) تُترك كما هي.
  Future<String> seal(String raw) async {
    await identity.ensureInitialized();
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('الحزمة يجب أن تكون كائن JSON.');
    }
    final map = Map<String, dynamic>.from(decoded);
    if (map.containsKey('_sig')) return raw;

    final self = identity.userId;
    final claimed = claimedIds(map);
    if (claimed.isEmpty) {
      map['senderId'] = self;
    } else if (claimed.any((id) => id != self)) {
      throw StateError('لا يمكن توقيع حزمة باسم مستخدم آخر.');
    }

    map['_v'] = version;
    map['_pk'] = base64Encode(identity.edPublicKey);
    map['_xpk'] = base64Encode(identity.xPublicKey);
    map['_ts'] = _clock();
    await _encrypt(map, self);

    final signature = await identity.sign(utf8.encode(canonicalJson(_signable(map))));
    map['_sig'] = base64Encode(signature);

    final out = jsonEncode(map);
    if (out.length > maxPacketChars) {
      throw StateError('حجم الرسالة أكبر من الحد المسموح.');
    }
    return out;
  }

  List<int> _aad(String conversationId, Object? messageId, String signerId) =>
      utf8.encode('$conversationId|${messageId ?? ''}|$signerId');

  Future<void> _encrypt(Map<String, dynamic> map, String self) async {
    final conversationId = map['conversationId']?.toString() ?? '';
    if (conversationId.isEmpty) return;
    final fields = <String, dynamic>{
      for (final name in encryptedFields)
        if (map.containsKey(name)) name: map[name],
    };
    if (fields.isEmpty) return;

    SecretKey? key;
    String kind;
    if (conversationId.startsWith('dm_')) {
      final peer = peerOfDirect(conversationId, self);
      if (peer == null) return;
      final keys = await peerKeys.get(peer);
      if (keys == null) return; // لم نتلقَّ مفتاح الطرف الآخر بعد.
      key = await identity.deriveDirectKey(keys.xPublic, peer);
      kind = 'd';
    } else {
      final groupKey = await groupKeys(conversationId);
      if (groupKey == null) return; // مجتمع قديم دون مفتاح.
      key = SecretKey(groupKey);
      kind = 'g';
    }

    final box = await _aes.encrypt(
      utf8.encode(jsonEncode(fields)),
      secretKey: key,
      aad: _aad(conversationId, map['id'], self),
    );
    for (final name in fields.keys) {
      map.remove(name);
    }
    map['_enc'] = base64Encode(box.concatenation());
    map['_ek'] = kind;
  }

  // ---------------------------------------------------------------- الاستقبال

  /// يتحقق من حزمة واردة. يعيد null إذا كانت غير صالحة أو مكررة أو منتحِلة.
  Future<OpenedPacket?> open(String raw) async {
    if (raw.isEmpty || raw.length > maxPacketChars) return null;
    Map<String, dynamic> map;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      map = Map<String, dynamic>.from(decoded);
    } catch (_) {
      return null;
    }

    if (map['_v'] != version) return null;
    final timestamp = map['_ts'];
    final sigText = map['_sig'];
    final pkText = map['_pk'];
    if (timestamp is! int || sigText is! String || pkText is! String) return null;

    final now = _clock();
    if (timestamp > now + maxFutureSkewMs || timestamp < now - maxAgeMs) return null;

    List<int> signature;
    List<int> publicKey;
    try {
      signature = base64Decode(sigText);
      publicKey = base64Decode(pkText);
    } catch (_) {
      return null;
    }

    final valid = await IdentityService.verify(
      utf8.encode(canonicalJson(_signable(map))),
      signature,
      publicKey,
    );
    if (!valid) return null;

    final claimed = claimedIds(map);
    if (claimed.length != 1) return null;
    final claimedId = claimed.first;

    if (claimedId.startsWith('bx')) {
      // معرّف مشتق من المفتاح: يجب أن يطابق الموقّع تمامًا.
      if (claimedId != await IdentityService.idForPublicKey(publicKey)) return null;
    } else {
      // معرّف قديم: ثبّت أول مفتاح رأيناه (TOFU) وارفض أي مفتاح مختلف بعدها.
      final known = await peerKeys.get(claimedId);
      if (known != null && !_sameBytes(known.edPublic, publicKey)) return null;
    }

    List<int>? peerX;
    final xText = map['_xpk'];
    if (xText is String) {
      try {
        final bytes = base64Decode(xText);
        if (bytes.length == 32) peerX = bytes;
      } catch (_) {}
    }
    if (peerX != null) {
      final known = await peerKeys.get(claimedId);
      if (known == null ||
          !_sameBytes(known.edPublic, publicKey) ||
          !_sameBytes(known.xPublic, peerX)) {
        await peerKeys.put(claimedId, PeerKeys(edPublic: publicKey, xPublic: peerX));
      }
    }

    // منع إعادة التشغيل القريبة: نفس التوقيع لا يُقبل مرتين.
    if (!_seenSignatures.add(sigText)) return null;
    if (_seenSignatures.length > _seenCapacity) {
      _seenSignatures.remove(_seenSignatures.first);
    }

    if (!map.containsKey('_enc')) {
      return OpenedPacket(
        plain: jsonEncode(_publicView(map, claimedId)),
        raw: raw,
        signerId: claimedId,
        readable: true,
        timestampMs: timestamp,
      );
    }

    final conversationId = map['conversationId']?.toString() ?? '';
    SecretKey? key;
    final kind = map['_ek'];
    if (kind == 'g') {
      final groupKey = await groupKeys(conversationId);
      if (groupKey != null) key = SecretKey(groupKey);
    } else if (kind == 'd' && peerX != null) {
      await identity.ensureInitialized();
      if (peerOfDirect(conversationId, identity.userId) == claimedId) {
        key = await identity.deriveDirectKey(peerX, claimedId);
      }
    }

    if (key != null) {
      try {
        final box = SecretBox.fromConcatenation(
          base64Decode(map['_enc'] as String),
          nonceLength: 12,
          macLength: 16,
        );
        final clear = await _aes.decrypt(
          box,
          secretKey: key,
          aad: _aad(conversationId, map['id'], claimedId),
        );
        final fields = jsonDecode(utf8.decode(clear));
        if (fields is Map) {
          for (final name in encryptedFields) {
            if (fields.containsKey(name)) map[name] = fields[name];
          }
          return OpenedPacket(
            plain: jsonEncode(_publicView(map, claimedId)),
            raw: raw,
            signerId: claimedId,
            readable: true,
            timestampMs: timestamp,
          );
        }
      } catch (_) {
        // مفتاح خاطئ أو حزمة معبوث بها: تُعامل كغير مقروءة.
      }
    }

    return OpenedPacket(
      plain: raw,
      raw: raw,
      signerId: claimedId,
      readable: false,
      timestampMs: timestamp,
    );
  }

  /// نسخة للتطبيق: بلا حقول التشفير والتوقيع، مع إبقاء الطابع الزمني.
  Map<String, dynamic> _publicView(Map<String, dynamic> map, String signerId) {
    final view = Map<String, dynamic>.from(map);
    for (final key in const ['_v', '_pk', '_xpk', '_sig', '_enc', '_ek']) {
      view.remove(key);
    }
    view['_signer'] = signerId;
    return view;
  }
}
