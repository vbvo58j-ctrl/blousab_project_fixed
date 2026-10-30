import 'dart:convert';

import 'package:blousab/services/identity_service.dart';
import 'package:blousab/services/packet_security.dart';
import 'package:blousab/services/storage_ports.dart';
import 'package:flutter_test/flutter_test.dart';

class _Node {
  _Node(this.memory, this.identity, this.security);
  final MemoryStore memory;
  final IdentityService identity;
  final PacketSecurity security;
}

Future<_Node> makeNode({
  int Function()? clock,
  Map<String, List<int>>? groupKeys,
  String? presetId,
}) async {
  final memory = MemoryStore();
  if (presetId != null) memory.data[IdentityService.userIdKey] = presetId;
  final identity = IdentityService(vault: memory, store: memory);
  await identity.ensureInitialized();
  final keys = groupKeys ?? <String, List<int>>{};
  final security = PacketSecurity(
    identity: identity,
    peerKeys: KeyValuePeerKeyStore(memory),
    groupKeys: (conversationId) async => keys[conversationId],
    clock: clock,
  );
  return _Node(memory, identity, security);
}

String chat(String id, String text, {String conversation = 'c1', bool relay = false}) =>
    jsonEncode({
      'type': 'chat',
      'id': id,
      'conversationId': conversation,
      'text': text,
      'hops': 0,
      'relay': relay,
    });

