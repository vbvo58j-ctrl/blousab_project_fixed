import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'screens/communities_screen.dart';
import 'screens/developer_chat_preview_screen.dart';
import 'screens/stories_strip.dart';
import 'screens/public_feed_screen.dart';
import 'services/app_lock_service.dart';
import 'services/background_service.dart';
import 'services/bluetooth_classic_service.dart';
import 'services/delivery_service.dart';
import 'services/identity_service.dart';
import 'services/local_network_service.dart';
import 'services/mesh_relay_service.dart';
import 'services/notification_service.dart';
import 'services/storage_ports.dart';

const String supportUrl = 'https://wsend.co/967737414884';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // الهوية أولًا: تُنشأ المفاتيح ويُضبط wasl_user_id قبل أن تقرأه أي شاشة.
  try {
    await IdentityService.instance.ensureInitialized();
  } catch (_) {}
  DeliveryService.instance.start();
  try {
    await NotificationService.instance.initialize();
    await NotificationService.instance.requestPermission();
  } catch (_) {}
  runApp(const BlousabApp());
}

class BlousabApp extends StatelessWidget {
  const BlousabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'بلوساب',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF128C7E)),
        useMaterial3: true,
        fontFamily: 'sans-serif',
        appBarTheme: const AppBarTheme(centerTitle: false),
      ),
      home: const BluetoothGate(),
    );
  }
}

class BluetoothGate extends StatefulWidget {
  const BluetoothGate({super.key});

  @override
  State<BluetoothGate> createState() => _BluetoothGateState();
}

class _BluetoothGateState extends State<BluetoothGate> {
  final BluetoothClassicService _bluetooth = BluetoothClassicService.instance;
  bool _checking = true;
  bool _supported = false;
  bool _enabled = false;
  bool _busy = false;
  String _status = 'جارٍ التحقق من البلوتوث…';

  @override
  void initState() {
    super.initState();
    _checkBluetooth();
  }

  Future<void> _checkBluetooth() async {
    if (mounted) setState(() { _checking = true; });
    try {
      final supported = await _bluetooth.isSupported();
      if (!supported) {
        if (mounted) setState(() {
          _supported = false;
          _enabled = false;
          _status = 'هذا الهاتف لا يدعم Bluetooth Classic.';
          _checking = false;
        });
        return;
      }
      final permissions = await _bluetooth.requestPermissions();
      if (!permissions) {
        if (mounted) setState(() {
          _supported = true;
          _enabled = false;
          _status = 'يلزم السماح بصلاحيات البلوتوث للمتابعة.';
          _checking = false;
        });
        return;
      }
      final enabled = await _bluetooth.isEnabled();
      if (!mounted) return;
      setState(() {
        _supported = true;
        _enabled = enabled;
        _status = enabled
            ? 'البلوتوث جاهز. يمكنك فتح بلوساب.'
            : 'شغّل البلوتوث للمتابعة إلى التطبيق.';
        _checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _status = 'تعذر التحقق من البلوتوث. تحقق من الصلاحيات ثم أعد المحاولة.';
        _checking = false;
      });
    }
  }

  Future<void> _enableBluetooth() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (!await _bluetooth.requestPermissions()) {
        _notice('لم تُمنح صلاحيات البلوتوث.');
        return;
      }
      if (!await _bluetooth.isEnabled()) {
        await _bluetooth.requestEnable();
        _notice('وافق على تشغيل البلوتوث في نافذة Android، ثم اضغط «إعادة التحقق».');
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await _checkBluetooth();
    } catch (e) {
      _notice('تعذر تشغيل البلوتوث: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _notice(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    // Do not block the whole app when Bluetooth is disabled: Wi-Fi mode and settings must remain accessible.
    return const BlousabShell();

    /* Legacy Bluetooth gate UI retained below for reference.
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 96,
                    height: 96,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Icon(Icons.bluetooth, size: 54,
                      color: Theme.of(context).colorScheme.onPrimaryContainer),
                  ),
                  const SizedBox(height: 24),
                  Text('بلوساب', style: Theme.of(context).textTheme.headlineLarge?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  const Text('تواصل محلي عبر Bluetooth Classic', textAlign: TextAlign.center),
                  const SizedBox(height: 18),
                  Text(_status, textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  if (_checking || _busy) const CircularProgressIndicator(),
                  if (!_checking && !_enabled) ...[
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _supported ? _enableBluetooth : null,
                        icon: const Icon(Icons.bluetooth_searching),
                        label: const Text('تشغيل البلوتوث'),
                      ),
                    ),
                    TextButton(
                      onPressed: _busy ? null : _checkBluetooth,
                      child: const Text('إعادة التحقق'),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'لن تظهر واجهة المحادثات حتى يتم تفعيل البلوتوث.',
                    style: Theme.of(context).textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    */
  }
}

class BlousabShell extends StatefulWidget {
  const BlousabShell({super.key});

