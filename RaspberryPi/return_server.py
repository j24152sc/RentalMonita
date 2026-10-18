
#!/usr/bin/env python3

"""返却開始・QRコード確認・返却結果を管理するサーバー。"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError
import json
import threading
import time

HOST = "0.0.0.0"
PORT = 8081

# 返却対象のモニ太の識別番号
MONITA_ID = "TUIS-MONI-001"

# 同じRaspberry Pi内で動いているmonita.pyの返却受付
RETURN_CONTROL_URL = "http://127.0.0.1:50008/return"

# QRコードを読み取るための制限時間（秒）
RETURN_TIMEOUT = 15

# 返却状態を複数の通信から安全に操作する
lock = threading.Lock()

# 現在の返却セッション
session = {
    "active": False,
    "status": "idle",
    "message": "",
    "started_at": 0.0,
    "session_id": 0,
}


def start_return():
    """返却開始要求を受け付け、新しい返却セッションを開始する。"""
    with lock:
        # 返却結果が未確認、または返却処理中なら再開始させない
        if session["status"] != "idle":
            return False

        session["session_id"] += 1
        session["active"] = True
        session["status"] = "scanning"
        session["message"] = ""
        session["started_at"] = time.monotonic()

        print(
            f"[返却サーバー] 返却受付を開始しました"
            f"（セッション {session['session_id']}）"
        )
        return True


def check_timeout_locked():
    """ロック中に、QR読み取りの制限時間を確認する。"""
    if (
        session["active"]
        and session["status"] == "scanning"
        and time.monotonic() - session["started_at"] >= RETURN_TIMEOUT
    ):
        session["active"] = False
        session["status"] = "failed"
        session["message"] = "モニ太の位置をなおして下さい"
        print("[返却サーバー] QRコードの読み取りがタイムアウトしました")


def get_session():
    """現在の返却状態を返す。"""
    with lock:
        check_timeout_locked()
        return {
            "active": session["active"],
            "status": session["status"],
            "message": session["message"],
        }


def claim_qr_session():
    """QRコードを処理する権利を1つのリクエストだけに与える。"""
    with lock:
        check_timeout_locked()

        # 返却受付中かつ、まだ別のQRを処理していない場合だけ受け付ける
        if not session["active"] or session["status"] != "scanning":
            return None

        session["status"] = "processing"
        return session["session_id"]


def finish_return(session_id, status, message):
    """現在のセッションに対してだけ返却結果を保存する。"""
    with lock:
        # 古いリクエストが新しいセッションの結果を上書きしないようにする
        if (
            session["session_id"] != session_id
            or session["status"] != "processing"
        ):
            return False

        session["active"] = False
        session["status"] = status
        session["message"] = message
        print(f"[返却サーバー] 結果: {status} / {message}")
        return True


def acknowledge_result():
    """借りる側アプリが結果を確認した後、状態を初期化する。"""
    with lock:
        session["active"] = False
        session["status"] = "idle"
        session["message"] = ""
        session["started_at"] = 0.0


class ReturnHandler(BaseHTTPRequestHandler):

    def send_json(self, status_code, data):
        """JSON形式でスマホに結果を返す。"""
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")

        self.send_response(status_code)
        self.send_header(
            "Content-Type", "application/json; charset=utf-8"
        )
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def read_json(self):
        """リクエスト本文をJSONとして読み取る。"""
        length = int(self.headers.get("Content-Length", "0"))

        if length <= 0 or length > 1024:
            raise ValueError("リクエストサイズが不正です")

        data = json.loads(self.rfile.read(length).decode("utf-8"))

        if not isinstance(data, dict):
            raise ValueError("リクエスト形式が不正です")

        return data

    def do_GET(self):
        """スマホから返却状態の確認を受け付ける。"""
        if self.path == "/api/return/session":
            self.send_json(200, get_session())
            return

        self.send_json(404, {"success": False})

    def do_POST(self):
        """返却開始、QRコード送信、結果確認を処理する。"""

        # 借りる側アプリが返却ボタンを押したとき
        if self.path == "/api/return/start":
            if start_return():
                self.send_json(200, {
                    "success": True,
                    "message": "返却を開始しました",
                })
            else:
                self.send_json(409, {
                    "success": False,
                    "message": "前の返却結果を確認してください",
                })
            return

        # 借りる側アプリが返却結果を確認したとき
        if self.path == "/api/return/ack":
            acknowledge_result()
            self.send_json(200, {"success": True})
            return

        # 返却箱のスマホからQRコードが送られたとき
        if self.path != "/api/return":
            self.send_json(404, {"success": False})
            return

        try:
            data = self.read_json()
            qr_id = data.get("qr_id", "")

            if not isinstance(qr_id, str):
                raise ValueError("QRコードの形式が不正です")

            qr_id = qr_id.strip()

            if not qr_id:
                raise ValueError("QRコードが空です")

        except (ValueError, UnicodeDecodeError):
            self.send_json(400, {"success": False})
            return

        # 返却受付中かどうかを確認し、同時に処理権を確保する
        session_id = claim_qr_session()

        if session_id is None:
            self.send_json(409, {
                "success": False,
                "message": "返却受付中ではないか、処理済みです",
            })
            return

        # 間違ったQRコードでも結果を保存し、借りる側アプリへ伝える
        if qr_id != MONITA_ID:
            finish_return(
                session_id,
                "failed",
                "モニ太の位置をなおして下さい",
            )
            print("[返却サーバー] QRコードが一致しません")
            self.send_json(400, {"success": False})
            return

        # 正しいQRコードの場合だけモニ太本体に返却命令を送る
        body = json.dumps(
            {"qr_id": qr_id},
            ensure_ascii=False,
        ).encode("utf-8")

        request = Request(
            RETURN_CONTROL_URL,
            data=body,
            headers={
                "Content-Type": "application/json; charset=utf-8"
            },
            method="POST",
        )

        try:
            with urlopen(request, timeout=5) as response:
                result = json.loads(response.read().decode("utf-8"))

            if (
                response.status == 200
                and isinstance(result, dict)
                and result.get("success") is True
            ):
                finish_return(
                    session_id,
                    "success",
                    "ありがとうございました",
                )
                print("[返却サーバー] 返却に成功しました")
                self.send_json(200, {"success": True})
                return

            finish_return(
                session_id,
                "failed",
                "モニ太の位置をなおして下さい",
            )
            self.send_json(409, {"success": False})

        except (
            HTTPError,
            URLError,
            TimeoutError,
            OSError,
            ValueError,
            json.JSONDecodeError,
        ) as error:
            print(f"[返却サーバー] 返却処理に失敗しました: {error}")
            finish_return(
                session_id,
                "failed",
                "モニ太の位置をなおして下さい",
            )
            self.send_json(503, {"success": False})

    def log_message(self, format, *args):
        print("[返却サーバー]", format % args)


if __name__ == "__main__":
    print(f"返却サーバーを起動します: ポート {PORT}")
    ThreadingHTTPServer((HOST, PORT), ReturnHandler).serve_forever()
