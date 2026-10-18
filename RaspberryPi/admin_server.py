#!/usr/bin/env python3

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import subprocess
import threading

from system.shutdown_controller import shutdown_pi3


# 操作できるサービスを固定する
# 管理者サーバー自身は停止対象に含めない
SERVICES = {
    "monita": "monita.service",
    "return": "monita-return.service",
}


# 管理者ページのHTML
HTML = """<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>モニ太 管理者ページ</title>
<style>
body {
  font-family: sans-serif;
  max-width: 560px;
  margin: 24px auto;
  padding: 0 16px;
  color: #333;
}
h1, h2 { color: #2F8A55; }
section {
  margin: 20px 0;
  padding: 16px;
  border: 1px solid #ddd;
  border-radius: 10px;
}
button {
  padding: 12px;
  margin: 5px 0;
  width: 100%;
  font-size: 16px;
  border: 0;
  border-radius: 8px;
  background: #2F8A55;
  color: white;
  cursor: pointer;
}
.danger { background: #b42318; }
.status { font-weight: bold; }
#message { overflow-wrap: anywhere; }
</style>
</head>
<body>

<h1>モニ太 管理者ページ</h1>

<section>
  <h2>接続確認</h2>
  <button onclick="checkConnection()">接続確認</button>
  <p id="message" role="status"></p>
</section>

<section>
  <h2>モニ太本体</h2>
  <p>状態：<span id="monita-status" class="status">未確認</span></p>
  <button onclick="serviceAction('monita', 'status')">状態確認</button>
  <button class="danger"
          onclick="serviceAction('monita', 'stop')">停止</button>
  <button onclick="serviceAction('monita', 'start')">再開</button>
</section>

<section>
  <h2>返却サーバー</h2>
  <p>状態：<span id="return-status" class="status">未確認</span></p>
  <button onclick="serviceAction('return', 'status')">状態確認</button>
  <button class="danger"
          onclick="serviceAction('return', 'stop')">停止</button>
  <button onclick="serviceAction('return', 'start')">再開</button>
</section>

<section>
  <h2>Raspberry Pi 3</h2>
  <p>Pi 3本体の電源を切ります。</p>
  <button class="danger" onclick="shutdownPi()">シャットダウン</button>
</section>

<script>
async function postData(path, data = {}) {
  const response = await fetch(path, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8'
    },
    body: new URLSearchParams(data)
  });

  const result = await response.json();

  if (!response.ok) {
    throw new Error(result.message || '操作に失敗しました。');
  }

  return result;
}

// 管理者ページとサーバーの接続を確認する
async function checkConnection() {
  const message = document.getElementById('message');

  try {
    const result = await postData('/api/check');
    message.textContent = result.message;
  } catch (error) {
    message.textContent = error.message;
  }
}

// サービスの状態を取得して画面に表示する
async function refreshStatus(service) {
  const result = await postData('/api/service', {
    service: service,
    action: 'status'
  });

  document.getElementById(service + '-status').textContent =
    result.message;

  return result.message;
}

// モニ太本体または返却サーバーを操作する
async function serviceAction(service, action) {
  const names = {
    monita: 'モニ太本体',
    return: '返却サーバー'
  };

  if (action === 'stop' &&
      !confirm(names[service] + 'を停止しますか？')) {
    return;
  }

  if (action === 'start' &&
      !confirm(names[service] + 'を再開しますか？')) {
    return;
  }

  const message = document.getElementById('message');
  message.textContent = '処理中です…';

  try {
    const result = await postData('/api/service', {
      service: service,
      action: action
    });

    message.textContent = result.message;

    // 操作後の状態も取得する
    if (action !== 'status') {
      await new Promise(resolve => setTimeout(resolve, 800));
    }

    await refreshStatus(service);
  } catch (error) {
    message.textContent = error.message;
  }
}

// Raspberry Pi 3を安全にシャットダウンする
async function shutdownPi() {
  if (!confirm('Raspberry Pi 3をシャットダウンしますか？')) {
    return;
  }

  const message = document.getElementById('message');

  try {
    const result = await postData('/api/shutdown');
    message.textContent = result.message;
  } catch (error) {
    message.textContent = error.message;
  }
}

// ページを開いたときに各サービスの状態を取得する
window.addEventListener('DOMContentLoaded', async () => {
  for (const service of ['monita', 'return']) {
    try {
      await refreshStatus(service);
    } catch (error) {
      document.getElementById(service + '-status').textContent =
        '確認できません';
    }
  }
});
</script>
</body>
</html>
"""