  @override
  State<BlousabShell> createState() => _BlousabShellState();
}

class _BlousabShellState extends State<BlousabShell> with WidgetsBindingObserver {
  String _userName = 'مستخدم بلوساب';
  String _background = 'داكن';
  String _chatWallpaper = 'mint';
  String _profilePhotoPath = ''; // صورة الملف الشخصي
  int _homeTabIndex = 0; // تبدأ الواجهة بالمحادثات
  bool _lanEnabled = true;
  bool _nearbyVisible = true;
  String _connectionMode = 'bluetooth';
  double _messageFontSize = 16;
  bool _showMessageTime = true;
  bool _vibrateOnSend = true;
  bool _compactBubbles = false;
  bool _appLockEnabled = false;
  bool _appLocked = false;
  StreamSubscription<BlousabEvent>? _notificationBluetoothSubscription;
  final Map<String, int> _smartReconnectAttempts = {};
  final Set<String> _smartReconnectPending = {};
  bool _meshRelayEnabled = true;
  bool _smartReconnectEnabled = true;
  StreamSubscription<BlousabEvent>? _notificationLanSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSettings();
    _startNotificationListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_appLockEnabled) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      if (mounted) setState(() => _appLocked = true);
    }
  }

  Future<void> _manageAppLock() async {
    final lockIsSet = await AppLockService.instance.isSet();
    if (!mounted) return;
    final pinController = TextEditingController();
    final confirmController = TextEditingController();
    final result = await showDialog<Map<String, String>?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('قفل التطبيق'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(lockIsSet ? 'يمكنك تغيير رمز القفل أو إلغاء القفل من الزر أدناه.' : 'أنشئ رمزًا من 4 إلى 8 أرقام لقفل بلوساب.'),
          const SizedBox(height: 12),
          TextField(controller: pinController, keyboardType: TextInputType.number, obscureText: true, maxLength: 8, decoration: const InputDecoration(labelText: 'رمز القفل (4-8 أرقام)')),
          TextField(controller: confirmController, keyboardType: TextInputType.number, obscureText: true, maxLength: 8, decoration: const InputDecoration(labelText: 'تأكيد الرمز')),
          const SizedBox(height: 8),
          const Text('الرمز يُحفظ مجزّأً في مخزن أندرويد الآمن، وبعد 5 محاولات خاطئة يُقفل التطبيق مؤقتًا. هذا القفل لا يشفّر بياناتك على القرص.', style: TextStyle(fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('رجوع')),
          if (lockIsSet)
            TextButton(
              onPressed: () => Navigator.pop(ctx, {'pin': ''}),
              child: const Text('إلغاء القفل'),
            ),
          FilledButton(onPressed: () {
            final pin = pinController.text.trim();
            final confirm = confirmController.text.trim();
            if (!AppLockService.isValidPin(pin) || pin != confirm) {
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('أدخل رمزًا من 4 إلى 8 أرقام وتأكد من تطابقه.'))); return;
            }
            Navigator.pop(ctx, {'pin': pin});
          }, child: const Text('حفظ'))],
      ),
    );
    pinController.dispose(); confirmController.dispose();
    if (result == null) return;
    final pin = result['pin'] ?? '';
    final prefs = await SharedPreferences.getInstance();
    if (pin.isEmpty) {
      await AppLockService.instance.clear();
      await prefs.setBool('blousab_app_lock_enabled', false);
      if (mounted) setState(() { _appLockEnabled = false; _appLocked = false; });
    } else {
      await AppLockService.instance.setPin(pin);
      await prefs.setBool('blousab_app_lock_enabled', true);
      if (mounted) setState(() { _appLockEnabled = true; _appLocked = false; });
    }
  }

  Future<void> _unlockApp() async {
    final controller = TextEditingController();
    final entered = await showDialog<String>(context: context, barrierDismissible: false, builder: (ctx) => AlertDialog(
      title: const Text('بلوساب مقفل'),
      content: TextField(controller: controller, autofocus: true, keyboardType: TextInputType.number, obscureText: true, decoration: const InputDecoration(labelText: 'أدخل رمز القفل')),
      actions: [FilledButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('فتح التطبيق'))],
    ));
    controller.dispose();
    if (entered == null || !mounted) return;
    final check = await AppLockService.instance.verify(entered);
    if (!mounted) return;
    switch (check.check) {
      case LockCheck.ok:
        setState(() => _appLocked = false);
        break;
      case LockCheck.lockedOut:
        final seconds = check.remaining.inSeconds + 1;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('محاولات كثيرة خاطئة. حاول بعد $seconds ثانية.')));
        break;
      case LockCheck.wrong:
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('رمز القفل غير صحيح.')));
        break;
    }
  }

  void _startNotificationListeners() {
    _notificationBluetoothSubscription = BluetoothClassicService.instance.events.listen((event) {
      if (event.type == 'message' && event.message != null) {
        _notifyForIncoming(event.message!);
      }
      // Smart connection: remember a successful peer and retry transient drops.
      if (event.type == 'connected' && event.address != null) {
        _smartReconnectAttempts.remove(event.address);
        _smartReconnectPending.remove(event.address);
      } else if ((event.type == 'disconnected' || event.type == 'connectionError') && event.address != null) {
        _scheduleSmartReconnect(event.address!);
      }
    });
    _notificationLanSubscription = LocalNetworkService.instance.events.listen((event) {
      if (event.type == 'message' && event.message != null) {
        _notifyForIncoming(event.message!);
      }
    });
  }

  Future<void> _scheduleSmartReconnect(String address) async {
    if (!_smartReconnectEnabled || address.isEmpty || _smartReconnectPending.contains(address)) return;
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('blousab_smart_connection') ?? true)) return;
    final attempt = _smartReconnectAttempts[address] ?? 0;
    // Limit retries to avoid draining the battery or repeatedly disturbing Android.
    if (attempt >= 4) return;
    _smartReconnectAttempts[address] = attempt + 1;
    _smartReconnectPending.add(address);
    final seconds = [2, 5, 10, 20][attempt];
    Future<void>.delayed(Duration(seconds: seconds), () async {
      try {
        if (!(prefs.getBool('blousab_smart_connection') ?? true)) return;
        if (await BluetoothClassicService.instance.isEnabled()) {
          await BluetoothClassicService.instance.connect(address);
        }
      } catch (_) {
        // The next native disconnect/error event may schedule another bounded retry.
      } finally {
        _smartReconnectPending.remove(address);
      }
    });
  }

  Future<void> _notifyForIncoming(String raw) async {
    final prefs = await SharedPreferences.getInstance();
    final currentUserId = prefs.getString('wasl_user_id') ?? 'blousab-user';
    await NotificationService.instance.handleIncomingPayload(raw, currentUserId: currentUserId);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _notificationBluetoothSubscription?.cancel();
    _smartReconnectEnabled = false;
    _notificationLanSubscription?.cancel();
    super.dispose();
  }

  Future<void> _startBluetoothListener() async {
    try {
      await BluetoothClassicService.instance.startServer();
    } catch (_) {
      // The user can start listening from the Bluetooth action if Android
      // has just returned from the system permission/enable dialog.
    }
  }

  Future<void> _startNearbyVisibility() async {
    // Best-effort visibility: Android controls discoverability prompts/duration.
    try {
      final service = BluetoothClassicService.instance;
      if (await service.isSupported() && await service.isEnabled()) {
        await service.startServer();
        await service.requestDiscoverable();
      }
    } catch (_) {
      // Keep the app usable if Bluetooth permissions or system approval are missing.
    }
  }

  Future<void> _setNearbyVisibility(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('blousab_nearby_visible', enabled);
    if (!mounted) return;
    setState(() => _nearbyVisible = enabled);
    if (enabled) {
      await _startNearbyVisibility();
      final userId = prefs.getString('wasl_user_id') ?? 'blousab-user';
      try {
        await LocalNetworkService.instance.start(userId: userId, userName: _userName);
      } catch (_) {}
    } else {
      try { await BluetoothClassicService.instance.stopServer(); } catch (_) {}
      try { await LocalNetworkService.instance.stop(); } catch (_) {}
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _userName = prefs.getString('wasl_user_name') ?? 'مستخدم بلوساب';
      _background = prefs.getString('wasl_background') ?? 'داكن';
      _chatWallpaper = prefs.getString('wasl_chat_wallpaper') ?? 'mint';
      _profilePhotoPath = prefs.getString('wasl_profile_photo') ?? '';
      _lanEnabled = prefs.getBool('blousab_lan_enabled') ?? true;
      _meshRelayEnabled = prefs.getBool('blousab_use_relay') ?? false;
      _nearbyVisible = prefs.getBool('blousab_nearby_visible') ?? true;
      _connectionMode = prefs.getString('blousab_connection_mode') ?? 'bluetooth';
      _messageFontSize = (prefs.getDouble('blousab_message_font_size') ?? 16).clamp(14, 22).toDouble();
      _showMessageTime = prefs.getBool('blousab_show_message_time') ?? true;
      _vibrateOnSend = prefs.getBool('blousab_vibrate_on_send') ?? true;
      _compactBubbles = prefs.getBool('blousab_compact_bubbles') ?? false;
    });
    // الرمز القديم (نص صريح) يُرحَّل إلى تجزئة مملّحة ثم يُحذف.
    try { await AppLockService.instance.migrateLegacy(const PrefsKeyValueStore()); } catch (_) {}
    final lockIsSet = await AppLockService.instance.isSet();
    if (mounted) {
      setState(() {
        _appLockEnabled = lockIsSet;
        _appLocked = lockIsSet;
      });
    }
    await MeshRelayService.instance.start(
      selfId: IdentityService.instance.userId.isNotEmpty
          ? IdentityService.instance.userId
          : (prefs.getString('wasl_user_id') ?? ''),
      strangersEnabled: _meshRelayEnabled,
    );
    await BackgroundService.instance.syncWithSettings();
    await _requestInitialPermissionsOnce(prefs);
    await _ensureBluetoothOnLaunch();
    if (_nearbyVisible) {
      await _startNearbyVisibility();
    }
    if (_nearbyVisible && (_lanEnabled || _connectionMode == 'wifi')) {
      final id = prefs.getString('wasl_user_id') ?? 'blousab-user';
      try { await LocalNetworkService.instance.start(userId: id, userName: _userName); } catch (_) {}
    }
  }

  Future<void> _ensureBluetoothOnLaunch() async {
    try {
      final service = BluetoothClassicService.instance;
      if (!await service.isSupported()) return;
      // If permission was denied on the first-run request, do not keep prompting.
      final sdk = await service.getAndroidSdk();
      if (sdk >= 31) {
        final connect = await Permission.bluetoothConnect.status;
        final scan = await Permission.bluetoothScan.status;
        final advertise = await Permission.bluetoothAdvertise.status;
        if (!connect.isGranted || !scan.isGranted || !advertise.isGranted) return;
      }
      if (!await service.isEnabled()) {
        // Android displays its own approval dialog; apps cannot silently turn BT on.
        await service.requestEnable();
      }
      if (await service.isEnabled()) {
        await service.startServer();
      }
    } catch (_) {
      // Keep the rest of the app usable if the user declines or the device disallows it.
    }
  }

  /// Android runtime/special permissions are requested during first app setup,
  /// not from a persistent settings row. Android may still show system approval UI.
  Future<void> _requestInitialPermissionsOnce(SharedPreferences prefs) async {
    if (prefs.getBool('blousab_initial_permissions_attempted') == true) return;
    // Set first to prevent repeated prompts if Android pauses/recreates the app.
    await prefs.setBool('blousab_initial_permissions_attempted', true);
    try {
      final sdk = await BluetoothClassicService.instance.getAndroidSdk();
      if (sdk >= 31) {
        await <Permission>[
          Permission.bluetoothConnect,
          Permission.bluetoothScan,
          Permission.bluetoothAdvertise,
        ].request();
      } else if (sdk > 0 && sdk <= 30) {
        await Permission.locationWhenInUse.request();
      }
    } catch (_) {}
    try { await Permission.nearbyWifiDevices.request(); } catch (_) {}
    try { await Permission.notification.request(); } catch (_) {}
  }

  Future<String?> _pickAndStoreProfilePhoto() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 65,
        maxWidth: 640,
      );
      if (picked == null) return null;
      // Gallery providers may return temporary/cache paths. Copy the image
      // into the app's documents directory so the profile photo persists.
      final directory = await getApplicationDocumentsDirectory();
      final profileDirectory = Directory('${directory.path}/profile');
      if (!await profileDirectory.exists()) {
        await profileDirectory.create(recursive: true);
      }
      final extension = picked.path.contains('.')
          ? picked.path.substring(picked.path.lastIndexOf('.'))
          : '.jpg';
      final destination = File(
        '${profileDirectory.path}/profile_photo${extension.toLowerCase()}',
      );
      if (await destination.exists()) await destination.delete();
      await File(picked.path).copy(destination.path);
      return destination.path;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('تعذر اختيار الصورة. تحقق من صلاحية الوصول للصور ثم حاول مجددًا.')),
        );
      }
      return null;
    }
  }

  Future<void> _announceProfileUpdate({required String userId, required String userName}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final path = prefs.getString('wasl_profile_photo') ?? '';
      String? photo;
      if (path.isNotEmpty) {
        final file = File(path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (bytes.isNotEmpty && bytes.length <= 100 * 1024) {
            photo = base64Encode(bytes);
          }
        }
      }
      final packet = jsonEncode({
        'type': 'profile_update',
        'senderId': userId,
        'senderName': userName,
        if (photo != null) 'senderPhoto': photo,
      });

      // Send updates to Bluetooth peers used in previous direct conversations.
      final addresses = <String>{};
      for (final key in prefs.getKeys()) {
        if (key.startsWith('blousab_last_device_dm_')) {
          final address = prefs.getString(key);
          if (address != null && address.isNotEmpty && !address.startsWith('lan:')) {
            addresses.add(address);
          }
        }
      }
      for (final address in addresses) {
        try {
          await BluetoothClassicService.instance.sendMessage(address: address, message: packet);
        } catch (_) {
          // A saved peer may be offline; the next handshake/message refreshes the profile.
        }
      }

      // Also publish to discovered peers on the same local Wi-Fi network.
      try {
        if (LocalNetworkService.instance.isRunning) {
          await LocalNetworkService.instance.broadcastMessage(packet);
        }
      } catch (_) {}
    } catch (_) {}
  }

  Future<void> _manageConnectivityPermissions() async {
    final messages = <String>[];
    try {
      final bluetoothStatuses = await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.bluetoothAdvertise,
      ].request();
      final bluetoothGranted = bluetoothStatuses.values.every((status) => status.isGranted);
      messages.add(bluetoothGranted
          ? 'صلاحيات البلوتوث: ممنوحة.'
          : 'بعض صلاحيات البلوتوث لم تُمنح؛ يمكنك السماح بها من إعدادات التطبيق.');
    } catch (_) {
      messages.add('تعذر طلب صلاحيات البلوتوث تلقائيًا على هذا الإصدار.');
    }
    try {
      final wifiStatus = await Permission.nearbyWifiDevices.request();
      messages.add(wifiStatus.isGranted
          ? 'صلاحية أجهزة Wi-Fi القريبة: ممنوحة.'
          : 'صلاحية أجهزة Wi-Fi القريبة غير ممنوحة أو غير مطلوبة على هذا الهاتف.');
    } catch (_) {
      // Permission is not available on every Android version.
    }
    // Battery optimization exemption is special Android access. Check it
    // through the native API and open Android's official consent screen.
    try {
      const batteryChannel = MethodChannel('com.blousab.messenger/battery');
      var exempt = await batteryChannel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
      if (!exempt && Platform.isAndroid) {
        messages.add('تحسينات البطارية: غير مستثنى.');
        // Keep this action explicit and user-initiated from the permissions dialog.
      } else {
        messages.add(exempt
            ? 'العمل دون قيود تحسينات البطارية: مفعّل.'
            : 'حالة تحسينات البطارية غير متاحة على هذا النظام.');
      }
    } catch (_) {
      messages.add('تعذر التحقق من حالة استثناء تحسينات البطارية.');
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('صلاحيات بلوساب'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final message in messages) Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('• $message'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.battery_saver),
              label: const Text('إعدادات تحسين البطارية'),
              onPressed: () async {
                try {
                  const batteryChannel = MethodChannel('com.blousab.messenger/battery');
                  await batteryChannel.invokeMethod<bool>('requestIgnoreBatteryOptimizations');
                } catch (_) {
                  try { await openAppSettings(); } catch (_) {}
                }
              },
            ),
            const Text('بعد الرجوع من إعدادات أندرويد، افتح صفحة الصلاحيات مرة أخرى للتحقق من الحالة. هذا الاستثناء يساعد على استمرار العمل في الخلفية لكنه لا يلغي جميع قيود النظام.'),
          ]),
        ),
        actions: [
          TextButton(onPressed: () async { Navigator.pop(dialogContext); await openAppSettings(); }, child: const Text('إعدادات التطبيق')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('تم')),
        ],
      ),
    );
  }

  Future<void> _openSettings() async {
    final nameController = TextEditingController(text: _userName);
    bool selectedKeepAlive = await BackgroundService.instance.isEnabled();
    if (!mounted) return;
    String selectedBackground = _background;
    String selectedWallpaper = _chatWallpaper;
    String selectedPhotoPath = _profilePhotoPath;
    bool photoWasPicked = false;
    bool selectedLan = _lanEnabled;
    bool selectedRelayEnabled = _meshRelayEnabled;
    bool selectedNearbyVisible = _nearbyVisible;
    String selectedMode = _connectionMode;
    double selectedFontSize = _messageFontSize;
    bool selectedShowTime = _showMessageTime;
    bool selectedVibrate = _vibrateOnSend;
    bool selectedCompact = _compactBubbles;
    final result = await showDialog<Map<String, Object?>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => Theme(
        // Rebuild the entire settings theme when the user changes appearance.
        // Builder below ensures Theme.of(context) reads this theme, not the page theme.
        data: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF128C7E),
            brightness: selectedBackground == 'فاتح' ? Brightness.light : Brightness.dark,
          ),
          useMaterial3: true,
          fontFamily: 'sans-serif',
          scaffoldBackgroundColor: selectedBackground == 'فاتح' ? const Color(0xFFF4FAF8) : const Color(0xFF101414),
          cardTheme: CardThemeData(
            color: selectedBackground == 'فاتح' ? const Color(0xFFFFFFFF) : const Color(0xFF1B2422),
            elevation: 1,
          ),
          dialogTheme: DialogThemeData(
            backgroundColor: selectedBackground == 'فاتح' ? const Color(0xFFF7FBFA) : const Color(0xFF151B1A),
          ),
        ),
        child: Builder(
          builder: (context) => AlertDialog(
          insetPadding: EdgeInsets.zero,
          constraints: const BoxConstraints.expand(),
          shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
          elevation: 0,
          backgroundColor: Theme.of(context).colorScheme.surface,
          titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          contentPadding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          actionsPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          title: Row(children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(Icons.settings_outlined, color: Theme.of(context).colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 12),
            const Expanded(child: Text('الإعدادات', style: TextStyle(fontWeight: FontWeight.bold))),
            IconButton(
              tooltip: 'إغلاق الإعدادات',
              onPressed: () => Navigator.pop(dialogContext),
              icon: const Icon(Icons.close),
            ),
          ]),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.45),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(children: [
                    GestureDetector(
                      onTap: () async {
                        final path = await _pickAndStoreProfilePhoto();
                        if (path != null) setDialogState(() { selectedPhotoPath = path; photoWasPicked = true; });
                      },
                      child: Stack(alignment: Alignment.bottomRight, children: [
                        CircleAvatar(
                          radius: 43,
                          backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.15),
                          backgroundImage: selectedPhotoPath.isNotEmpty && File(selectedPhotoPath).existsSync() ? FileImage(File(selectedPhotoPath)) : null,
                          child: selectedPhotoPath.isEmpty || !File(selectedPhotoPath).existsSync() ? const Icon(Icons.person, size: 48) : null,
                        ),
                        CircleAvatar(radius: 14, child: const Icon(Icons.camera_alt, size: 16)),
                      ]),
                    ),
                    const SizedBox(height: 8),
                    Text(nameController.text.trim().isEmpty ? 'مستخدم بلوساب' : nameController.text.trim(), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
                    const SizedBox(height: 3),
                    Text('اضغط على الصورة لتغييرها', style: Theme.of(context).textTheme.bodySmall),
                    if (selectedPhotoPath.isNotEmpty)
                      TextButton.icon(onPressed: () => setDialogState(() => selectedPhotoPath = ''), icon: const Icon(Icons.delete_outline), label: const Text('إزالة الصورة')),
                  ]),
                ),
                TextField(
                  controller: nameController,
                  maxLength: 40,
                  decoration: const InputDecoration(
                    labelText: 'اسم المستخدم',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: selectedBackground,
                  decoration: const InputDecoration(
                    labelText: 'مظهر التطبيق',
                    prefixIcon: Icon(Icons.palette_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'افتراضي', child: Text('افتراضي')),
                    DropdownMenuItem(value: 'فاتح', child: Text('فاتح')),
                    DropdownMenuItem(value: 'داكن', child: Text('داكن')),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => selectedBackground = value);
                  },
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: selectedWallpaper,
                  decoration: const InputDecoration(
                    labelText: 'خلفية المحادثة',
                    prefixIcon: Icon(Icons.wallpaper_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'mint', child: Text('أخضر هادئ')),
                    DropdownMenuItem(value: 'cream', child: Text('كريمي')),
                    DropdownMenuItem(value: 'plain', child: Text('أبيض بسيط')),
                    DropdownMenuItem(value: 'night', child: Text('داكن')),
                  ],
                  onChanged: (value) { if (value != null) setDialogState(() => selectedWallpaper = value); },
                ),
                const SizedBox(height: 8),
                Card(
                  child: SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    secondary: const Icon(Icons.visibility_outlined),
                    title: const Text('مرئي للأجهزة التي حولك', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text('تشغيل الظهور التلقائي عبر Bluetooth والشبكة المحلية عند فتح بلوساب. قد يطلب Android موافقة إضافية.'),
                    value: selectedNearbyVisible,
                    onChanged: (value) => setDialogState(() => selectedNearbyVisible = value),
                  ),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  value: selectedMode,
                  decoration: const InputDecoration(
                    labelText: 'طريقة الاتصال الأساسية',
                    prefixIcon: Icon(Icons.compare_arrows),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'bluetooth', child: Text('Bluetooth Classic')),
                    DropdownMenuItem(value: 'wifi', child: Text('Wi-Fi عبر نقطة اتصال')),
                  ],
                  onChanged: (value) { if (value != null) setDialogState(() => selectedMode = value); },
                ),
                if (selectedMode == 'wifi')
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('شغّل نقطة الاتصال من إعدادات Android في الهاتف المنشئ، ثم صِل الهاتف الآخر بها. يجب أن يكون الهاتفان على الشبكة نفسها. لا يستطيع التطبيق تشغيل نقطة الاتصال تلقائيًا على كل الأجهزة.', style: TextStyle(fontSize: 12)),
                  ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Row(children: [Icon(Icons.chat_bubble_outline), SizedBox(width: 8), Text('تخصيص المحادثات', style: TextStyle(fontWeight: FontWeight.bold))]),
                      const SizedBox(height: 8),
                      Row(children: [const Expanded(child: Text('حجم نص الرسائل')), Text('${selectedFontSize.round()}')]),
                      Slider(value: selectedFontSize, min: 14, max: 22, divisions: 8, label: '${selectedFontSize.round()}', onChanged: (value) => setDialogState(() => selectedFontSize = value)),
                      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('إظهار وقت الرسالة'), subtitle: const Text('عرض وقت الإرسال أسفل كل رسالة'), value: selectedShowTime, onChanged: (value) => setDialogState(() => selectedShowTime = value)),
                      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('فقاعات مضغوطة'), subtitle: const Text('عرض رسائل أكثر على الشاشة'), value: selectedCompact, onChanged: (value) => setDialogState(() => selectedCompact = value)),
                      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('اهتزاز خفيف عند الإرسال'), subtitle: const Text('اهتزاز محلي عند إرسال الرسالة بنجاح'), value: selectedVibrate, onChanged: (value) => setDialogState(() => selectedVibrate = value)),
                    ]),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    secondary: const Icon(Icons.hub_outlined, color: Color(0xFF128C7E)),
                    title: const Text('استخدام وسيط', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text('السماح لهذا الهاتف بتمرير رسائل المجتمعات للأجهزة القريبة حتى دون قبول صداقة أو عضوية في المجتمع. يجب أن يكون بلوساب مفتوحًا وأن يكون الاتصال القريب متاحًا. لا تُرحّل المحادثات الخاصة. رسائل المجتمعات الجديدة مشفّرة بمفتاح المجتمع فلا يقرؤها الوسيط؛ أما المجتمعات القديمة غير المشفّرة فقد يرى الوسيط محتواها.'),
                    value: selectedRelayEnabled,
                    onChanged: (value) => setDialogState(() => selectedRelayEnabled = value),
                  ),
                ),
                const SizedBox(height: 8),
                Card(
                  child: SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    secondary: const Icon(Icons.bolt_outlined, color: Color(0xFF128C7E)),
                    title: const Text('العمل في الخلفية', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text('يُبقي بلوساب نشطًا بإشعار دائم عند الانتقال لتطبيق آخر، فلا يقتل أندرويد اتصالات البلوتوث والشبكة. يستهلك بطارية أكثر. إغلاق التطبيق بالسحب من قائمة التطبيقات يوقفه رغم ذلك.'),
                    value: selectedKeepAlive,
                    onChanged: (value) => setDialogState(() => selectedKeepAlive = value),
                  ),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: selectedLan,
                  title: const Text('استخدام الشبكة المحلية Wi-Fi'),
                  subtitle: const Text('لإرسال رسائل المجتمعات إلى الأجهزة على شبكة Wi-Fi نفسها.'),
                  onChanged: (value) { if (value != null) setDialogState(() => selectedLan = value); },
                ),
                const SizedBox(height: 8),
                const SizedBox(height: 8),
                Card(child: ListTile(leading: const Icon(Icons.lock_outline), title: const Text('قفل التطبيق'), subtitle: Text(_appLockEnabled ? 'القفل مفعّل — اضغط لإدارته' : 'حماية بلوساب برمز PIN'), trailing: const Icon(Icons.chevron_left), onTap: _manageAppLock)),
                const SizedBox(height: 8),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.verified_user_outlined),
                        title: const Text('صلاحيات بلوساب'),
                        subtitle: const Text('فحص صلاحيات الاتصال والأجهزة القريبة'),
                        trailing: const Icon(Icons.chevron_left),
                        onTap: _manageConnectivityPermissions,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.tune),
                        title: const Text('المزيد من الأذونات'),
                        subtitle: const Text('فتح صفحة أذونات بلوساب في إعدادات Android'),
                        trailing: const Icon(Icons.open_in_new),
                        onTap: () async {
                          try {
                            await openAppSettings();
                          } catch (_) {
                            if (mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('تعذر فتح إعدادات الأذونات. افتح إعدادات الهاتف ثم التطبيقات ثم بلوساب.')),
                              );
                            }
                          }
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.preview_outlined, color: Color(0xFF128C7E)),
                    title: const Text('محادثة وهمية تجريبية (للمطور)', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: const Text('معاينة واجهة المحادثة وتجربة شكل الرسائل دون اتصال'),
                    trailing: const Icon(Icons.chevron_left),
                    onTap: () {
                      Navigator.of(context).push(MaterialPageRoute<void>(
                        builder: (_) => const DeveloperChatPreviewScreen(),
                      ));
                    },
                  ),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF9800),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: ListTile(
                      leading: const Icon(Icons.support_agent, color: Colors.blue, size: 30),
                      title: const Text('التواصل مع المطور', style: TextStyle(color: Colors.blue, fontWeight: FontWeight.bold)),
                      subtitle: const Text('للاقتراحات والمساعدة', style: TextStyle(color: Colors.blue)),
                      trailing: const Icon(Icons.open_in_new, color: Colors.blue),
                      onTap: _openSupport,
                    ),
                  ),
                ),
                const SizedBox(height: 8),

                const Text(
                  'تُحفظ هذه الإعدادات على هذا الهاتف. لا تُزامَن تلقائيًا مع الأجهزة الأخرى.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            Row(children: [
              Expanded(child: OutlinedButton.icon(
                onPressed: () => Navigator.pop(dialogContext),
                icon: const Icon(Icons.close),
                label: const Text('إلغاء'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              )),
              const SizedBox(width: 12),
              Expanded(child: FilledButton.icon(
                onPressed: () => Navigator.pop(dialogContext, {
                  'name': nameController.text.trim(),
                  'background': selectedBackground,
                  'wallpaper': selectedWallpaper,
                  'photoPath': selectedPhotoPath,
                  'photoWasPicked': photoWasPicked,
                  'lanEnabled': selectedLan,
                  'relayEnabled': selectedRelayEnabled,
                  'keepAlive': selectedKeepAlive,
                  'nearbyVisible': selectedNearbyVisible,
                  'connectionMode': selectedMode,
                  'messageFontSize': selectedFontSize,
                  'showMessageTime': selectedShowTime,
                  'vibrateOnSend': selectedVibrate,
                  'compactBubbles': selectedCompact,
                }),
                icon: const Icon(Icons.save_outlined),
                label: const Text('حفظ التغييرات'),
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              )),
            ]),
          ],
          ),
        ),
        ),
      ),
    );
    nameController.dispose();
    if (result == null) return;
    final enteredName = (result['name'] as String? ?? '').trim();
    final cleanName = enteredName.isEmpty ? 'مستخدم بلوساب' : enteredName;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wasl_user_name', cleanName);
    await prefs.setString('wasl_background', result['background'] as String);
    await prefs.setString('wasl_chat_wallpaper', result['wallpaper'] as String? ?? 'mint');
    final photoPath = result['photoPath'] as String? ?? '';
    if (photoPath.isEmpty) { await prefs.remove('wasl_profile_photo'); } else { await prefs.setString('wasl_profile_photo', photoPath); }
    final lanEnabled = result['lanEnabled'] as bool? ?? true;
    final nearbyVisible = result['nearbyVisible'] as bool? ?? true;
    await prefs.setBool('blousab_lan_enabled', lanEnabled);
    final relayEnabled = result['relayEnabled'] as bool? ?? false;
    await prefs.setBool('blousab_use_relay', relayEnabled);
    await BackgroundService.instance.setEnabled(result['keepAlive'] as bool? ?? false);
    _meshRelayEnabled = relayEnabled;
    MeshRelayService.instance.strangersEnabled = relayEnabled;
    await prefs.setBool('blousab_nearby_visible', nearbyVisible);
    final connectionMode = result['connectionMode'] as String? ?? 'bluetooth';
    await prefs.setString('blousab_connection_mode', connectionMode);
    final messageFontSize = (result['messageFontSize'] as double? ?? 16).clamp(14, 22).toDouble();
    final showMessageTime = result['showMessageTime'] as bool? ?? true;
    final vibrateOnSend = result['vibrateOnSend'] as bool? ?? true;
    final compactBubbles = result['compactBubbles'] as bool? ?? false;
    await prefs.setDouble('blousab_message_font_size', messageFontSize);
    await prefs.setBool('blousab_show_message_time', showMessageTime);
    await prefs.setBool('blousab_vibrate_on_send', vibrateOnSend);
    await prefs.setBool('blousab_compact_bubbles', compactBubbles);
    final userId = prefs.getString('wasl_user_id') ?? 'blousab-user';
    if (nearbyVisible && (lanEnabled || connectionMode == 'wifi')) {
      try {
        await LocalNetworkService.instance.start(userId: userId, userName: cleanName);
      } catch (_) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('تعذر تشغيل الشبكة المحلية. تحقق من اتصال Wi-Fi.')));
      }
    } else {
      await LocalNetworkService.instance.stop();
    }
    if (!nearbyVisible) {
      try { await BluetoothClassicService.instance.stopServer(); } catch (_) {}
    } else {
      await _startNearbyVisibility();
    }
    final oldPhotoPath = _profilePhotoPath;
    if ((result['photoWasPicked'] as bool? ?? false) || oldPhotoPath != photoPath || _userName != cleanName) {
      await _announceProfileUpdate(userId: userId, userName: cleanName);
    }
    if (!mounted) return;
    setState(() {
      _userName = cleanName;
      _background = result['background'] as String;
      _chatWallpaper = result['wallpaper'] as String? ?? 'mint';
      _profilePhotoPath = photoPath;
      _lanEnabled = lanEnabled;
      _nearbyVisible = nearbyVisible;
      _connectionMode = connectionMode;
      _messageFontSize = messageFontSize;
      _showMessageTime = showMessageTime;
      _vibrateOnSend = vibrateOnSend;
      _compactBubbles = compactBubbles;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(!nearbyVisible ? 'تم حفظ الإعدادات وإيقاف الظهور للأجهزة القريبة.' : (connectionMode == 'wifi' ? 'تم حفظ الإعدادات. تأكد من اتصال الهاتفين بالشبكة نفسها.' : 'تم حفظ الإعدادات على هذا الهاتف.'))));
  }

  Future<void> _openSupport() async {
    // Try the WhatsApp app first, then its official HTTPS deep link.
    final targets = <Uri>[
      Uri.parse('whatsapp://send?phone=967737414884'),
      Uri.parse('https://wa.me/967737414884'),
      Uri.parse('https://api.whatsapp.com/send?phone=967737414884'),
      Uri.parse(supportUrl),
    ];
    for (final uri in targets) {
      try {
        final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (opened) return;
      } catch (_) {
        // Continue to the next compatible WhatsApp link.
      }
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('تعذر فتح واتساب. ثبّت التطبيق أو تأكد من اتصال الإنترنت.')),
      );
    }
  }

  Widget _buildProfileTab() {
    final photo = _profilePhotoPath;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const SizedBox(height: 24),
        Center(
          child: CircleAvatar(
            radius: 48,
            backgroundImage: photo.isNotEmpty && File(photo).existsSync() ? FileImage(File(photo)) : null,
            child: photo.isEmpty || !File(photo).existsSync() ? const Icon(Icons.person, size: 48) : null,
          ),
        ),
        const SizedBox(height: 12),
        Center(child: Text(_userName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
        const SizedBox(height: 24),
        Card(
          child: ListTile(
            leading: const Icon(Icons.settings_outlined),
            title: const Text('الإعدادات'),
            subtitle: const Text('الحساب والمظهر والخصوصية والاتصال'),
            trailing: const Icon(Icons.chevron_left),
            onTap: _openSettings,
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.edit_outlined),
            title: const Text('تعديل الملف الشخصي'),
            subtitle: const Text('تغيير الاسم والصورة من الإعدادات'),
            trailing: const Icon(Icons.chevron_left),
            onTap: _openSettings,
          ),
        ),
      ],
    );
  }

  Future<void> _handleConnectionTap() async {
    if (_connectionMode == 'wifi') {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('الاتصال عبر Wi-Fi'),
          content: const Text('تأكد من اتصال الهاتفين بالشبكة المحلية نفسها، ثم افتح البحث عن مستخدمين أو مجتمع.'),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('حسنًا'))],
        ),
      );
      return;
    }
    final service = BluetoothClassicService.instance;
    try {
      final enabled = await service.isEnabled();
      if (!enabled) {
        await service.requestEnable();
      } else {
        await service.startServer();
        await service.requestDiscoverable();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('بدأ استقبال البلوتوث. وافق على جعل الهاتف مرئيًا للأجهزة القريبة لمدة 5 دقائق للانضمام الأول.')),
          );
        }
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('تعذر تشغيل استقبال البلوتوث: $e')));
    }
  }

  Future<void> _openNotifications() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [Icon(Icons.notifications_active_outlined), SizedBox(width: 8), Text('الإشعارات')]),
        content: const Text('ستظهر إشعارات الرسائل الواردة عبر بلوساب في إشعارات الهاتف. إذا لم تظهر، تحقق من سماح Android بإشعارات التطبيق.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إغلاق'))],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_appLocked && _appLockEnabled) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.lock_outline, size: 72),
                    const SizedBox(height: 18),
                    const Text(
                      'بلوساب مقفل',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    const Text('أدخل رمز القفل للمتابعة', textAlign: TextAlign.center),
                    const SizedBox(height: 18),
                    FilledButton.icon(
                      onPressed: _unlockApp,
                      icon: const Icon(Icons.lock_open),
                      label: const Text('فتح التطبيق'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    }
    final brightness = _background == 'فاتح' ? Brightness.light : Brightness.dark;
    return Theme(
      data: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF128C7E),
          brightness: brightness,
        ),
        useMaterial3: true,
        fontFamily: 'sans-serif',
      ),
      child: Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Material(
              color: Theme.of(context).colorScheme.surface,
              elevation: 1,
              child: SizedBox(
                height: 54,
                child: Row(
                  children: [
                    const SizedBox(width: 14),
                    const Icon(Icons.forum_rounded, color: Color(0xFF128C7E), size: 25),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('بلوساب', style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold))),
                    IconButton(
                      tooltip: _connectionMode == 'wifi' ? 'الاتصال عبر Wi-Fi' : 'الاتصال عبر Bluetooth',
                      onPressed: _handleConnectionTap,
                      icon: Icon(_connectionMode == 'wifi' ? Icons.wifi : Icons.bluetooth_searching, color: const Color(0xFF128C7E)),
                    ),
                    IconButton(
                      tooltip: 'الإشعارات',
                      onPressed: _openNotifications,
                      icon: const Icon(Icons.notifications_none_rounded, color: Color(0xFF3687D9)),
                    ),
                    const SizedBox(width: 4),
                  ],
                ),
              ),
            ),
            Expanded(
              child: IndexedStack(
                index: _homeTabIndex,
                children: [
                  const CommunitiesScreen(),
                  PublicFeedScreen(userName: _userName, profilePhotoPath: _profilePhotoPath),
                  Center(
                    child: SingleChildScrollView(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: StoriesStrip(userName: _userName, profilePhotoPath: _profilePhotoPath),
                      ),
                    ),
                  ),
                  _buildProfileTab(),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _homeTabIndex,
        onDestinationSelected: (index) => setState(() => _homeTabIndex = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: 'المحادثات'),
          NavigationDestination(icon: Icon(Icons.dynamic_feed_outlined), selectedIcon: Icon(Icons.dynamic_feed), label: 'المنشورات'),
          NavigationDestination(icon: Icon(Icons.auto_awesome_outlined), selectedIcon: Icon(Icons.auto_awesome), label: 'القصص'),
          NavigationDestination(icon: Icon(Icons.person_outline), selectedIcon: Icon(Icons.person), label: 'ملفي'),
        ],
      ),     ),
    );
  }
}