import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial_plus/flutter_bluetooth_serial_plus.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

// アプリ全体で使用する基本色
const Color monitaGreen = Color(0xFF2F8A55);

// Raspberry Pi 3との通信先
const String piWebSocketUrl =
    'ws://raspberrypi.local:50007'; // Bluetooth未接続時の予備接続先
const String piBluetoothAddress = 'B8:27:EB:E8:32:44';
const String returnServerUrl = 'http://raspberrypi.local:8081';

// モニ太の基本情報
const String defaultMonitorId = 'TUIS-MONI-001';

const RentalSpot defaultRentalSpot = RentalSpot(
  code: 'TUIS-001',
  facilityName: '東京情報大学',
  spotName: '貸出場所001',
);

// 通知機能
final FlutterLocalNotificationsPlugin localNotifications =
    FlutterLocalNotificationsPlugin();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ローカル通知はFirebaseの初期化結果に関係なく使用できるようにする。
  try {
    await initializeNotifications();
  } catch (e) {
    debugPrint('ローカル通知の初期化エラー: $e');
  }

  try {
    await Firebase.initializeApp();
    await FirebaseMessaging.instance.requestPermission();
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final title = message.notification?.title ?? 'モニ太';
      final body = message.notification?.body ?? '荷物の異常を検知しました';
      unawaited(showAlertNotification(title, body));
    });
  } catch (e) {
    debugPrint('Firebase通知の初期化エラー: $e');
  }

  runApp(const RentalMonitaApp());
}

/// Androidのローカル通知を初期化して、通知権限を確認する。
Future<void> initializeNotifications() async {
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  const settings = InitializationSettings(android: androidSettings);
  await localNotifications.initialize(settings);

  final android = localNotifications.resolvePlatformSpecificImplementation<
      AndroidFlutterLocalNotificationsPlugin>();
  try {
    final granted = await android?.requestNotificationsPermission();
    debugPrint('モニ太の通知権限: $granted');
  } catch (e) {
    debugPrint('モニ太の通知権限確認エラー: $e');
  }
  debugPrint('モニ太のローカル通知初期化完了');
}

/// Androidの通知欄に異常通知を表示する。
Future<void> showAlertNotification(String title, String body) async {
  // 以前の通知ID=1のスヌーズ記録と区別するため、新しい通知チャンネルを使う。
  const androidDetails = AndroidNotificationDetails(
    'monita_alert_channel_v2',
    'モニ太の異常通知',
    channelDescription: '荷物の異常を知らせる通知',
    importance: Importance.max,
    priority: Priority.high,

    // 通知バーに表示する白一色のアイコン
    icon: 'ic_monita_notification',

    // 通知を展開したときに表示するカラーアイコン
    largeIcon: DrawableResourceAndroidBitmap(
      'monita_notification_large',
    ),
  );

  const details = NotificationDetails(android: androidDetails);
  final notificationId =
      DateTime.now().microsecondsSinceEpoch.remainder(2147483647);

  try {
    await localNotifications.show(notificationId, title, body, details);
    debugPrint('通知発行成功 ID: $notificationId / $body');
  } catch (e) {
    debugPrint('通知発行失敗 ID: $notificationId / $e');
  }
}

/// アプリ全体のテーマを設定する
class RentalMonitaApp extends StatelessWidget {
  const RentalMonitaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'レンタルモニ太',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: monitaGreen),
        scaffoldBackgroundColor: const Color(0xFFF6F8F6),
        useMaterial3: true,
      ),
      home: const MonitaHomePage(),
    );
  }
}

/// 貸出場所の情報
class RentalSpot {
  final String code;
  final String facilityName;
  final String spotName;

  const RentalSpot({
    required this.code,
    required this.facilityName,
    required this.spotName,
  });
}

/// QRコードと貸出場所の対応表
const Map<String, RentalSpot> rentalSpots = {
  'TUIS-SPOT-001': defaultRentalSpot,
};

enum MonitorStatus { standby, monitoring, communicationError }

enum AppTab { home, settings, history }

class MonitaHomePage extends StatefulWidget {
  const MonitaHomePage({super.key});

  @override
  State<MonitaHomePage> createState() => _MonitaHomePageState();
}

class _MonitaHomePageState extends State<MonitaHomePage> {
  // Raspberry Pi 3とのWebSocket通信
  WebSocket? _piSocket;
  StreamSubscription<dynamic>? _piSubscription;
  Future<void>? _connecting;

  // Bluetooth Classic通信
  BluetoothConnection? _piBluetooth;
  StreamSubscription<Uint8List>? _bluetoothSubscription;
  String _bluetoothBuffer = '';

  // 接続確認タイマー
  Timer? _connectionRetryTimer;

  // 返却処理のタイマーと重複防止フラグ
  Timer? _returnResultTimer;
  bool _returnResultChecking = false;
  bool _returnDialogShowing = false;

  // 貸出処理の二重実行を防ぐ
  bool _isRentalProcessing = false;

  // 画面とモニ太の状態
  MonitorStatus _status = MonitorStatus.standby;
  AppTab _tab = AppTab.home;

  // 貸出・異常通知・Pi 3との同期状態
  bool _isBorrowed = false;
  bool _hasAlert = false;
  bool _warningAlreadyHandled = false;
  bool _piBorrowSynced = false;

  // 貸出場所・モニ太ID・貸出日時
  RentalSpot? _selectedSpot;
  String? _selectedMonitorId;
  DateTime? _borrowedAt;

  // センサーと通信状況
  String? _lastPiSensorStatus;
  String _connectionMessage = '未接続';
  // Bluetoothから受け取ったPiのIPアドレスを使用する（固定IP不要）。
  String? _discoveredPiIp;
  String? _activeWifiUrl;
  DateTime? _lastNetworkInfoRequest;
  bool _wifiVerified = false;
  bool _wifiConnecting = false;
  int _adminSequence = 0;
  int _commandSequence = 0;
  final String _commandSession =
      DateTime.now().microsecondsSinceEpoch.toString();
  final Map<String, Completer<String>> _pendingCommands = {};
  // 通信方式は端末内に保存する。Bluetoothを選んだ場合はWi-Fiを使わない。
  String _preferredConnection = 'auto';
  bool _connectionCheckRunning = false;
  bool _stopCommandPending = false;
  final Map<int, Completer<Map<String, dynamic>>> _adminRequests = {};

  // アプリ内の操作履歴
  final List<String> _history = [];