void main() {
  test('canonicalJson ترتّب المفاتيح تصاعديًا حتى في الكائنات المتداخلة', () {
    final a = PacketSecurity.canonicalJson({'b': 1, 'a': {'d': 2, 'c': [3, 1]}});
    final b = PacketSecurity.canonicalJson({'a': {'c': [3, 1], 'd': 2}, 'b': 1});
    expect(a, b);
    expect(a, '{"a":{"c":[3,1],"d":2},"b":1}');
  });

  test('المعرّف الجديد مشتق من المفتاح العام ويبدأ بـ bx', () async {
    final node = await makeNode();
    expect(node.identity.userId.startsWith('bx'), isTrue);
    expect(node.identity.userId, await IdentityService.idForPublicKey(node.identity.edPublicKey));
  });

  test('توقيع ثم فحص: حزمة سليمة', () async {
    final a = await makeNode();
    final b = await makeNode();
    final sealed = await a.security.seal(chat('m1', 'مرحبا'));
    final opened = await b.security.open(sealed);
    expect(opened, isNotNull);
    expect(opened!.readable, isTrue);
    expect(opened.signerId, a.identity.userId);
    final plain = jsonDecode(opened.plain) as Map<String, dynamic>;
    expect(plain['text'], 'مرحبا');
    expect(plain['senderId'], a.identity.userId);
    expect(plain.containsKey('_sig'), isFalse);
  });

  test('تعديل المحتوى يُبطل التوقيع', () async {
    final a = await makeNode();
    final b = await makeNode();
    final sealed = jsonDecode(await a.security.seal(chat('m1', 'مرحبا'))) as Map<String, dynamic>;
    sealed['text'] = 'نص معدّل';
    expect(await b.security.open(jsonEncode(sealed)), isNull);
  });

  test('تغيير hops وrelayPath عند الترحيل لا يُبطل التوقيع', () async {
    final a = await makeNode();
    final b = await makeNode();
    final sealed = jsonDecode(await a.security.seal(chat('m1', 'x', relay: true))) as Map<String, dynamic>;
    sealed['hops'] = 3;
    sealed['relayPath'] = ['r1', 'r2'];
    expect(await b.security.open(jsonEncode(sealed)), isNotNull);
  });

  test('لا يمكن توقيع حزمة باسم مستخدم آخر', () async {
    final a = await makeNode();
    final b = await makeNode();
    final forged = jsonEncode({
      'type': 'chat', 'id': 'x', 'conversationId': 'c1', 'text': 'hi',
      'senderId': b.identity.userId,
    });
    expect(() => a.security.seal(forged), throwsStateError);
  });

  test('انتحال معرّف مستخدم آخر بتوقيع مفتاح مختلف يُرفض', () async {
    final victim = await makeNode();
    final attacker = await makeNode();
    final receiver = await makeNode();
    // المهاجم يبني حزمة تدّعي معرّف الضحية ويوقّعها بمفتاحه.
    final map = <String, dynamic>{
      'type': 'chat', 'id': 'evil', 'conversationId': 'c1', 'text': 'أنا الضحية',
      'senderId': victim.identity.userId,
      '_v': 1,
      '_pk': base64Encode(attacker.identity.edPublicKey),
      '_xpk': base64Encode(attacker.identity.xPublicKey),
      '_ts': DateTime.now().millisecondsSinceEpoch,
    };
    final sig = await attacker.identity.sign(utf8.encode(PacketSecurity.canonicalJson(map)));
    map['_sig'] = base64Encode(sig);
    expect(await receiver.security.open(jsonEncode(map)), isNull);
  });

  test('إعادة إرسال الحزمة نفسها تُرفض', () async {
    final a = await makeNode();
    final b = await makeNode();
    final sealed = await a.security.seal(chat('m1', 'x'));
    expect(await b.security.open(sealed), isNotNull);
    expect(await b.security.open(sealed), isNull);
  });

  test('حزمة أقدم من 3 أيام أو من المستقبل البعيد تُرفض', () async {
    final a = await makeNode();
    final future = await makeNode(
      clock: () => DateTime.now().millisecondsSinceEpoch + const Duration(days: 4).inMilliseconds,
    );
    final past = await makeNode(
      clock: () => DateTime.now().millisecondsSinceEpoch - const Duration(days: 4).inMilliseconds,
    );
    final sealed = await a.security.seal(chat('m1', 'x'));
    expect(await future.security.open(sealed), isNull); // قديمة بالنسبة له
    final sealedFuture = await past.security.seal(chat('m2', 'y'));
    final receiver = await makeNode();
    expect(await receiver.security.open(sealedFuture), isNull);
  });

  test('تشفير المجتمع: العضو يقرأ والوسيط لا يرى النص لكنه يمرّر', () async {
    final key = List<int>.generate(32, (i) => i + 1);
    final a = await makeNode(groupKeys: {'c1': key});
    final member = await makeNode(groupKeys: {'c1': key});
    final stranger = await makeNode();
    final sealed = await a.security.seal(chat('m1', 'سر المجتمع', relay: true));
    expect(sealed.contains('سر المجتمع'), isFalse);

    final readable = await member.security.open(sealed);
    expect(readable!.readable, isTrue);
    expect((jsonDecode(readable.plain) as Map)['text'], 'سر المجتمع');

    final blind = await stranger.security.open(sealed);
    expect(blind, isNotNull);
    expect(blind!.readable, isFalse);
    expect(blind.raw, sealed);
  });

  test('تشفير المحادثة الخاصة بين طرفين بعد تبادل المفاتيح', () async {
    final a = await makeNode();
    final b = await makeNode();
    final ids = [a.identity.userId, b.identity.userId]..sort();
    final conversation = 'dm_${ids[0]}_${ids[1]}';

    // تبادل المفاتيح: أول حزمة من كل طرف تحمل مفتاح X25519.
    await b.security.open(await a.security.seal(jsonEncode({'type': 'hello', 'senderName': 'A'})));
    await a.security.open(await b.security.seal(jsonEncode({'type': 'hello_ack', 'senderName': 'B'})));

    final sealed = await a.security.seal(chat('d1', 'رسالة خاصة', conversation: conversation));
    expect(sealed.contains('رسالة خاصة'), isFalse);
    final opened = await b.security.open(sealed);
    expect(opened!.readable, isTrue);
    expect((jsonDecode(opened.plain) as Map)['text'], 'رسالة خاصة');

    // طرف ثالث لا يستطيع القراءة.
    final eve = await makeNode();
    final blind = await eve.security.open(sealed);
    expect(blind == null || !blind.readable, isTrue);
  });

  test('المعرّف القديم يُثبَّت مفتاحه عند أول اتصال (TOFU)', () async {
    final first = await makeNode(presetId: '1700000000000000');
    final impostor = await makeNode(presetId: '1700000000000000');
    final receiver = await makeNode();
    final okPacket = await first.security.seal(chat('m1', 'x'));
    expect(await receiver.security.open(okPacket), isNotNull);
    final badPacket = await impostor.security.seal(chat('m2', 'y'));
    expect(await receiver.security.open(badPacket), isNull);
  });

  test('حزمة بلا توقيع أو بنص عادي تُرفض', () async {
    final b = await makeNode();
    expect(await b.security.open(chat('m1', 'x')), isNull);
    expect(await b.security.open('not json'), isNull);
    expect(await b.security.open(''), isNull);
  });
}
