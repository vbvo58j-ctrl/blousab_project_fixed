import 'package:blousab/services/app_lock_service.dart';
import 'package:blousab/services/storage_ports.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MemoryStore vault;
  late int now;
  late AppLockService lock;

  setUp(() {
    vault = MemoryStore();
    now = 1000000;
    lock = AppLockService(vault: vault, clock: () => now, iterations: 1000);
  });

  test('الرمز لا يُخزَّن نصًا ويُقبل الصحيح فقط', () async {
    await lock.setPin('1234');
    expect(vault.data.values.any((v) => v == '1234'), isFalse);
    expect((await lock.verify('1234')).check, LockCheck.ok);
    expect((await lock.verify('9999')).check, LockCheck.wrong);
  });

  test('قفل مؤقت بعد 5 محاولات خاطئة ثم يزول بمرور الوقت', () async {
    await lock.setPin('1234');
    for (var i = 0; i < 4; i++) {
      expect((await lock.verify('0000')).check, LockCheck.wrong);
    }
    final fifth = await lock.verify('0000');
    expect(fifth.check, LockCheck.lockedOut);
    // حتى الرمز الصحيح مرفوض أثناء القفل.
    expect((await lock.verify('1234')).check, LockCheck.lockedOut);
    now += 31 * 1000;
    expect((await lock.verify('1234')).check, LockCheck.ok);
  });

  test('مدة القفل تتضاعف مع تكرار الفشل', () async {
    await lock.setPin('1234');
    for (var i = 0; i < 4; i++) {
      await lock.verify('0000');
    }
    final first = await lock.verify('0000');
    now += first.remaining.inMilliseconds + 1000;
    final second = await lock.verify('0000');
    expect(second.remaining.inSeconds, greaterThan(first.remaining.inSeconds));
  });

  test('ترحيل الرمز القديم النصي ثم حذفه', () async {
    final prefs = MemoryStore();
    prefs.data[AppLockService.legacyPrefKey] = '4321';
    await lock.migrateLegacy(prefs);
    expect(prefs.data.containsKey(AppLockService.legacyPrefKey), isFalse);
    expect(await lock.isSet(), isTrue);
    expect((await lock.verify('4321')).check, LockCheck.ok);
  });

  test('رمز غير صالح يُرفض', () async {
    expect(() => lock.setPin('12'), throwsArgumentError);
    expect(() => lock.setPin('abcd'), throwsArgumentError);
  });
}
