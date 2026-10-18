import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 返却箱の画面を縦向き・全画面表示にする
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  runApp(const MonitaReturnApp());
}

class MonitaReturnApp extends StatelessWidget {
  const MonitaReturnApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'モニ太返却',
      debugShowCheckedModeBanner: false,
      home: ReturnScreen(),
    );
  }
}

class ReturnScreen extends StatefulWidget {
  const ReturnScreen({super.key});

  @override
  State<ReturnScreen> createState() => _ReturnScreenState();
}

class _ReturnScreenState extends State<ReturnScreen> {
  // Raspberry Piの返却サーバーのURL
  static const String serverBaseUrl = 'http://raspberrypi.local:8081';

  // QRコードを送信するAPI
  static const String returnUrl = '$serverBaseUrl/api/return';

  // 返却受付中かどうかを確認するAPI
  static const String sessionUrl = '$serverBaseUrl/api/return/session';

  final MobileScannerController cameraController = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  // QRコードをサーバーへ送信している間は重複処理を防ぐ
  bool isProcessing = false;

  // サーバーが返却受付中と判断している場合だけQRを送信する
  bool returnSessionActive = false;

  // セッション確認の通信が重複しないようにする
  bool isCheckingSession = false;

  // 返却状態を定期的に確認するタイマー
  Timer? sessionTimer;

  @override
  void initState() {
    super.initState();

    // 起動直後に返却状態を確認する
    checkReturnSession();

    // 500ミリ秒ごとに返却受付状態を確認する
    sessionTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => checkReturnSession(),
    );
  }

  @override
  void dispose() {
    // 画面を閉じるときに定期確認を停止する
    sessionTimer?.cancel();

    cameraController.dispose();
    super.dispose();
  }

  /// 返却サーバーに問い合わせ、現在の返却受付状態を確認する
  Future<void> checkReturnSession() async {
    if (isCheckingSession) return;

    isCheckingSession = true;

    try {
      final response = await http
          .get(Uri.parse(sessionUrl))
          .timeout(const Duration(seconds: 3));

      if (response.statusCode != 200) {
        returnSessionActive = false;
        return;
      }

      final dynamic result = jsonDecode(response.body);

      if (result is! Map<String, dynamic>) {
        returnSessionActive = false;
        return;
      }

      // QRコードを処理していない受付中のセッションだけ許可する
      returnSessionActive =
          result['active'] == true &&
          result['status'] == 'scanning' &&
          !isProcessing;
    } catch (_) {
      // 通信できないときはQRコードを送信しない
      returnSessionActive = false;
    } finally {
      isCheckingSession = false;
    }
  }

  /// QRコードを読み取ったら、返却受付中か確認して送信する
  Future<void> onQrDetected(BarcodeCapture capture) async {
    // 返却受付前、または処理中ならQRコードを送信しない
    if (!returnSessionActive || isProcessing) return;

    final String? qrText = capture.barcodes.isEmpty
        ? null
        : capture.barcodes.first.rawValue;

    if (qrText == null || qrText.trim().isEmpty) return;

    // 同じセッションでQRコードを重複送信しない
    isProcessing = true;
    returnSessionActive = false;

    // 通信中の重複読み取りを防ぐためカメラを一時停止する
    try {
      await cameraController.stop();
    } catch (_) {
      // カメラ停止に失敗しても送信を試みる
    }

    await sendReturnRequest(qrText.trim());
  }

  /// 読み取ったQRコードを返却サーバーへ送信する
  Future<void> sendReturnRequest(String qrId) async {
    try {
      final response = await http
          .post(
            Uri.parse(returnUrl),
            headers: {'Content-Type': 'application/json; charset=utf-8'},
            body: jsonEncode({'qr_id': qrId}),
          )
          .timeout(const Duration(seconds: 8));

      // 成功・失敗の結果は借りる側アプリがサーバーから取得する
      if (response.statusCode == 200) {
        // 返却成功。カメラを再開し、次の受付に備える
      } else {
        // QR不一致や受付終了などの場合もカメラを再開する
      }
    } catch (_) {
      // 通信失敗時も画面に文章などは表示しない
    } finally {
      await resumeCamera();
    }
  }

  /// カメラを再開し、次の返却受付に備える
  Future<void> resumeCamera() async {
    await Future<void>.delayed(const Duration(milliseconds: 500));

    isProcessing = false;

    try {
      await cameraController.start();
    } catch (_) {
      // カメラ再開に失敗した場合も画面に文章は表示しない
    }

    // 再開直後の受付状態を確認する
    await checkReturnSession();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(
        child: MobileScanner(
          controller: cameraController,
          onDetect: onQrDetected,

          // カメラエラー時も文章やボタンを表示しない
          errorBuilder: (context, error) {
            return const ColoredBox(color: Colors.black);
          },
        ),
      ),
    );
  }
}
