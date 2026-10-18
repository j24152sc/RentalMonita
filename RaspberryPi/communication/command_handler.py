"""Pi 5から受信した命令を実行する。"""
import subprocess
import threading


class CommandHandler:
    ALLOWED = {"MONITOR_START", "MONITOR_STOP", "RENTAL_CONFIRMED", "RETURN_CONFIRMED", "SHUTDOWN"}

    def __init__(self, monitoring, led, speaker, status):
        self.monitoring, self.led, self.speaker, self.status = monitoring, led, speaker, status
        self.lock = threading.Lock()
        self.seen_message_ids = set()

    def handle(self, command, message_id=None):
        if not isinstance(command, str) or command not in self.ALLOWED:
            return False
        with self.lock:
            if message_id and message_id in self.seen_message_ids:
                return True
            if command == "MONITOR_START":
                self.monitoring.start()
            elif command == "MONITOR_STOP":
                self.monitoring.stop()
                self.led.clear()
            elif command == "RENTAL_CONFIRMED":
                self.led.show_white()
                self.speaker.play("take_monita.wav")
            elif command == "RETURN_CONFIRMED":
                self.led.clear()
                self.speaker.play("return_complete.wav")
            elif command == "SHUTDOWN":
                state = self.status()
                if state.get("borrowed") or state.get("monitoring"):
                    return False
                self.led.clear()
                subprocess.Popen(["sudo", "/usr/sbin/shutdown", "-h", "now"])
            if message_id:
                self.seen_message_ids.add(message_id)
                if len(self.seen_message_ids) > 2000:
                    self.seen_message_ids.clear()
            return True
