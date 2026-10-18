
import json
import socket
import threading


class BluetoothClient:
    """Bluetooth（RFCOMM）通信の接続・送受信を担当する。"""

    def __init__(
        self,
        address,
        port=1,
        connect_timeout=5,
        receive_timeout=1,
    ):
        self.address = address
        self.port = port
        self.connect_timeout = connect_timeout
        self.receive_timeout = receive_timeout

        self.sock = None
        self.connected = False

        self.send_lock = threading.Lock()
        self.receive_lock = threading.Lock()
        self.receive_buffer = b""

    def connect(self):
        """Bluetooth経由で接続先に接続する。"""

        self.close()

        try:
            connection = socket.socket(
                socket.AF_BLUETOOTH,
                socket.SOCK_STREAM,
                socket.BTPROTO_RFCOMM,
            )

            connection.settimeout(self.connect_timeout)
            connection.connect((self.address, self.port))
            connection.settimeout(self.receive_timeout)

            self.sock = connection
            self.connected = True
            self.receive_buffer = b""

            return True

        except (OSError, AttributeError):
            self.close()
            return False

    def send(self, message):
        """辞書形式のメッセージをJSONに変換して送信する。"""

        if not isinstance(message, dict):
            return False

        try:
            data = (
                json.dumps(message, ensure_ascii=False) + "\n"
            ).encode("utf-8")

            with self.send_lock:
                if not self.is_connected():
                    return False

                self.sock.sendall(data)

            return True

        except (OSError, TypeError, ValueError):
            self.close()
            return False

    def receive(self):
        """改行区切りのJSONメッセージを1件受信する。

        タイムアウト時や受信データが揃っていない場合はNoneを返す。
        """

        with self.receive_lock:
            if not self.is_connected():
                return None

            try:
                while b"\n" not in self.receive_buffer:
                    data = self.sock.recv(4096)

                    # 相手側が接続を切断した
                    if not data:
                        self.close()
                        return None

                    self.receive_buffer += data

                line, self.receive_buffer = self.receive_buffer.split(
                    b"\n", 1
                )

                if not line.strip():
                    return None

                message = json.loads(line.decode("utf-8"))

                if not isinstance(message, dict):
                    return None

                return message

            except socket.timeout:
                return None

            except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                self.close()
                return None

    def is_connected(self):
        """ローカルで接続中として管理しているかを返す。"""

        return self.connected and self.sock is not None

    def close(self):
        """Bluetooth接続を安全に閉じる。"""

        connection = self.sock
        self.sock = None
        self.connected = False
        self.receive_buffer = b""

        if connection is not None:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

            try:
                connection.close()
            except OSError:
                pass
