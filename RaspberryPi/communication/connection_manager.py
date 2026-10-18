"""Socketを優先してPi 5へ再接続する通信管理。Bluetooth切替は未接続。"""
import threading
import time


class ConnectionManager:
    def __init__(self, socket_client, retry_initial=1, retry_max=30):
        self.socket_client = socket_client
        self.retry_initial = max(1, retry_initial)
        self.retry_max = max(self.retry_initial, retry_max)
        self.running = False
        self.active_client = None
        self.message_callback = None
        self.status_callback = None
        self.lock = threading.RLock()
        self.send_lock = threading.Lock()
        self.worker = None

    def start(self, message_callback=None, status_callback=None):
        with self.lock:
            if self.running:
                return
            self.running = True
            self.message_callback = message_callback
            self.status_callback = status_callback
            self.worker = threading.Thread(target=self._loop, daemon=True)
            self.worker.start()

    def _loop(self):
        delay = self.retry_initial
        while self._running():
            if not self.socket_client.is_connected():
                if not self.socket_client.connect():
                    self._set_active(False)
                    self._wait(delay)
                    delay = min(delay * 2, self.retry_max)
                    continue
            delay = self.retry_initial
            self._set_active(True)
            while self._running() and self.socket_client.is_connected():
                msg = self.socket_client.receive()
                if msg is not None and self.message_callback:
                    try:
                        self.message_callback(msg)
                    except Exception:
                        pass
            self.socket_client.close()
            self._set_active(False)

    def send(self, message):
        with self.send_lock:
            if not self.socket_client.is_connected():
                return False
            return self.socket_client.send(message)

    def _set_active(self, connected):
        callback = self.status_callback
        if callback:
            try:
                callback({"connected": connected, "transport": "socket" if connected else None})
            except Exception:
                pass

    def _running(self):
        with self.lock:
            return self.running

    def _wait(self, seconds):
        end = time.monotonic() + seconds
        while self._running() and time.monotonic() < end:
            time.sleep(min(0.2, max(0, end - time.monotonic())))

    def get_status(self):
        connected = self.socket_client.is_connected()
        return {"connected": connected, "transport": "socket" if connected else None}

    def stop(self):
        with self.lock:
            self.running = False
        self.socket_client.close()
