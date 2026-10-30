import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/blousab_community.dart';
import 'bluetooth_classic_service.dart';
import 'community_store.dart';
import 'local_network_service.dart';

/// قرارات الترحيل (دوال نقية قابلة للاختبار دون أي إضافات).
class MeshRelayPolicy {
  static const int maxHops = 8;
  static const int maxPathLength = 16;
  static const Duration ttl = Duration(hours: 6);

  /// يعيد نسخة الحزمة الجاهزة للتمرير (hops+1 ومسار فيه هذا الجهاز)،
  /// أو null إذا لا يجوز ترحيلها.
  ///
  /// الصلاحية تُحسب من الطابع الزمني الموقَّع `_ts` وليس من حقل يتحكم به المرسل.
  static Map<String, dynamic>? prepareForward({
    required Map<String, dynamic> packet,
    required String selfId,
    required int nowMs,
  }) {
    if (packet['relay'] != true) return null;
    final type = packet['type']?.toString();
    if (type != 'chat' && type != 'file') return null;
    final id = packet['id']?.toString() ?? '';
    if (id.isEmpty || id.length > 128) return null;

    final timestamp = packet['_ts'];
    if (timestamp is! int) return null;
    if (nowMs > timestamp + ttl.inMilliseconds) return null;

    final hops = int.tryParse(packet['hops']?.toString() ?? '0') ?? 0;
    if (hops < 0 || hops >= maxHops) return null;

    final rawPath = packet['relayPath'];
    final path = rawPath is List ? rawPath.map((e) => e.toString()).toList() : <String>[];
    if (path.length >= maxPathLength) return null;
    if (path.contains(selfId)) return null;
    path.add(selfId);

    return Map<String, dynamic>.from(packet)
      ..['hops'] = hops + 1
      ..['relayPath'] = path;
  }

  /// هل انتهت صلاحية حزمة محفوظة في الطابور؟
  static bool isExpired(Map<String, dynamic> packet, int nowMs) {
    final timestamp = packet['_ts'];
    if (timestamp is! int) return true;
    return nowMs > timestamp + ttl.inMilliseconds;
  }
}

/// ترحيل متعدد القفزات (تخزين وحمل وإعادة) مستقل عن أي واجهة.
///
/// * يمرّر حزم المجتمعات التي تحمل `relay:true` إلى الأجهزة المتصلة عدا مصدرها.
/// * يمرّر دائمًا إن كان هذا الجهاز عضوًا معتمدًا في المجتمع، وللغرباء فقط عند تفعيل
///   خيار «استخدام وسيط». الحزم المشفرة بمفتاح المجتمع تُمرَّر دون أن يقرأها الوسيط.
/// * بدل إعادة بث الطابور كله كل 15 ثانية: عند ظهور جهاز جديد يُرسَل له قائمة
///   `mesh_have` (معرّفات فقط)، فيطلب ما ينقصه بـ `mesh_want`، فنرسل له تلك الحزم فقط.
/// * لا يوفّر إقرار تسليم طرفيًا للمجتمعات (قد يصل لعدد غير معلوم من الأعضاء).
class MeshRelayService {
  MeshRelayService._();
  static final MeshRelayService instance = MeshRelayService._();

  static const String _pendingKey = 'blousab_mesh_pending_v2';
  static const String _seenKey = 'blousab_mesh_seen_v2';
  static const int _seenCapacity = 2000;
  static const int _maxPending = 300;
  static const int _maxHaveItems = 100;
  static const int _maxWantItems = 50;

  final CommunityStore _communities = CommunityStore();
  final LinkedHashSet<String> _seen = LinkedHashSet<String>();
  final Map<String, Map<String, dynamic>> _pending = <String, Map<String, dynamic>>{};
  final Set<String> _btPeers = <String>{};
  StreamSubscription<BlousabEvent>? _btSub;
  StreamSubscription<BlousabEvent>? _lanSub;
  Timer? _maintenanceTimer;
  String _selfId = '';
  bool _started = false;

  /// خيار «استخدام وسيط» للغرباء عن المجتمع.
  bool strangersEnabled = false;

  Future<void> start({required String selfId, required bool strangersEnabled}) async {
    _selfId = selfId;
    this.strangersEnabled = strangersEnabled;
    if (_started) return;
    _started = true;
    await _restore();
    _btSub = BluetoothClassicService.instance.events.listen(_onEvent);
    _lanSub = LocalNetworkService.instance.events.listen(_onEvent);
    _maintenanceTimer = Timer.periodic(const Duration(seconds: 60), (_) => _maintain());
  }

  Future<void> stop() async {
    _started = false;
    await _btSub?.cancel();
    await _lanSub?.cancel();
    _maintenanceTimer?.cancel();
    _btSub = null;
    _lanSub = null;
    _maintenanceTimer = null;
  }

  // ---------------------------------------------------------------- الأحداث

  Future<void> _onEvent(BlousabEvent event) async {
    try {
      if (event.type == 'connected' && event.address != null) {
        _btPeers.add(event.address!);
        await _offerInventory(event.address!);
        return;
      }
      if ((event.type == 'disconnected' || event.type == 'connectionError') &&
          event.address != null) {
        _btPeers.remove(event.address);
        return;
      }
      if (event.type == 'lanPeer' && event.address != null) {
        await _offerInventory(event.address!);
        return;
      }
      if (event.type != 'message' && event.type != 'relay_only') return;

      final text = event.type == 'message' ? event.message : event.rawMessage;
      if (text == null) return;
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      final packet = Map<String, dynamic>.from(decoded);
      final type = packet['type']?.toString();

      if (type == 'mesh_have') {
        await _onHave(packet, event.address);
      } else if (type == 'mesh_want') {
        await _onWant(packet, event.address);
      } else if (packet['relay'] == true) {
        // للتمرير نحتاج الحزمة الموقّعة الأصلية (قد تكون مشفّرة)، لا النسخة المفكوكة.
        final rawText = event.rawMessage ?? text;
        final raw = jsonDecode(rawText);
        if (raw is Map) {
          await _considerRelay(Map<String, dynamic>.from(raw), event.address);
        }
      }
    } catch (_) {
      // حزمة غير مفهومة: لا تعطّل بقية التطبيق.
    }
  }

