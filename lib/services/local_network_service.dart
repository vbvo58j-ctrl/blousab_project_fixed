import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'bluetooth_classic_service.dart';
import 'packet_security.dart';

/// نقل عبر الشبكة المحلية (Wi-Fi / نقطة اتصال).
///
/// * الاكتشاف: UDP بث على 255.255.255.255 وعلى عنوان البث الموجّه لكل شبكة فرعية
///   (x.y.z.255) لأن كثيرًا من أجهزة أندرويد والراوترات لا تمرّر البث العام.
/// * النقل: TCP بأسطر JSON. كل حزمة موقّعة عبر [PacketSecurity] قبل الإرسال،
///   وتُفحص قبل أن تصل إلى الواجهات.
/// * حدود صارمة على حجم السطر وعدد الاتصالات ومدتها لمنع استنزاف الذاكرة.
///
/// هذا مسار نقل محلي وليس ترحيلًا عبر الإنترنت.
class LocalNetworkService {
  LocalNetworkService._();
  static final LocalNetworkService instance = LocalNetworkService._();

  static const int _discoveryPort = 39772;
  static const int _tcpPort = 39771;

  /// أقصى طول لسطر واحد (الملفات تُرسل كـ Base64 داخل JSON).
  static const int maxLineBytes = PacketSecurity.maxPacketChars;
  static const int _maxClients = 12;
  static const Duration _connectionLifetime = Duration(seconds: 90);
  static const int _maxDiscoveryBytes = 1024;
  static const Duration _peerTimeout = Duration(seconds: 30);

  final StreamController<BlousabEvent> _events =
      StreamController<BlousabEvent>.broadcast();
  final Map<String, _LanPeer> _peers = <String, _LanPeer>{};

  RawDatagramSocket? _udp;
  ServerSocket? _server;
  Timer? _discoveryTimer;
  List<InternetAddress> _broadcastTargets = <InternetAddress>[
    InternetAddress('255.255.255.255'),
  ];
  int _discoveryTick = 0;
  int _activeClients = 0;
  String _userId = '';
  String _userName = 'مستخدم بلوساب';
  bool _running = false;

  Stream<BlousabEvent> get events => _events.stream;
  bool get isRunning => _running;
  int get peerCount => _peers.length;
  List<Map<String, String>> get discoveredPeers => _peers.values
      .map((p) => <String, String>{'id': p.id, 'name': p.name, 'address': p.address})
      .toList(growable: false);

