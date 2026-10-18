
from pathlib import Path

from config import MONITA_ID
from monitoring.sensor_manager import SensorManager
from monitoring.anomaly_detector import detect_anomaly
from monitoring.monitoring_controller import MonitoringController
from hardware.sense_hat_controller import SenseHatController
from hardware.speaker_controller import SpeakerController
from communication.command_handler import CommandHandler
from communication.server_client import Pi5Client


def main():
    """見守り処理・ハードウェア・Pi 5との通信を連携させる。"""

    # センサーと見守り処理を初期化
    sensor = SensorManager()
    monitor = MonitoringController(sensor, detect_anomaly)

    # LED・スピーカーを初期化
    led = SenseHatController()
    sound_dir = Path(__file__).resolve().parent / "sounds"
    speaker = SpeakerController(sound_dir)

    # 貸出状態を管理
    state = {
        "borrowed": False,
    }

    # Pi 5へ送信するモニ太の状態を取得
    def get_status():
        return {
            "type": "status",
            "monita_id": MONITA_ID,
            "monitoring": monitor.active,
            "borrowed": state["borrowed"],
            "anomaly": monitor.last_anomaly,
        }

    # Pi 5から受信したコマンドを処理
    handler = CommandHandler(
        monitor,
        led,
        speaker,
        get_status,
    )

    original_handle = handler.handle

    def handle_command(command):
        # 貸出・返却状態を更新
        if command == "RENTAL_CONFIRMED":
            state["borrowed"] = True

        elif command == "RETURN_CONFIRMED":
            state["borrowed"] = False

        # 通常のコマンド処理を実行
        original_handle(command)

    handler.handle = handle_command

    # Pi 5との通信を開始
    client = Pi5Client(
        handler,
        get_status,
    )
    client.run()


if __name__ == "__main__":
    main()