  @override
  void initState() {
    super.initState();

    unawaited(_restoreConnectionPreference());
    unawaited(_restoreBorrowState());
    unawaited(_checkConnectionAndPreferWebSocket());

    _connectionRetryTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_checkConnectionAndPreferWebSocket()),
    );
  }

  Future<void> _restoreConnectionPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('monita_connection_preference') ?? 'auto';
    if (!mounted) return;
    setState(() {
      _preferredConnection =
          ['auto', 'bluetooth', 'wifi'].contains(value) ? value : 'auto';
    });
    unawaited(_checkConnectionAndPreferWebSocket());
  }

  Future<void> _setConnectionPreference(String value) async {
    if (!['auto', 'bluetooth', 'wifi'].contains(value)) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('monita_connection_preference', value);
    if (!mounted) return;
    setState(() => _preferredConnection = value);
    // Bluetoothを手動選択したときはWi-Fiを切断し、送信経路を固定する。
    if (value == 'bluetooth') {
      _wifiVerified = false;
      final socket = _piSocket;
      _piSocket = null;
      _activeWifiUrl = null;
      await _piSubscription?.cancel();
      _piSubscription = null;
      await socket?.close();
    }
    await _checkConnectionAndPreferWebSocket();
  }

  String get _activeConnectionName {
    if (_preferredConnection != 'bluetooth' &&
        _wifiVerified &&
        _piSocket?.readyState == WebSocket.open) {
      return 'Wi-Fi';
    }
    if (_piBluetooth?.isConnected == true) return 'Bluetooth';
    return '未接続';
  }

  bool get _isConnected {
    final webSocketConnected =
        _piSocket != null && _piSocket!.readyState == WebSocket.open;
    final bluetoothConnected =
        _piBluetooth != null && _piBluetooth!.isConnected;

    return (webSocketConnected && _wifiVerified) || bluetoothConnected;
  }

  String get _statusLabel {
    switch (_status) {
      case MonitorStatus.standby:
        return _isBorrowed ? '待機中' : '未貸出';
      case MonitorStatus.monitoring:
        return '見守り中';
      case MonitorStatus.communicationError:
        return '通信エラー';
    }
  }

  void _addHistory(String message) {
    if (!mounted) return;

    setState(() {
      _history.insert(
        0,
        '${DateTime.now().toString().substring(0, 16)}  $message',
      );
    });
  }

  void _showMessage(String message) {
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 貸出状態をスマートフォン内に保存する
  Future<void> _saveBorrowState() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setBool('monita_is_borrowed', _isBorrowed);
    await prefs.setString('monita_spot_code', _selectedSpot?.code ?? '');
    await prefs.setString('monita_monitor_id', _selectedMonitorId ?? '');
    await prefs.setString(
      'monita_borrowed_at',
      _borrowedAt?.toIso8601String() ?? '',
    );
  }

  /// 保存済みの貸出状態を復元する
  Future<void> _restoreBorrowState() async {
    final prefs = await SharedPreferences.getInstance();
    final isBorrowed = prefs.getBool('monita_is_borrowed') ?? false;

    if (!mounted) return;

    if (!isBorrowed) {
      // 未貸出の場合は、前回の貸出情報を削除する
      await prefs.remove('monita_spot_code');
      await prefs.remove('monita_monitor_id');
      await prefs.remove('monita_borrowed_at');

      if (!mounted) return;

      setState(() {
        _selectedSpot = null;
        _selectedMonitorId = null;
        _borrowedAt = null;
        _isBorrowed = false;
        _status = MonitorStatus.standby;
        _hasAlert = false;
      });

      return;
    }

    final spotCode = prefs.getString('monita_spot_code') ?? '';
    final monitorId = prefs.getString('monita_monitor_id') ?? '';
    final borrowedAtText = prefs.getString('monita_borrowed_at') ?? '';

    RentalSpot? spot;

    for (final item in rentalSpots.values) {
      if (item.code == spotCode) {
        spot = item;
        break;
      }
    }

    setState(() {
      _isBorrowed = true;
      _selectedSpot = spot ?? defaultRentalSpot;
      _selectedMonitorId = monitorId.isNotEmpty ? monitorId : defaultMonitorId;
      _borrowedAt = DateTime.tryParse(borrowedAtText);
      _status = MonitorStatus.standby;
    });
  }

  // Android側にBluetooth権限を確認してもらう
  static const MethodChannel _bluetoothPermissionChannel = MethodChannel(
    'com.example.rental_monita/bluetooth_permissions',
  );

  Future<bool> _requestBluetoothPermissions() async {
    try {
      final granted = await _bluetoothPermissionChannel.invokeMethod<bool>(
        'requestBluetoothPermissions',
      );

      return granted ?? false;
    } catch (e) {
      debugPrint('Bluetooth権限の確認に失敗しました: $e');
      return false;
    }
  }

  // -------------------------------------------------------
  // Raspberry Pi 3との通信
  // -------------------------------------------------------

  /// 最初にBluetoothを試す。失敗してもWi-Fi通信を確認する。
  Future<void> _checkConnectionAndPreferWebSocket() async {
    if (!mounted || _connectionCheckRunning) return;
    _connectionCheckRunning = true;
    try {
      // Bluetoothを先に確認する。Wi-Fiは通信確認後に優先する。
      if (_piBluetooth?.isConnected != true) await _connectToPi();
      // Bluetoothがつながっていれば、IPアドレスの変更を定期的に問い合わせる。
      await _requestPiNetworkInfo();
      if (_preferredConnection != 'bluetooth' &&
          (_discoveredPiIp != null || _piBluetooth?.isConnected != true) &&
          (_piSocket?.readyState != WebSocket.open || !_wifiVerified)) {
        await _tryWifiConnection();
      }
    } finally {
      _connectionCheckRunning = false;
    }
  }

  Future<void> _tryWifiConnection() async {
    if (!mounted || _wifiConnecting || _preferredConnection == 'bluetooth')
      return;
    if (_wifiVerified && _piSocket?.readyState == WebSocket.open) return;
    _wifiConnecting = true;
    WebSocket? socket;
    try {
      // Bluetoothから取得したIPを優先し、未取得時だけ.localを試す。
      final url = _discoveredPiIp == null
          ? piWebSocketUrl
          : 'ws://$_discoveredPiIp:50007';
      socket = await WebSocket.connect(url).timeout(const Duration(seconds: 4));
      final connectedSocket = socket;
      final confirmed = Completer<bool>();
      final subscription = connectedSocket.listen(
        (dynamic data) {
          final message = data.toString();
          if (message.startsWith('STATE,') && !confirmed.isCompleted) {
            confirmed.complete(true);
          }
          _handlePiMessage(data);
        },
        onError: (Object error) {
          if (!confirmed.isCompleted) confirmed.complete(false);
          _handlePiDisconnect(connectedSocket);
        },
        onDone: () {
          if (!confirmed.isCompleted) confirmed.complete(false);
          _handlePiDisconnect(connectedSocket);
        },
        cancelOnError: true,
      );
      connectedSocket.add('status');
      final success = await confirmed.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () => false,
      );
      if (!success || !mounted || _preferredConnection == 'bluetooth') {
        await subscription.cancel();
        await connectedSocket.close();
        return;
      }
      await _piSubscription?.cancel();
      _piSocket = connectedSocket;
      _activeWifiUrl = url;
      _piSubscription = subscription;
      _wifiVerified = true;
      if (mounted)
        setState(
          () => _connectionMessage = _piBluetooth?.isConnected == true
              ? 'Wi-Fi接続中（Bluetooth維持）'
              : 'Wi-Fi接続中',
        );
      _addHistory('Wi-Fi通信を確認しました');
    } catch (error) {
      debugPrint('Wi-Fi接続確認失敗: $error');
      if (socket != null && !identical(_piSocket, socket)) {
        try {
          await socket.close();
        } catch (_) {}
      }
      if (mounted)
        setState(
          () => _connectionMessage =
              _piBluetooth?.isConnected == true ? 'Bluetooth接続中' : '未接続',
        );
    } finally {
      _wifiConnecting = false;
    }
  }

  /// Bluetoothを最初に試す。Wi-Fi確認は呼び出し元で必ず続ける。
  Future<void> _connectToPi() async {
    if (_piBluetooth?.isConnected == true) return;
    if (_connecting != null) {
      await _connecting;
      return;
    }
    final future = _openPiConnection();
    _connecting = future;
    try {
      await future;
    } finally {
      _connecting = null;
    }
  }

  Future<void> _openPiConnection() async {
    try {
      final permitted = await _requestBluetoothPermissions();
      if (!permitted) throw StateError('Bluetoothの権限が必要です');
      final connection = await BluetoothConnection.toAddress(piBluetoothAddress)
          .timeout(const Duration(seconds: 7));
      if (!mounted) {
        await connection.close();
        return;
      }
      _piBluetooth = connection;
      _bluetoothBuffer = '';
      await _bluetoothSubscription?.cancel();
      _bluetoothSubscription = connection.input.listen(
        (Uint8List data) {
          _bluetoothBuffer += utf8.decode(data, allowMalformed: true);
          while (_bluetoothBuffer.contains('\n')) {
            final index = _bluetoothBuffer.indexOf('\n');
            final message = _bluetoothBuffer.substring(0, index).trim();
            _bluetoothBuffer = _bluetoothBuffer.substring(index + 1);
            if (message.isNotEmpty) _handlePiMessage(message);
          }
        },
        onError: (Object error) => _handleBluetoothDisconnect(connection),
        onDone: () => _handleBluetoothDisconnect(connection),
        cancelOnError: true,
      );
      if (mounted) setState(() => _connectionMessage = 'Bluetooth接続中');
      _addHistory('Bluetoothで接続しました');
      await _sendBluetoothCommand('status');
      await _requestPiNetworkInfo(force: true);
    } catch (error) {
      debugPrint('Bluetooth接続失敗: $error');
      if (mounted && !_wifiVerified)
        setState(() => _connectionMessage = 'Bluetooth接続エラー');
    }
  }

  /// BluetoothでPiの現在のIPv4アドレスを取得する。
  /// Wi-Fiがない場合もBluetooth接続自体は維持する。
  Future<void> _requestPiNetworkInfo({bool force = false}) async {
    if (_piBluetooth?.isConnected != true) return;
    final now = DateTime.now();
    if (!force &&
        _lastNetworkInfoRequest != null &&
        now.difference(_lastNetworkInfoRequest!) <
            const Duration(seconds: 10)) {
      return;
    }
    _lastNetworkInfoRequest = now;
    try {
      await _sendBluetoothCommand('NETINFO');
    } catch (error) {
      debugPrint('IPアドレス問い合わせ失敗: $error');
    }
  }

  /// PiのWi-Fiアドレス変更を反映し、古いWebSocketを切断する。
  void _updatePiNetworkInfo(String message) {
    try {
      final data = jsonDecode(message.substring('NETINFO:'.length));
      if (data is! Map<String, dynamic>) return;
      final addresses = (data['ipv4'] as List<dynamic>? ?? [])
          .whereType<String>()
          .where(
            (ip) =>
                InternetAddress.tryParse(ip)?.type == InternetAddressType.IPv4,
          )
          .toList();
      final newIp = addresses.isEmpty ? null : addresses.first;
      if (_discoveredPiIp == newIp) return;
      _discoveredPiIp = newIp;
      debugPrint('BluetoothでPiのIPを取得: ${newIp ?? 'Wi-Fi未接続'}');
      if (mounted) setState(() {});
      // 接続先が変わった場合は旧接続を破棄し、新しいIPを試す。
      final nextUrl = newIp == null ? null : 'ws://$newIp:50007';
      if (_activeWifiUrl != null && _activeWifiUrl != nextUrl) {
        final oldSocket = _piSocket;
        _piSocket = null;
        _piSubscription?.cancel();
        _piSubscription = null;
        _activeWifiUrl = null;
        _wifiVerified = false;
        oldSocket?.close();
      }
      if (newIp != null && mounted) unawaited(_tryWifiConnection());
    } catch (error) {
      debugPrint('IPアドレス応答の解析失敗: $error');
    }
  }

  Future<void> _sendBluetoothCommand(String command) async {
    final connection = _piBluetooth;
    if (connection == null || !connection.isConnected) {
      throw StateError('Bluetoothが接続されていません');
    }
    connection.output.add(Uint8List.fromList(utf8.encode('$command\n')));
    await connection.output.allSent;
  }

  /// 管理要求はBluetoothで送り、要求番号に対応する応答を待つ。
  Future<Map<String, dynamic>> _adminCommand(
    String action, [
    Map<String, dynamic> arguments = const {},
  ]) async {
    final id = ++_adminSequence;
    final completer = Completer<Map<String, dynamic>>();
    _adminRequests[id] = completer;
    try {
      await _sendBluetoothCommand(
        'ADMIN:${jsonEncode({'id': id, 'action': action, ...arguments})}',
      );
      final result = await completer.future.timeout(
        const Duration(seconds: 42),
      );
      if (result['ok'] != true) {
        throw StateError(result['message']?.toString() ?? '管理操作に失敗しました');
      }
      return result;
    } finally {
      _adminRequests.remove(id);
    }
  }

  void _handleBluetoothDisconnect(BluetoothConnection connection) {
    if (!identical(_piBluetooth, connection)) return;

    _piBluetooth = null;
    _lastNetworkInfoRequest = null;
    _bluetoothBuffer = '';
    _piBorrowSynced = false;
    _connectionMessage = _wifiVerified ? 'Wi-Fi接続中' : 'Bluetooth切断・再接続待ち';

    if (mounted) {
      setState(() {
        if (!_isConnected && _status == MonitorStatus.monitoring) {
          _status = MonitorStatus.communicationError;
        }
      });
    }

    _addHistory('Raspberry Pi 3とのBluetooth接続が切れました');
  }

  /// Pi 3から届いた状態やセンサー情報を処理する
  void _handlePiMessage(dynamic data) {
    if (!mounted) return;

    final message = data.toString().trim();
    if (message.startsWith('NETINFO:')) {
      _updatePiNetworkInfo(message);
      return;
    }
    if (message.startsWith('ACK:')) {
      final parts = message.split(':');
      if (parts.length >= 3) {
        final request = _pendingCommands[parts[1]];
        if (request != null && !request.isCompleted) {
          request.complete(parts.sublist(2).join(':'));
        }
      }
      return;
    }
    if (message.startsWith('ADMIN_RESULT:')) {
      try {
        final result =
            jsonDecode(message.substring(13)) as Map<String, dynamic>;
        final id = result['id'];
        if (id is int) {
          final request = _adminRequests[id];
          if (request != null && !request.isCompleted) request.complete(result);
        }
      } catch (error) {
        debugPrint('管理応答の解析失敗: $error');
      }
      return;
    }
    final parts = message.split(',');

    if (parts.isEmpty) return;

    if (parts[0] == 'RETURNED') {
      unawaited(_handleReturned());
      return;
    }

    if (parts[0] == 'STATE' && parts.length >= 4) {
      final monitoring = parts[2] == '1';
      final warning = parts[3] == '1';

      // STATEがWarningより先に届いた場合も、最初の異常だけ通知する。
      final shouldNotify = warning &&
          monitoring &&
          !_stopCommandPending &&
          !_warningAlreadyHandled;

      setState(() {
        // 貸出状態はアプリ側で管理し、STATE受信では変更しない
        // 停止命令中に到着した古い状態で警告画面を戻さない
        if (!_stopCommandPending) {
          _status =
              monitoring ? MonitorStatus.monitoring : MonitorStatus.standby;
        }

        if (warning && monitoring && !_stopCommandPending) {
          _hasAlert = true;
          _warningAlreadyHandled = true;
          _lastPiSensorStatus = 'Warning';
        } else {
          _lastPiSensorStatus = 'Safe';

          if (!_hasAlert) {
            _warningAlreadyHandled = false;
          }
        }

        _connectionMessage = '接続中';
      });

      _piBorrowSynced = parts[1] == '1';

      if (shouldNotify) {
        _addHistory('荷物の異常を検知しました');
        _showMessage('荷物の異常を検知しました');
        unawaited(showAlertNotification('モニ太', '荷物の異常を検知しました'));
      }
      return;
    }

    final sensorStatus = parts[0];

    if (sensorStatus == 'Warning') {
      // 停止後に遅れて届いた警告では異常検知画面を再表示しない
      if (_status != MonitorStatus.monitoring) return;
      if (!_warningAlreadyHandled) {
        _warningAlreadyHandled = true;

        setState(() {
          _hasAlert = true;
          _lastPiSensorStatus = 'Warning';
        });

        _addHistory('荷物の異常を検知しました');
        _showMessage('荷物の異常を検知しました');

        unawaited(showAlertNotification('モニ太', '荷物の異常を検知しました'));
      } else {
        setState(() {
          _hasAlert = true;
          _lastPiSensorStatus = 'Warning';
        });
      }
    } else if (sensorStatus == 'Safe') {
      setState(() {
        _lastPiSensorStatus = 'Safe';

        if (!_hasAlert) {
          _warningAlreadyHandled = false;
        }
      });
    }
  }

  void _handlePiDisconnect(WebSocket socket) {
    if (!identical(_piSocket, socket)) return;

    _piSocket = null;
    _activeWifiUrl = null;
    _wifiVerified = false;
    _piBorrowSynced = false;
    _connectionMessage =
        _piBluetooth?.isConnected == true ? 'Bluetooth接続中' : '通信切断・再接続待ち';

    if (mounted) {
      setState(() {
        if (!_isConnected && _status == MonitorStatus.monitoring) {
          _status = MonitorStatus.communicationError;
        }
      });
    }

    _addHistory('Raspberry Pi 3とのWebSocket接続が切れました');

    if (mounted) {
      unawaited(_checkConnectionAndPreferWebSocket());
    }
  }

  /// 命令を1つの経路で送り、Pi側の実行応答を確認する。
  /// 応答が不明な場合は別経路に再送せず、重複操作を防ぐ。
  Future<void> _sendPiCommand(String command) async {
    final id = '$_commandSession-${++_commandSequence}';
    final request = Completer<String>();
    _pendingCommands[id] = request;
    final payload = 'CMD:$id:$command';
    try {
      if (_preferredConnection != 'bluetooth' &&
          _wifiVerified &&
          _piSocket?.readyState == WebSocket.open) {
        _piSocket!.add(payload);
        debugPrint('Wi-Fiで送信: $command');
      } else if (_piBluetooth?.isConnected == true) {
        await _sendBluetoothCommand(payload);
        debugPrint('Bluetoothで送信: $command');
      } else {
        throw StateError('Raspberry Pi 3に接続されていません');
      }
      final result = await request.future.timeout(const Duration(seconds: 8));
      if (result != 'OK')
        throw StateError(
          result.startsWith('ERROR:')
              ? result.substring(6)
              : '命令を実行できませんでした: $result',
        );
    } on TimeoutException {
      throw StateError('命令の実行結果を確認できません。状態を再確認してください');
    } finally {
      _pendingCommands.remove(id);
    }
  }

  Future<void> _ensurePiReady({bool sendBorrow = false}) async {
    await _checkConnectionAndPreferWebSocket();

    if (sendBorrow) {
      await _sendPiCommand('borrow');
      _piBorrowSynced = true;
    } else {
      await _sendPiCommand('status');
    }
  }

  // -------------------------------------------------------
  // 返却処理
  // -------------------------------------------------------

  Future<void> _clearSavedBorrowState() async {
    final prefs = await SharedPreferences.getInstance();

    await prefs.setBool('monita_is_borrowed', false);
    await prefs.remove('monita_spot_code');
    await prefs.remove('monita_monitor_id');
    await prefs.remove('monita_borrowed_at');
  }

  Future<void> _resetAfterReturn() async {
    await _clearSavedBorrowState();

    if (!mounted) return;

    setState(() {
      _isBorrowed = false;
      _selectedSpot = null;
      _selectedMonitorId = null;
      _borrowedAt = null;
      _status = MonitorStatus.standby;
      _hasAlert = false;
      _warningAlreadyHandled = false;
      _piBorrowSynced = false;
      _lastPiSensorStatus = null;
      _tab = AppTab.home;
    });

    _addHistory('モニ太の返却が完了しました');
  }

  Future<void> _handleReturned() async {
    if (_returnDialogShowing) return;

    _returnDialogShowing = true;

    try {
      await _resetAfterReturn();

      if (!mounted) return;

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          title: const Text('返却完了'),
          content: const Text('ありがとうございました'),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('返却状態の更新に失敗しました: $e');
    } finally {
      _returnDialogShowing = false;
    }
  }

  /// ユーザーアプリから直接Pi 3へ返却命令を送る
  Future<void> _startReturnProcess() async {
    if (!_isBorrowed) {
      _showMessage('モニ太を借りてから操作してください');
      return;
    }

    if (_returnDialogShowing) {
      return;
    }

    try {
      // Pi 3に接続し、返却命令を送信する
      await _ensurePiReady();
      await _sendPiCommand('return');

      _addHistory('返却命令を送信しました');
      _showMessage('返却処理を行っています');
    } catch (e) {
      debugPrint('返却命令の送信に失敗しました: $e');
      _addHistory('返却命令の送信に失敗しました');
      _showMessage('Pi 3に接続できません。接続を確認してください。');
    }
  }

  /// 返却サーバーから返却結果を取得する
  Future<void> _checkReturnResult() async {
    if (!mounted || _returnResultChecking || _returnDialogShowing) return;

    _returnResultChecking = true;

    try {
      final response = await http
          .get(Uri.parse('$returnServerUrl/api/return/session'))
          .timeout(const Duration(seconds: 3));

      if (response.statusCode != 200) return;

      final dynamic data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) return;

      final status = data['status'];

      if (status == 'success') {
        _returnResultTimer?.cancel();
        _returnResultTimer = null;
        _returnDialogShowing = true;

        try {
          await _resetAfterReturn();

          if (!mounted) return;

          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => AlertDialog(
              title: const Text('返却完了'),
              content: const Text('ありがとうございました'),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('OK'),
                ),
              ],
            ),
          );

          await _acknowledgeReturnResult();
        } finally {
          _returnDialogShowing = false;
        }
      } else if (status == 'failed') {
        _returnResultTimer?.cancel();
        _returnResultTimer = null;
        _returnDialogShowing = true;

        try {
          if (!mounted) return;

          await showDialog<void>(
            context: context,
            barrierDismissible: false,
            builder: (dialogContext) => AlertDialog(
              title: const Text('返却を確認できません'),
              content: const Text('モニ太の位置をなおして下さい'),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('OK'),
                ),
              ],
            ),
          );

          await _acknowledgeReturnResult();
        } finally {
          _returnDialogShowing = false;
        }
      }
    } catch (e) {
      debugPrint('返却結果の確認に失敗しました: $e');
    } finally {
      _returnResultChecking = false;
    }
  }

  Future<void> _acknowledgeReturnResult() async {
    try {
      await http
          .post(Uri.parse('$returnServerUrl/api/return/ack'))
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      debugPrint('返却結果の確認通知に失敗しました: $e');
    }
  }

  // -------------------------------------------------------
  // 貸出QRコードと貸出確定
  // -------------------------------------------------------

  /// QRコードを読み取り、登録された貸出場所を確認する
  Future<void> _scanSpotQrCode() async {
    if (_isBorrowed) {
      _showMessage('すでにモニ太を借りています。先に返却してください。');
      return;
    }

    if (_isRentalProcessing) {
      _showMessage('貸出処理中です。しばらくお待ちください。');
      return;
    }

    setState(() {
      _isRentalProcessing = true;
    });

    try {
      final result = await Navigator.push<String>(
        context,
        MaterialPageRoute(builder: (_) => const SpotQrScannerPage()),
      );

      if (!mounted || result == null) return;

      final qrValue = result.trim();
      RentalSpot? spot;

      // QRコードの登録キーと貸出場所コードの両方に対応する
      for (final entry in rentalSpots.entries) {
        if (entry.key == qrValue || entry.value.code == qrValue) {
          spot = entry.value;
          break;
        }
      }

      if (spot == null) {
        _showMessage('登録されていない貸出場所です：$qrValue');
        return;
      }

      await _showRentalOptions(spot);
    } finally {
      if (mounted) {
        setState(() {
          _isRentalProcessing = false;
        });
      } else {
        _isRentalProcessing = false;
      }
    }
  }

  /// 貸出場所を確認し、貸出確定後に情報を保存する
  Future<void> _showRentalOptions(RentalSpot spot) async {
    if (_isBorrowed) {
      _showMessage('すでにモニ太を借りています。');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('貸出場所の確認'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('施設：${spot.facilityName}'),
            const SizedBox(height: 8),
            Text('貸出場所：${spot.spotName}'),
            const SizedBox(height: 8),
            const SizedBox(height: 16),
            const Text('このモニ太を借りますか？'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('貸出確定'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;

    // 貸出確定直後にホーム画面へ詳細情報を反映する
    setState(() {
      _selectedSpot = spot;
      _selectedMonitorId = defaultMonitorId;
      _borrowedAt = DateTime.now();
      _isBorrowed = true;
      _status = MonitorStatus.standby;
      _hasAlert = false;
      _warningAlreadyHandled = false;
      _lastPiSensorStatus = null;
      _tab = AppTab.home;
    });

    // 貸出情報をスマートフォンに保存する
    await _saveBorrowState();

    if (!mounted) return;

    _addHistory('モニ太の貸出を確定しました');

    // Pi 3へ貸出命令を送信する
    try {
      await _ensurePiReady(sendBorrow: true);

      if (!mounted) return;

      _showMessage('貸出が完了しました');
      _addHistory('Pi 3へ貸出命令を送信しました');
    } catch (e) {
      if (!mounted) return;

      _showMessage('貸出情報は保存しましたが、Pi 3に接続できません。接続を確認してください。');
      _addHistory('Pi 3への貸出命令の送信に失敗しました');
      debugPrint('貸出命令の送信失敗: $e');
    }
  }

  // -------------------------------------------------------
  // 見守り開始・停止
  // -------------------------------------------------------

  Future<void> _startMonitoring() async {
    if (!_isBorrowed) {
      _showMessage('モニ太を借りてから操作してください');
      return;
    }

    try {
      await _ensurePiReady();
      await _sendPiCommand('start');

      if (!mounted) return;

      setState(() {
        _status = MonitorStatus.monitoring;
      });

      _addHistory('見守りを開始しました');
      _showMessage('見守りを開始しました');
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _status = MonitorStatus.communicationError;
      });

      _addHistory('見守り開始に失敗しました');
      _showMessage('Pi 3に接続できません。接続を確認してください。');
      debugPrint('見守り開始エラー: $e');
    }
  }

  Future<void> _confirmStopMonitoring() async {
    if (!_isBorrowed) {
      _showMessage('モニ太を借りてから操作してください');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('見守りを停止'),
        content: const Text('見守りを停止しますか？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('停止する'),
          ),
        ],
      ),
    );

    if (!mounted || confirmed != true) return;

    _stopCommandPending = true;
    try {
      await _ensurePiReady();
      await _sendPiCommand('stop');

      if (!mounted) return;

      setState(() {
        _status = MonitorStatus.standby;
        // 見守り停止時は異常検知表示も閉じる
        _hasAlert = false;
        _warningAlreadyHandled = false;
        _lastPiSensorStatus = 'Safe';
      });

      _addHistory('見守りを停止しました');
      _showMessage('見守りを停止しました');
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _status = MonitorStatus.communicationError;
      });

      _showMessage('Pi 3に接続できないため停止命令を送信できませんでした');
      _addHistory('見守り停止命令の送信に失敗しました');
      debugPrint('見守り停止エラー: $e');
    } finally {
      _stopCommandPending = false;
    }
  }

  /// Pi 3との接続を再確認する
  Future<void> _recheckConnection() async {
    try {
      await _checkConnectionAndPreferWebSocket();
      await _sendPiCommand('status');

      if (!mounted) return;

      setState(() {
        if (_status == MonitorStatus.communicationError && _isConnected) {
          _status = MonitorStatus.standby;
        }
      });

      _showMessage('Pi 3に接続しました');
    } catch (e) {
      if (!mounted) return;

      _showMessage('Pi 3に接続できませんでした');
      debugPrint('再接続エラー: $e');
    }
  }

  // -------------------------------------------------------
  // 異常通知・テスト
  // -------------------------------------------------------

  void _simulateAlert() {
    if (_hasAlert) return;

    _warningAlreadyHandled = true;

    setState(() {
      _hasAlert = true;
      _lastPiSensorStatus = 'Warning';
    });

    _addHistory('異常検知のテストを実行しました');
    _showMessage('異常検知をテストしました');

    unawaited(showAlertNotification('モニ太', '荷物の異常を検知しました'));
  }

  Future<void> _acknowledgeAlert() async {
    if (!_hasAlert) return;

    try {
      await _ensurePiReady();
      await _sendPiCommand('acknowledge');

      if (!mounted) return;

      setState(() {
        _hasAlert = false;
        _warningAlreadyHandled = false;
        _lastPiSensorStatus = 'Safe';
      });

      _addHistory('異常通知を確認しました');
      _showMessage('警告を解除しました。見守りを継続します');
    } catch (e) {
      if (!mounted) return;

      setState(() {
        _status = MonitorStatus.communicationError;
      });

      _showMessage('Pi 3に接続できないため、警告解除命令を送信できませんでした');
      _addHistory('警告解除命令の送信に失敗しました');
      debugPrint('警告解除命令の送信失敗: $e');
    }
  }

  void _simulateCommunicationError() {
    setState(() {
      _status = MonitorStatus.communicationError;
    });

    _addHistory('通信エラーのテストを実行しました');
  }

  /// モニ太の詳細をダイアログで表示する
  void _showMonitorDetails() {
    final monitorId =
        _isBorrowed ? (_selectedMonitorId ?? defaultMonitorId) : null;
    final spot = _selectedSpot;

    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('モニ太の詳細'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (monitorId != null) ...[
                Text('モニ太ID：$monitorId'),
                const SizedBox(height: 8),
              ],
              if (_isBorrowed && spot != null) ...[
                Text('施設：${spot.facilityName}'),
                const SizedBox(height: 8),
                Text('貸出場所：${spot.spotName}'),
                const SizedBox(height: 8),
              ],
              Text(
                '貸出日時：'
                '${_isBorrowed && _borrowedAt != null ? _borrowedAt!.toString().substring(0, 16) : '未貸出'}',
              ),
              const SizedBox(height: 8),
              Text('状態：$_statusLabel'),
              const SizedBox(height: 8),
              Text('モニ太：${_isConnected ? '接続中' : '未接続'}'),
              const SizedBox(height: 8),
              Text('センサー：${_lastPiSensorStatus ?? '未受信'}'),
              const SizedBox(height: 8),
              Text('貸出状況：${_isBorrowed ? '貸出中' : '未貸出'}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }
  // -------------------------------------------------------
  // 画面
  // -------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'レンタルモニ太',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: monitaGreen,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            onPressed: _showMonitorDetails,
            icon: const Icon(Icons.info_outline),
            tooltip: 'モニ太の詳細',
          ),
        ],
      ),
      body: SafeArea(child: _buildCurrentPage()),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab.index,
        onDestinationSelected: (index) {
          setState(() {
            _tab = AppTab.values[index];
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'ホーム',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '設定',
          ),
          NavigationDestination(
            icon: Icon(Icons.notifications_outlined),
            selectedIcon: Icon(Icons.notifications),
            label: '通知履歴',
          ),
        ],
      ),
    );
  }

  Widget _buildCurrentPage() {
    switch (_tab) {
      case AppTab.home:
        return _buildHome();
      case AppTab.settings:
        return _buildSettings();
      case AppTab.history:
        return _buildHistory();
    }
  }

  /// ホーム画面
  Widget _buildHome() {
    final isMonitoring = _status == MonitorStatus.monitoring;

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _buildDeviceHeader(),
        const SizedBox(height: 20),

        if (_hasAlert) ...[_buildAlertCard(), const SizedBox(height: 16)],

        Center(
          child: Column(
            children: [
              _buildStatusPill(),
              const SizedBox(height: 18),
              Icon(
                Icons.pets,
                size: 100,
                color: isMonitoring ? monitaGreen : Colors.grey,
              ),
              const SizedBox(height: 8),
              const Text(
                'モニ太',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Text(
                _isBorrowed ? '大切な荷物を見守ります' : '貸出QRコードを読み取ってください',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.black54),
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),

        // 貸出中は返却ボタンを表示する
        if (_isBorrowed) ...[
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: _startReturnProcess,
              icon: const Icon(Icons.assignment_return),
              label: const Text('返却'),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.orange.shade800,
                foregroundColor: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],

        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: !_isBorrowed
                ? null
                : isMonitoring
                    ? _confirmStopMonitoring
                    : _startMonitoring,
            icon: Icon(isMonitoring ? Icons.stop : Icons.play_arrow),
            label: Text(isMonitoring ? '見守り停止' : '見守り開始'),
            style: FilledButton.styleFrom(
              backgroundColor: isMonitoring ? Colors.redAccent : monitaGreen,
              foregroundColor: Colors.white,
            ),
          ),
        ),

        const SizedBox(height: 12),

        OutlinedButton.icon(
          onPressed: _recheckConnection,
          icon: const Icon(Icons.sync),
          label: const Text('Pi 3との接続を確認'),
        ),

        const SizedBox(height: 12),

        OutlinedButton.icon(
          onPressed: _hasAlert ? _acknowledgeAlert : _simulateAlert,
          icon: const Icon(Icons.notifications_active_outlined),
          label: Text(_hasAlert ? '異常通知を確認しました' : '異常検知をテスト'),
        ),

        const SizedBox(height: 8),

        OutlinedButton.icon(
          onPressed: _simulateCommunicationError,
          icon: const Icon(Icons.wifi_off),
          label: const Text('通信エラーをテスト'),
        ),

        const SizedBox(height: 24),

        // 貸出中もボタンを表示し、状態を分かるようにする
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed:
                _isBorrowed || _isRentalProcessing ? null : _scanSpotQrCode,
            icon: const Icon(Icons.qr_code_scanner),
            label: Text(
              _isRentalProcessing
                  ? '貸出処理中...'
                  : _isBorrowed
                      ? '貸出中です（返却後に利用できます）'
                      : '貸出QRコードを読み取る',
            ),
            style: FilledButton.styleFrom(
              backgroundColor: monitaGreen,
              foregroundColor: Colors.white,
            ),
          ),
        ),

        const SizedBox(height: 12),

        Text(
          'モニ太：${_isConnected ? '接続中' : '未接続'}',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.black54),
        ),
      ],
    );
  }

  /// ホーム上部にモニ太IDと貸出詳細を表示する
  Widget _buildDeviceHeader() {
    final monitorId =
        _isBorrowed ? (_selectedMonitorId ?? defaultMonitorId) : null;
    final spot = _selectedSpot;

    return Card(
      child: ListTile(
        leading: const CircleAvatar(
          backgroundColor: Color(0xFFE3F1E7),
          child: Icon(Icons.pets, color: monitaGreen),
        ),
        title: Text(
          _isBorrowed && monitorId != null ? monitorId : 'モニ太',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_isBorrowed && spot != null)
              Text('${spot.facilityName}・${spot.spotName}'),
            const SizedBox(height: 4),
            Text('貸出状況：${_isBorrowed ? '貸出中' : '未貸出'}'),
            if (_isBorrowed && _borrowedAt != null)
              Text('貸出日時：${_borrowedAt!.toString().substring(0, 16)}'),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: _showMonitorDetails,
      ),
    );
  }

  Widget _buildStatusPill() {
    Color color;

    switch (_status) {
      case MonitorStatus.standby:
        color = _isBorrowed ? Colors.blueGrey : Colors.grey;
        break;
      case MonitorStatus.monitoring:
        color = monitaGreen;
        break;
      case MonitorStatus.communicationError:
        color = Colors.red;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Text(
        _statusLabel,
        style: TextStyle(color: color, fontWeight: FontWeight.bold),
      ),
    );
  }

  Widget _buildAlertCard() {
    return Card(
      color: const Color(0xFFFFEBEE),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '荷物の異常を検知しました',
                    style: TextStyle(
                      color: Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _acknowledgeAlert,
                    child: const Text('確認'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    onPressed: _confirmStopMonitoring,
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                    ),
                    child: const Text('見守りを停止する', textAlign: TextAlign.center),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 設定画面
  Widget _buildSettings() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          '設定',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        Card(
          child: ListTile(
            leading: const Icon(Icons.wifi),
            title: const Text('Raspberry Pi 3との通信'),
            subtitle: Text(_isConnected ? '接続中' : '未接続'),
            trailing: IconButton(
              onPressed: _recheckConnection,
              icon: const Icon(Icons.refresh),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: const Text('管理画面'),
            subtitle: const Text('Wi-Fi設定・サービス操作・シャットダウン'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => MonitaAdminPage(
                  sendCommand: _adminCommand,
                  preferredConnection: () => _preferredConnection,
                  changeConnection: _setConnectionPreference,
                  connectionStatus: () => {
                    'bluetooth': _piBluetooth?.isConnected == true,
                    'wifi': _wifiVerified &&
                        _piSocket?.readyState == WebSocket.open,
                  },
                ),
              ),
            ),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('モニ太の詳細'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _showMonitorDetails,
          ),
        ),
      ],
    );
  }

  /// 通知・操作履歴
  Widget _buildHistory() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Text(
          '通知履歴',
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        if (_history.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: Center(child: Text('通知履歴はありません')),
          ),
        ..._history.map(
          (item) => Card(
            child: ListTile(
              leading: const Icon(Icons.notifications_none, color: monitaGreen),
              title: Text(item),
            ),
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _returnResultTimer?.cancel();
    _connectionRetryTimer?.cancel();
    for (final request in _pendingCommands.values) {
      if (!request.isCompleted) request.complete('ERROR:アプリを終了しました');
    }
    _pendingCommands.clear();

    _piSubscription?.cancel();
    _piSocket?.close();

    _bluetoothSubscription?.cancel();
    _piBluetooth?.close();

    super.dispose();
  }
}

/// 貸出場所のQRコードを読み取る画面
class SpotQrScannerPage extends StatefulWidget {
  const SpotQrScannerPage({super.key});

  @override
  State<SpotQrScannerPage> createState() => _SpotQrScannerPageState();
}

class _SpotQrScannerPageState extends State<SpotQrScannerPage> {
  bool _hasScanned = false;

  /// QRコードを読み取ったら文字列を前の画面へ返す
  void _onDetect(BarcodeCapture capture) {
    if (_hasScanned) return;

    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;

      if (value != null && value.isNotEmpty) {
        _hasScanned = true;
        Navigator.pop(context, value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('貸出QRコードを読み取る'),
        backgroundColor: monitaGreen,
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              '貸出場所に設置されたQRコードを読み取ってください。',
              textAlign: TextAlign.center,
            ),
          ),
          Expanded(child: MobileScanner(onDetect: _onDetect)),
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text('QRコードをカメラの枠内に合わせてください。', textAlign: TextAlign.center),
          ),
        ],
      ),
    );
  }
}

