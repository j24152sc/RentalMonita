"""Pi 5との通信、状態送信、受信命令の仲介。"""
import threading
import time
from config import PI5_HOST, PI5_PORT, MONITA_ID, SOCKET_RETRY_SECONDS
from communication.socket_client import SocketClient
from communication.connection_manager import ConnectionManager


class Pi5Client:
    def __init__(self, handler, status):
        self.handler, self.status = handler, status
        self.running = False
        self.socket_client = SocketClient(PI5_HOST, PI5_PORT)
        self.manager = ConnectionManager(self.socket_client, retry_initial=SOCKET_RETRY_SECONDS)
        self.status_thread = None

    def run(self):
        if self.running:
            return
        self.running = True
        self.manager.start(self._handle_message)
        self.status_thread = threading.Thread(target=self._send_status_loop, daemon=True)
        self.status_thread.start()
        try:
            while self.running:
                time.sleep(0.5)
        finally:
            self.stop()

    def _handle_message(self, message):
        if message.get("type") == "command":
            self.handler.handle(message.get("command"), message.get("message_id"))

    def _send_status_loop(self):
        while self.running:
            payload = {"type": "status", "monita_id": MONITA_ID, **self.status()}
            self.manager.send(payload)
            for _ in range(10):
                if not self.running:
                    return
                time.sleep(0.5)

    def send_alert(self, alert):
        return self.manager.send({"type": "alert", "monita_id": MONITA_ID, "alert": alert, "timestamp": time.time()})

    def stop(self):
        self.running = False
        self.manager.stop()