class AdminHandler(BaseHTTPRequestHandler):

    # JSON形式でブラウザに結果を返す
    def send_json(self, status, message):
        body = json.dumps(
            {"message": message},
            ensure_ascii=False
        ).encode("utf-8")

        self.send_response(status)
        self.send_header(
            "Content-Type",
            "application/json; charset=utf-8"
        )
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    # 管理者ページを表示する
    def do_GET(self):
        if self.path != "/":
            self.send_error(404)
            return

        body = HTML.encode("utf-8")
        self.send_response(200)
        self.send_header(
            "Content-Type",
            "text/html; charset=utf-8"
        )
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    # ブラウザからの操作を処理する
    def do_POST(self):
        if self.path not in (
            "/api/check",
            "/api/service",
            "/api/shutdown"
        ):
            self.send_error(404)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self.send_json(400, "リクエストの形式が正しくありません。")
            return

        if length > 4096:
            self.send_json(400, "リクエストが大きすぎます。")
            return

        form = {}
        if length > 0:
            from urllib.parse import parse_qs
            form = parse_qs(
                self.rfile.read(length).decode(
                    "utf-8", errors="replace"
                )
            )

        # 接続確認
        if self.path == "/api/check":
            self.send_json(200, "管理者ページに接続できています。")
            return

        # サービスの状態確認・停止・再開
        if self.path == "/api/service":
            service = form.get("service", [""])[0]
            action = form.get("action", [""])[0]

            # 許可したサービスと操作だけを実行する
            if service not in SERVICES:
                self.send_json(400, "対象のプログラムが正しくありません。")
                return

            if action not in ("status", "start", "stop"):
                self.send_json(400, "操作が正しくありません。")
                return

            unit = SERVICES[service]

            try:
                if action == "status":
                    result = subprocess.run(
                        ["/usr/bin/systemctl", "is-active", unit],
                        capture_output=True,
                        text=True,
                        timeout=5,
                        check=False
                    )

                    status = result.stdout.strip() or "unknown"
                    self.send_json(200, status)
                    return

                result = subprocess.run(
                    ["/usr/bin/systemctl", action, unit],
                    capture_output=True,
                    text=True,
                    timeout=15,
                    check=False
                )

                if result.returncode != 0:
                    detail = (
                        result.stderr.strip()
                        or result.stdout.strip()
                    )
                    self.send_json(
                        500,
                        "操作に失敗しました。" +
                        ((" " + detail) if detail else "")
                    )
                    return

                message = (
                    "再開命令を送信しました。"
                    if action == "start"
                    else "停止命令を送信しました。"
                )
                self.send_json(200, message)
                return

            except subprocess.TimeoutExpired:
                self.send_json(500, "操作がタイムアウトしました。")
                return
            except OSError:
                self.send_json(500, "サービスを操作できませんでした。")
                return

        # Pi 3のシャットダウン
        if self.path == "/api/shutdown":
            self.send_json(200, "シャットダウン命令を送信しました。")
            threading.Thread(
                target=shutdown_pi3,
                daemon=True
            ).start()
            return

    # アクセスログを表示する
    def log_message(self, fmt, *args):
        print("[管理者ページ]", fmt % args)


if __name__ == "__main__":
    server = ThreadingHTTPServer(
        ("0.0.0.0", 8080),
        AdminHandler
    )

    print("管理者ページをポート8080で起動しました。")

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\\n管理者サーバーを終了します。")
    finally:
        server.server_close()