/// 管理画面。既存のユーザーアプリ内からBluetoothでPiを操作する。
class MonitaAdminPage extends StatefulWidget {
  const MonitaAdminPage({
    super.key,
    required this.sendCommand,
    required this.connectionStatus,
    required this.preferredConnection,
    required this.changeConnection,
  });
  final String Function() preferredConnection;
  final Future<void> Function(String) changeConnection;
  final Map<String, bool> Function() connectionStatus;
  final Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)
      sendCommand;
  @override
  State<MonitaAdminPage> createState() => _MonitaAdminPageState();
}

class _MonitaAdminPageState extends State<MonitaAdminPage> {
  final _password = TextEditingController();
  List<Map<String, dynamic>> _networks = [];
  List<Map<String, dynamic>> _savedNetworks = [];
  String? _connectedSsid;
  String? _connectedIp;
  String? _ssid;
  String _message = '本体操作・Wi-Fi設定にはBluetooth接続が必要です';
  String _monitaStatus = '未確認';
  String _returnStatus = '未確認';
  bool _busy = false;
  String? _selectedConnection;

  Future<void> _execute(
    String action, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = '処理中…';
    });
    try {
      final result = await widget.sendCommand(action, args);
      if (!mounted) return;
      setState(() {
        _message = result['message']?.toString() ?? '完了しました';
        if (action == 'wifi_status' || action == 'wifi_saved') {
          _connectedSsid = result['ssid']?.toString();
          _connectedIp = result['ip']?.toString();
          _savedNetworks = (result['saved'] as List<dynamic>? ?? [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
        }
        if (action == 'wifi_scan') {
          _networks = (result['networks'] as List<dynamic>? ?? [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          if (!_networks.any((n) => n['ssid'] == _ssid)) _ssid = null;
          _message = '${_networks.length}件のWi-Fiを検出しました';
        }
        if (action == 'body_status' || action == 'body_action')
          _monitaStatus = _message;
        if (action == 'service_status') {
          if (args['service'] == 'return') _returnStatus = _message;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _message = '操作失敗: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirm(
    String title,
    String action,
    Map<String, dynamic> args,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: const Text('操作を実行しますか？ 通信が切れる場合があります。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('キャンセル'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('実行'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) await _execute(action, args);
  }

  @override
  void initState() {
    super.initState();
    _selectedConnection = widget.preferredConnection();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _execute('wifi_status');
    });
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('モニ太 管理画面')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(_message),
            if (_busy) const LinearProgressIndicator(),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '通信状態',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '現在の操作通信：${widget.preferredConnection() != 'bluetooth' && widget.connectionStatus()['wifi'] == true ? 'Wi-Fi' : widget.connectionStatus()['bluetooth'] == true ? 'Bluetooth' : '未接続'}',
                    ),
                    const SizedBox(height: 12),
                    const Text('接続の切り替え'),
                    RadioGroup<String>(
                      groupValue:
                          _selectedConnection ?? widget.preferredConnection(),
                      onChanged: (value) async {
                        if (value == null || _busy) return;
                        setState(() {
                          _busy = true;
                          _selectedConnection = value;
                        });
                        try {
                          await widget.changeConnection(value);
                        } catch (error) {
                          if (mounted)
                            setState(() {
                              _selectedConnection =
                                  widget.preferredConnection();
                              _message = '通信切り替え失敗: $error';
                            });
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
                      child: const Column(
                        children: [
                          RadioListTile<String>(
                            title: Text('自動切り替え'),
                            subtitle: Text('Wi-Fiが使えれば優先し、使えなければBluetooth'),
                            value: 'auto',
                          ),
                          RadioListTile<String>(
                            title: Text('Bluetooth通信'),
                            value: 'bluetooth',
                          ),
                          RadioListTile<String>(
                            title: Text('Wi-Fi通信'),
                            subtitle: Text('接続できない場合はBluetoothで操作'),
                            value: 'wifi',
                          ),
                        ],
                      ),
                    ),
                    Text(
                      'Bluetooth：${widget.connectionStatus()['bluetooth'] == true ? '接続中' : '未接続'}',
                    ),
                    Text(
                      'Wi-Fi通信：${widget.connectionStatus()['wifi'] == true ? '接続中' : '未接続'}',
                    ),
                    Text('モニ太のWi-Fi：${_connectedSsid ?? '未接続'}'),
                    Text('モニ太のIPアドレス：${_connectedIp ?? 'なし'}'),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _execute('wifi_status'),
                      child: const Text('通信状態を更新'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'モニ太のWi-Fi設定',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _execute('wifi_scan'),
                      child: const Text('周囲のWi-Fiを検索'),
                    ),
                    if (_networks.isNotEmpty)
                      DropdownButtonFormField<String>(
                        initialValue: _ssid,
                        decoration:
                            const InputDecoration(labelText: '接続先Wi-Fi'),
                        items: _networks
                            .map(
                              (n) => DropdownMenuItem<String>(
                                value: n['ssid'].toString(),
                                child: Text(
                                  '${n['ssid']}（信号 ${n['signal']}）',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: (value) => setState(() => _ssid = value),
                      ),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Wi-Fiパスワード（必要な場合）',
                      ),
                    ),
                    FilledButton(
                      onPressed: _busy || _ssid == null
                          ? null
                          : () => _confirm('Wi-Fiを変更', 'wifi_connect', {
                                'ssid': _ssid,
                                'password': _password.text,
                              }),
                      child: const Text('このWi-Fiに接続'),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '登録済みWi-Fi',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    if (_savedNetworks.isEmpty) const Text('登録済みWi-Fiはありません'),
                    for (final network in _savedNetworks)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(network['ssid']?.toString() ?? ''),
                        subtitle: const Text('パスワードの再入力は不要です'),
                        trailing: Wrap(
                          children: [
                            IconButton(
                              tooltip: '接続',
                              icon: const Icon(Icons.wifi),
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      await _execute('wifi_saved_connect', {
                                        'uuid': network['uuid'],
                                      });
                                      if (mounted)
                                        await _execute('wifi_status');
                                    },
                            ),
                            IconButton(
                              tooltip: '登録を削除',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      await _confirm(
                                        '登録済みWi-Fiを削除',
                                        'wifi_saved_delete',
                                        {'uuid': network['uuid']},
                                      );
                                      if (mounted)
                                        await _execute('wifi_status');
                                    },
                            ),
                          ],
                        ),
                      ),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _execute('wifi_status'),
                      child: const Text('登録済みWi-Fiを更新'),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'モニ太本体',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    Text('状態: $_monitaStatus'),
                    OutlinedButton(
                      onPressed: _busy ? null : () => _execute('body_status'),
                      child: const Text('状態確認'),
                    ),
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _confirm('本体を起動しますか？', 'body_action', {
                                'operation': 'start',
                              }),
                      child: const Text('モニ太起動'),
                    ),
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _confirm('本体を停止しますか？', 'body_action', {
                                'operation': 'stop',
                              }),
                      child: const Text('モニ太停止'),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      '返却サーバー',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    Text('状態: $_returnStatus'),
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () =>
                              _execute('service_status', {'service': 'return'}),
                      child: const Text('状態確認'),
                    ),
                    FilledButton(
                      onPressed: _busy
                          ? null
                          : () => _confirm('返却サーバーを起動しますか？', 'service_action', {
                                'service': 'return',
                                'operation': 'start',
                              }),
                      child: const Text('再開'),
                    ),
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _confirm('返却サーバーを停止しますか？', 'service_action', {
                                'service': 'return',
                                'operation': 'stop',
                              }),
                      child: const Text('停止'),
                    ),
                  ],
                ),
              ),
            ),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Text(
                      'Raspberry Pi 3',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _confirm('Pi 3をシャットダウンしますか？', 'shutdown', {}),
                      child: const Text('シャットダウン'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
}
