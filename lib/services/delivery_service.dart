import 'dart:async';
import 'dart:convert';

import 'bluetooth_classic_service.dart';
import 'local_network_service.dart';
import 'message_store.dart';

/// إقرار التسليم (ACK) للمحادثات الخاصة.
///
/// الطرف المستلم يرسل `{"type":"ack","ackId":<معرّف الرسالة>}` موقّعًا بعد حفظها.
/// هذه الخدمة تعمل على مستوى التطبيق كله (لا تعتمد على فتح شاشة المحادثة)،
/// فتعلّم الرسالة «وصلت» في قاعدة البيانات ثم تُبلغ الواجهة عبر [delivered].
///
/// نجاح كتابة المقبس لا يُعدّ تسليمًا؛ التسليم يثبت فقط بوصول ACK من المستلم.
class DeliveryService {
  DeliveryService._();
  static final DeliveryService instance = DeliveryService._();

  final MessageStore _store = MessageStore();
  final StreamController<String> _delivered = StreamController<String>.broadcast();
  StreamSubscription<BlousabEvent>? _bt;
  StreamSubscription<BlousabEvent>? _lan;

  /// معرّفات الرسائل التي أُكّد تسليمها.
  Stream<String> get delivered => _delivered.stream;

  void start() {
    _bt ??= BluetoothClassicService.instance.events.listen(_onEvent);
    _lan ??= LocalNetworkService.instance.events.listen(_onEvent);
  }

  Future<void> stop() async {
    await _bt?.cancel();
    await _lan?.cancel();
    _bt = null;
    _lan = null;
  }

  Future<void> _onEvent(BlousabEvent event) async {
    if (event.type != 'message' || event.message == null) return;
    try {
      final packet = jsonDecode(event.message!);
      if (packet is! Map || packet['type'] != 'ack') return;
      final ackId = packet['ackId']?.toString() ?? '';
      final conversationId = packet['conversationId']?.toString() ?? '';
      final signer = packet['_signer']?.toString() ?? '';
      // يجب أن يكون الموقّع هو الطرف الآخر في هذه المحادثة الخاصة.
      if (ackId.isEmpty || !conversationId.startsWith('dm_') || signer.isEmpty) return;
      final ids = conversationId.substring(3).split('_');
      if (!ids.contains(signer)) return;
      if (await _store.markDelivered(ackId, conversationId)) {
        _delivered.add(ackId);
      }
    } catch (_) {}
  }

  /// يرسل ACK إلى مصدر الرسالة. [address] هو عنوان الحدث (بلوتوث أو lan:IP).
  static Future<void> sendAck({
    required String messageId,
    required String conversationId,
    required String? address,
  }) async {
    if (address == null || address.isEmpty) return;
    final payload = jsonEncode(<String, dynamic>{
      'type': 'ack',
      'ackId': messageId,
      'conversationId': conversationId,
    });
    try {
      if (address.startsWith('lan:')) {
        await LocalNetworkService.instance.sendToAddress(address, payload);
      } else {
        await BluetoothClassicService.instance.sendMessage(address: address, message: payload);
      }
    } catch (_) {
      // فشل ACK لا يمنع عرض الرسالة؛ سيبقى المرسل يرى «أُرسلت» فقط.
    }
  }
}
