import 'package:blousab/services/mesh_relay_service.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> packet({
  int? ts,
  int hops = 0,
  bool relay = true,
  String type = 'chat',
  List<String>? path,
  String id = 'm1',
}) =>
    {
      'type': type,
      'id': id,
      'relay': relay,
      'hops': hops,
      if (ts != null) '_ts': ts,
      if (path != null) 'relayPath': path,
    };

void main() {
  const now = 1000000000000;

  test('يُمرَّر ويزيد hops ويضيف المعرّف إلى المسار', () {
    final out = MeshRelayPolicy.prepareForward(packet: packet(ts: now), selfId: 'me', nowMs: now)!;
    expect(out['hops'], 1);
    expect(out['relayPath'], ['me']);
  });

  test('لا يُمرَّر دون relay أو بنوع غير chat/file', () {
    expect(MeshRelayPolicy.prepareForward(packet: packet(ts: now, relay: false), selfId: 'me', nowMs: now), isNull);
    expect(MeshRelayPolicy.prepareForward(packet: packet(ts: now, type: 'hello'), selfId: 'me', nowMs: now), isNull);
  });

  test('لا يُمرَّر دون طابع زمني موقّع', () {
    expect(MeshRelayPolicy.prepareForward(packet: packet(), selfId: 'me', nowMs: now), isNull);
  });

  test('ينتهي بعد 6 ساعات من وقت المؤلف', () {
    final old = now - const Duration(hours: 6, minutes: 1).inMilliseconds;
    expect(MeshRelayPolicy.prepareForward(packet: packet(ts: old), selfId: 'me', nowMs: now), isNull);
    final fresh = now - const Duration(hours: 5).inMilliseconds;
    expect(MeshRelayPolicy.prepareForward(packet: packet(ts: fresh), selfId: 'me', nowMs: now), isNotNull);
  });

  test('سقف القفزات 8', () {
    expect(MeshRelayPolicy.prepareForward(packet: packet(ts: now, hops: 8), selfId: 'me', nowMs: now), isNull);
    expect(MeshRelayPolicy.prepareForward(packet: packet(ts: now, hops: 7), selfId: 'me', nowMs: now), isNotNull);
  });

  test('لا يعيد التمرير إذا مرّت الحزمة بهذا الجهاز من قبل', () {
    expect(MeshRelayPolicy.prepareForward(packet: packet(ts: now, path: ['x', 'me']), selfId: 'me', nowMs: now), isNull);
  });

  test('مسار أطول من الحد يُرفض', () {
    final path = List<String>.generate(16, (i) => 'n$i');
    expect(MeshRelayPolicy.prepareForward(packet: packet(ts: now, path: path), selfId: 'me', nowMs: now), isNull);
  });

  test('isExpired', () {
    expect(MeshRelayPolicy.isExpired(packet(), now), isTrue);
    expect(MeshRelayPolicy.isExpired(packet(ts: now), now), isFalse);
  });
}