  Future<void> start({required String userId, required String userName}) async {
    _userId = userId;
    _userName = userName;
    if (_running) {
      _sendDiscovery();
      return;
    }
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, _tcpPort, shared: true);
      _server!.listen(_acceptClient, onError: (Object error) {
        _emitError('تعذر استقبال اتصال الشبكة المحلية: $error');
      });
      _udp = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _discoveryPort,
        reuseAddress: true,
        reusePort: true,
      );
      _udp!.broadcastEnabled = true;
      _udp!.listen(_onUdpEvent, onError: (Object error) {
        _emitError('تعذر اكتشاف أجهزة الشبكة المحلية: $error');
      });
      _running = true;
      await _refreshBroadcastTargets();
      _sendDiscovery();
      _discoveryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _discoveryTick++;
        // عناوين الشبكة قد تتغير (تفعيل نقطة اتصال، تغيير Wi-Fi).
        if (_discoveryTick % 6 == 0) {
          _refreshBroadcastTargets();
        }
        _sendDiscovery();
        _prunePeers();
      });
      _events.add(const BlousabEvent(type: 'lanStarted'));
    } catch (e) {
      await stop();
      rethrow;
    }
  }

  Future<void> stop() async {
    _running = false;
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
    _udp?.close();
    _udp = null;
    await _server?.close();
    _server = null;
    _peers.clear();
    _events.add(const BlousabEvent(type: 'lanStopped'));
  }

  Future<void> _refreshBroadcastTargets() async {
    final targets = <String>{'255.255.255.255'};
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          // نفترض قناع /24 (الأشيع في الراوترات ونقاط الاتصال) لأن Dart لا يكشف القناع.
          if (parts.length == 4) targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
    } catch (_) {}
    _broadcastTargets = targets.map((t) => InternetAddress(t)).toList(growable: false);
  }

  void _sendDiscovery() {
    final udp = _udp;
    if (!_running || udp == null) return;
    final bytes = utf8.encode(jsonEncode({
      'kind': 'blousab_discovery',
      'peerId': _userId,
      'name': _userName,
      'port': _tcpPort,
    }));
    for (final target in _broadcastTargets) {
      try {
        udp.send(bytes, target, _discoveryPort);
      } catch (_) {}
    }
  }

  void _onUdpEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final udp = _udp;
    if (udp == null) return;
    Datagram? datagram;
    while ((datagram = udp.receive()) != null) {
      final current = datagram!;
      if (current.data.length > _maxDiscoveryBytes) continue;
      try {
        final packet = jsonDecode(utf8.decode(current.data));
        if (packet is! Map || packet['peerId']?.toString() == _userId) continue;
        final kind = packet['kind']?.toString();
        final peerId = packet['peerId']?.toString() ?? '';
        if (peerId.isEmpty || peerId.length > 64) continue;
        final name = _cleanName(packet['name']?.toString());
        final address = current.address.address;
        if (kind != 'blousab_discovery' && kind != 'blousab_peer') continue;

        final isNew = !_peers.containsKey(peerId);
        _peers[peerId] = _LanPeer(
          id: peerId,
          name: name,
          address: address,
          lastSeen: DateTime.now(),
        );
        if (isNew) {
          _events.add(BlousabEvent(
            type: 'lanPeer',
            address: 'lan:$address',
            name: name,
            message: peerId,
          ));
        }
        if (kind == 'blousab_discovery') {
          final reply = utf8.encode(jsonEncode({
            'kind': 'blousab_peer',
            'peerId': _userId,
            'name': _userName,
            'port': _tcpPort,
          }));
          udp.send(reply, current.address, _discoveryPort);
        }
      } catch (_) {}
    }
  }

  String _cleanName(String? raw) {
    final value = (raw ?? '').trim();
    if (value.isEmpty) return 'جهاز على الشبكة';
    return value.length > 40 ? value.substring(0, 40) : value;
  }

  void _prunePeers() {
    final cutoff = DateTime.now().subtract(_peerTimeout);
    _peers.removeWhere((_, peer) => peer.lastSeen.isBefore(cutoff));
  }

  // ---------------------------------------------------------------- الاستقبال

  void _acceptClient(Socket socket) {
    if (_activeClients >= _maxClients) {
      socket.destroy();
      return;
    }
    _activeClients++;
    final address = socket.remoteAddress.address;
    final buffer = BytesBuilder();
    var closed = false;
    Timer? lifetime;

    void finish() {
      if (closed) return;
      closed = true;
      lifetime?.cancel();
      _activeClients--;
      socket.destroy();
    }

    void deliver() {
      if (buffer.length == 0) return;
      final bytes = buffer.takeBytes();
      _handleIncomingLine(bytes, address);
    }

    lifetime = Timer(_connectionLifetime, finish);
    socket.listen(
      (Uint8List chunk) {
        var start = 0;
        while (start < chunk.length) {
          final newline = chunk.indexOf(10, start);
          final end = newline < 0 ? chunk.length : newline;
          if (buffer.length + (end - start) > maxLineBytes) {
            // سطر أكبر من الحد: اقطع الاتصال بدل تخزينه.
            buffer.clear();
            finish();
            return;
          }
          buffer.add(Uint8List.sublistView(chunk, start, end));
          if (newline < 0) break;
          deliver();
          start = newline + 1;
        }
      },
      onError: (Object error) => finish(),
      onDone: () {
        deliver();
        finish();
      },
      cancelOnError: true,
    );
  }

  Future<void> _handleIncomingLine(Uint8List bytes, String address) async {
    try {
      final line = utf8.decode(bytes);
      final secured = await secureIncomingEvent(BlousabEvent(
        type: 'message',
        address: 'lan:$address',
        name: 'شبكة محلية',
        message: line,
      ));
      if (secured != null) _events.add(secured);
    } catch (_) {
      // بيانات غير صالحة: تُهمل بصمت.
    }
  }

  // ----------------------------------------------------------------- الإرسال

  Future<bool> _sendLine(String address, String sealedPayload) async {
    Socket? socket;
    try {
      socket = await Socket.connect(address, _tcpPort, timeout: const Duration(seconds: 3));
      socket.write('$sealedPayload\n');
      await socket.flush();
      return true;
    } catch (_) {
      return false;
    } finally {
      try {
        await socket?.close();
      } catch (_) {
        socket?.destroy();
      }
    }
  }

  /// يرسل إلى كل الأجهزة المكتشفة بالتوازي. [excludeAddress] بصيغة lan:IP أو IP.
  Future<void> broadcastMessage(String payload, {String? excludeAddress}) async {
    if (!_running) throw StateError('الشبكة المحلية غير مفعلة');
    final excluded = (excludeAddress ?? '').replaceFirst('lan:', '');
    final targets = _peers.values.where((p) => p.address != excluded).toList(growable: false);
    if (targets.isEmpty) {
      throw StateError('لم يُعثر على أجهزة أخرى في الشبكة المحلية');
    }
    final sealed = await PacketSecurity.instance.seal(payload);
    final results = await Future.wait(targets.map((peer) => _sendLine(peer.address, sealed)));
    if (!results.any((ok) => ok)) {
      throw StateError('تعذر الإرسال عبر الشبكة المحلية');
    }
  }

  /// إرسال إلى عنوان IP محدد (يقبل lan:IP).
  Future<void> sendToAddress(String address, String payload) async {
    if (!_running) throw StateError('الشبكة المحلية غير مفعلة');
    final ip = address.replaceFirst('lan:', '');
    final sealed = await PacketSecurity.instance.seal(payload);
    if (!await _sendLine(ip, sealed)) {
      throw StateError('تعذر الإرسال إلى $ip');
    }
  }

  /// إرسال إلى جهاز مكتشف بمعرّفه.
  Future<void> sendToPeer(String peerId, String payload) async {
    final peer = _peers[peerId];
    if (peer == null) throw StateError('الجهاز غير ظاهر على الشبكة المحلية');
    await sendToAddress(peer.address, payload);
  }

  void _emitError(String message) {
    _events.add(BlousabEvent(type: 'lanError', message: message));
  }
}

class _LanPeer {
  final String id;
  final String name;
  final String address;
  DateTime lastSeen;
  _LanPeer({
    required this.id,
    required this.name,
    required this.address,
    required this.lastSeen,
  });
}
