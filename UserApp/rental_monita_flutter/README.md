# レンタルモニ太 — Android利用者アプリ

Raspberry Pi 3を使用した持ち物の盗難防止システム「モニ太」の**実機連携済みAndroidアプリ**です。Flutter（Dart）で開発しています。

> 大学のチーム研究として開発中です（2026年10月時点）。画面のみのUIプロトタイプではなく、Raspberry Piとの通信・異常検知通知を実装し、実機で動作確認しています。

## 実装済みの主な機能

- **QRコードによる貸出**：貸出場所のQRコードを読み取り、貸出内容を確認して確定
- **見守り開始・停止**：Raspberry Piに操作コマンドを送信。停止時は確認操作を用意
- **センサー異常の受信**：Raspberry Piからの異常情報を受け取り、アプリ内に警告カードを表示
- **Android通知**：異常検知時に通知を表示。通知アイコンもモニ太のデザインを使用
- **Bluetooth Classic・Wi-Fi通信**：Raspberry Piとの通信、通信状態の確認、通信方式の選択・切り替え
- **管理者向け画面**：通信状態、Wi-Fi設定、モニ太本体や関連サービスの操作
- **返却処理**：アプリの返却操作により貸出・監視状態を解除し、返却完了を表示
- **履歴・設定**：操作履歴の確認、通信や異常検知のテスト機能

## 使用技術

- Flutter / Dart
- Bluetooth Classic
- Wi-Fi / WebSocket
- `mobile_scanner`（QRコード読み取り）
- `flutter_local_notifications`（Androidローカル通知）
- Firebase Messaging（通知関連の実装）
- Raspberry Pi 3 / Python（本体側。コードはリポジトリの `RaspberryPi/` を参照）

## 起動方法

Flutter SDKとAndroid SDKをセットアップし、このフォルダーで次を実行します。

```powershell
flutter pub get
flutter run
```

実機連携には、Raspberry Pi側プログラムの起動、Bluetoothペアリング、ネットワーク設定、Androidの必要な権限が必要です。Firebase等の端末・環境固有設定は別途用意してください。

## 現在の開発状況と今後の予定

- Raspberry Piとの通信、センサー異常の受信、Android通知、貸出・見守り・アプリからの返却操作は実装済みです。
- **返却箱のQRコード読み取りと返却サーバーによる実物の返却確認は今後の実装予定**です。現在のアプリの「返却完了」は返却箱での物理的な返却確認を意味しません。
- 接続の安定性、操作性、実環境での検証を継続しています。

## 制作について

大学のチーム研究として開発しています。個人の担当範囲はリポジトリ直下の `README.md` を参照してください。
