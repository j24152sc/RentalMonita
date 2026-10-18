# モニ太（Rental Monita）

**Raspberry Piを活用した持ち物の盗難防止システム**  |  大学でのチーム研究・開発中（2026年10月現在）

![モニ太の試作機](screenshots/monita_device.jpg)

## 概要・開発目的

大学や施設で短時間席を離れる際の持ち物の盗難リスクを軽減するため、Raspberry Piとセンサーを使って持ち物の動きを検知し、異常時にAndroidアプリへ通知するシステム「モニ太」を開発しています。貸出から見守り、返却までの操作をスマートフォンで行えることを目指しています。

## 自分の担当

- Raspberry Pi 3の設定・動作制御
- センサーによる異常検知機能
- Bluetooth・Wi-Fiによる通信機能
- FlutterアプリのUI設計・実装
- 管理者向け機能の実装
- チーム内の進捗管理

※チーム制作のため、本リポジトリに含まれるコードのすべてを個人で制作したという意味ではありません。

## 使用技術

- **Flutter / Dart**：Android向け利用者アプリ、返却用アプリ
- **Python / Raspberry Pi 3 / Sense HAT**：本体制御・センサー監視（本体制御・センサー監視）
- **Bluetooth Classic**：本体との通信
- **Wi-Fi / WebSocket**：ネットワーク経由の通信
- **Firebase Messaging / flutter_local_notifications**：通知関連機能

## 画面・動作例

### 1. 貸出前のホーム画面
![貸出前のホーム画面](screenshots/home.jpg)

### 2. QRコード読み取り後の貸出確認
![貸出確認画面](screenshots/rental_confirmation.jpg)

### 3. 貸出後の待機画面
![貸出後の待機画面](screenshots/standby.jpg)

### 4. 見守り中
![見守り中の画面](screenshots/monitoring.jpg)

### 5. 異常検知とAndroid通知
![異常検知時の画面と通知](screenshots/alert_notification.jpg)

### 6. 管理者向け画面
Bluetooth・Wi-Fiの通信状態や本体の操作機能を確認できます。画面中のネットワーク識別情報は公開用に伏せています。

![通信設定](screenshots/admin_network_redacted.jpg)
![本体・サービス操作](screenshots/admin_controls_redacted.jpg)

### 7. 返却完了
![返却完了画面](screenshots/return_complete.jpg)

## 工夫した点

- **通信手段の選択**：BluetoothとWi-Fiの通信経路を用意し、環境に応じた接続・操作を検討
- **異常の可視化**：センサーによる検知結果をアプリの警告表示とAndroid通知につなぐ
- **操作の分かりやすさ**：貸出・見守り・返却の状態を画面で確認できるUIを設計
- **運用を意識した管理機能**：接続状態やモニ太本体の操作を管理画面から確認

## 開発状況・注意点

- 2026年10月現在、開発・動作確認を継続中です。
- 利用者アプリでは、QRコードによる貸出、見守り操作、異常検知通知などを実装しています。
- 現在の返却操作はアプリ側の返却処理を中心に実装しています。返却箱でのQRコード読み取りとサーバーによる確認は今後の連携課題です。
- `RaspberryPi/` にPythonコードを収録しています。実機のハードウェア構成・OS・権限・通信設定が必要なため、コードだけで動作するものではありません。
- Firebase設定や端末固有の設定は含めていないため、アプリのビルドには別途環境設定が必要な場合があります。

## フォルダー構成

```text
RentalMonita/
├── README.md
├── .gitignore
├── UserApp/rental_monita_flutter/  # 利用者向けFlutterアプリ
├── ReturnApp/monita_return_app/    # 返却用Flutterアプリ（開発中）
├── RaspberryPi/                    # Pythonによる本体・センサー・管理機能
└── screenshots/                    # アプリ画面・試作機の写真
```

## Raspberry Pi側の実装

`RaspberryPi/monita.py` を中心に、センサー監視・Bluetooth通信・WebSocket通信・貸出状態の制御などを実装しています。`admin_server.py` は管理機能、`return_server.py` は返却サーバー関連のコードです。`hardware/`、`monitoring/`、`communication/`、`system/` には機能別のモジュールを収録しています。

※ 実機での起動設定や依存パッケージ、設定値は環境に応じた調整が必要です。`sounds/` の音声ファイルは権利関係を確認するため公開用ZIPから除外しています。

## 公開について

大学でのチーム制作物です。公開範囲については共同制作者の許可を確認してください。コードや画面に含まれる設定値・ネットワーク情報は公開前に再確認してください。