  Future<bool> _isApprovedMember(String conversationId) async {
    if (conversationId.isEmpty) return false;
    final community = await _communities.findById(conversationId);
    if (community == null) return false;
    return community.members.any(
      (m) => m.id == _selfId && m.status == MemberStatus.approved,
    );
  }

  Future<void> _considerRelay(Map<String, dynamic> raw, String? source) async {
    final id = raw['id']?.toString() ?? '';
    if (id.isEmpty || _seen.contains(id)) return;
    // حزمتي التي عادت إليّ عبر الشبكة: لا أعيد ترحيلها.
    if (raw['senderId']?.toString() == _selfId) return;
    final conversationId = raw['conversationId']?.toString() ?? '';
    if (!strangersEnabled && !await _isApprovedMember(conversationId)) return;

    final forwarded = MeshRelayPolicy.prepareForward(
      packet: raw,
      selfId: _selfId,
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    if (forwarded == null) return;

    _markSeen(id);
    if (_pending.length >= _maxPending) {
      _pending.remove(_pending.keys.first);
    }
    _pending[id] = forwarded;
    await _persist();
    await _forward(forwarded, exclude: source);
  }

  void _markSeen(String id) {
    _seen.add(id);
    if (_seen.length > _seenCapacity) _seen.remove(_seen.first);
  }

  Future<void> _forward(Map<String, dynamic> packet, {String? exclude}) async {
    final encoded = jsonEncode(packet); // يحتوي _sig فيمرّ دون إعادة توقيع.
    try {
      await BluetoothClassicService.instance.broadcastMessage(
        encoded,
        excludeAddress: (exclude != null && !exclude.startsWith('lan:')) ? exclude : null,
      );
    } catch (_) {}
    try {
      await LocalNetworkService.instance.broadcastMessage(
        encoded,
        excludeAddress: (exclude != null && exclude.startsWith('lan:')) ? exclude : null,
      );
    } catch (_) {}
  }

  // ------------------------------------------------------ تبادل القوائم (gossip)

  Future<void> _send(String address, Map<String, dynamic> packet) async {
    final encoded = jsonEncode(packet);
    if (address.startsWith('lan:')) {
      await LocalNetworkService.instance.sendToAddress(address, encoded);
    } else {
      await BluetoothClassicService.instance.sendMessage(address: address, message: encoded);
    }
  }

  Future<void> _offerInventory(String address) async {
    _dropExpired();
    if (_pending.isEmpty) return;
    final items = _pending.entries
        .take(_maxHaveItems)
        .map((e) => <String, String>{
              'i': e.key,
              'c': e.value['conversationId']?.toString() ?? '',
            })
        .toList();
    try {
      await _send(address, <String, dynamic>{'type': 'mesh_have', 'items': items});
    } catch (_) {}
  }

  Future<void> _onHave(Map<String, dynamic> packet, String? address) async {
    if (address == null) return;
    final items = packet['items'];
    if (items is! List) return;
    final wanted = <String>[];
    for (final item in items.take(_maxHaveItems)) {
      if (item is! Map) continue;
      final id = item['i']?.toString() ?? '';
      final conversationId = item['c']?.toString() ?? '';
      if (id.isEmpty || _seen.contains(id)) continue;
      if (!strangersEnabled && !await _isApprovedMember(conversationId)) continue;
      wanted.add(id);
    }
    if (wanted.isEmpty) return;
    try {
      await _send(address, <String, dynamic>{'type': 'mesh_want', 'ids': wanted});
    } catch (_) {}
  }

  Future<void> _onWant(Map<String, dynamic> packet, String? address) async {
    if (address == null) return;
    final ids = packet['ids'];
    if (ids is! List) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    var sent = 0;
    for (final value in ids) {
      if (sent >= _maxWantItems) break;
      final stored = _pending[value.toString()];
      if (stored == null || MeshRelayPolicy.isExpired(stored, now)) continue;
      try {
        await _send(address, stored);
        sent++;
      } catch (_) {}
    }
  }

  // --------------------------------------------------------------- صيانة وحفظ

  void _dropExpired() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _pending.removeWhere((_, packet) => MeshRelayPolicy.isExpired(packet, now));
  }

  Future<void> _maintain() async {
    _dropExpired();
    await _persist();
    // أعد عرض القائمة على المتصلين حاليًا (معرّفات فقط، وليس الحزم).
    for (final address in List<String>.from(_btPeers)) {
      await _offerInventory(address);
    }
    for (final peer in LocalNetworkService.instance.discoveredPeers) {
      final ip = peer['address'];
      if (ip != null) await _offerInventory('lan:$ip');
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingKey, jsonEncode(_pending));
      await prefs.setStringList(_seenKey, _seen.toList());
    } catch (_) {}
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _seen.addAll(prefs.getStringList(_seenKey) ?? const <String>[]);
      final raw = prefs.getString(_pendingKey);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          decoded.forEach((key, value) {
            if (value is Map) _pending[key.toString()] = Map<String, dynamic>.from(value);
          });
        }
      }
      _dropExpired();
    } catch (_) {}
  }
}
