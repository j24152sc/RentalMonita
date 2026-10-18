"""Pi 5へ接続し、改行区切りJSONを送受信するSocketクライアント。"""
import json
import socket
import threading


class SocketClient:
    def __init__(self, host, port, connect_timeout=5, receive_timeout=1):
        self.host, self.port = host, port
        self.connect_timeout, self.receive_timeout = connect_timeout, receive_timeout
        self.sock = None
        self.connected = False
        self.send_lock = threading.Lock()
        self.receive_lock = threading.Lock()
        self.receive_buffer = b""
        self.state_lock = threading.RLock()

    def connect(self):
        self.close()
        try:
            conn = socket.create_connection((self.host, self.port), timeout=self.connect_timeout)
            conn.settimeout(self.receive_timeout)
            with self.state_lock:
                self.sock, self.connected, self.receive_buffer = conn, True, b""
            return True
        except OSError:
            self.close()
            return False

    def send(self, message):
        if not isinstance(message, dict):
            return False
        try:
            payload = (json.dumps(message, ensure_ascii=False) + "\n").encode("utf-8")
            with self.send_lock:
                with self.state_lock:
                    conn = self.sock if self.connected else None
                if conn is None:
                    return False
                conn.sendall(payload)
            return True
        except (OSError, TypeError, ValueError):
            self.close()
            return False

    def receive(self):
        with self.receive_lock:
            with self.state_lock:
                conn = self.sock if self.connected else None
            if conn is None:
                return None
            try:
                while b"\n" not in self.receive_buffer:
                    chunk = conn.recv(4096)
                    if not chunk:
                        self.close()
                        return None
                    self.receive_buffer += chunk
                line, self.receive_buffer = self.receive_buffer.split(b"\n", 1)
                if not line.strip():
                    return None
                msg = json.loads(line.decode("utf-8"))
                return msg if isinstance(msg, dict) else None
            except socket.timeout:
                return None
            except (OSError, UnicodeDecodeError, json.JSONDecodeError):
                self.close()
                return None

    def is_connected(self):
        with self.state_lock:
            return self.connected and self.sock is not None

    def close(self):
        with self.state_lock:
            conn = self.sock
            self.sock, self.connected, self.receive_buffer = None, False, b""
        if conn is not None:
            try:
                conn.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                conn.close()
            except OSError:
                pass
