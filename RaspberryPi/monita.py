
#!/usr/bin/python3

import signal
import asyncio
import base64
import hashlib
import json
import math
import os
import time
import traceback
import threading
import subprocess
import socket
from pathlib import Path

import smbus2
from sense_hat import SenseHat

# Bluetooth Classic用ライブラリ
try:
    import bluetooth
except ImportError:
    bluetooth = None


SERVER_PORT = 50007
RETURN_CONTROL_PORT = 50008

# Bluetooth Classicのサービス名
BLUETOOTH_SERVICE_NAME = "MonitaBluetooth"
BLUETOOTH_SERVICE_UUID = "00001101-0000-1000-8000-00805F9B34FB"
BLUETOOTH_RFCOMM_CHANNEL = 3

# センサーの貸出状態を保存するファイル
RENTAL_STATE_FILE = "/home/raspi6/raspi/monita/rental_state.json"

# 見守り状態を保存するファイル
MONITORING_STATE_FILE = "/tmp/robot_monitoring"

# 効果音ファイルの保存先
SOUND_DIR = Path(__file__).resolve().parent / "sounds"


# ---------------------------------------------------------
# MP3再生
# ---------------------------------------------------------

def play_mp3(filename):
    """USBスピーカーからMP3音声を再生する。"""
    sound_file = SOUND_DIR / filename

    if not sound_file.is_file():
        print(f"[WARNING] 音声ファイルが見つかりません: {sound_file}")
        return

    def playback():
        try:
            subprocess.run(
                [
                    "/usr/bin/mpg123",
                    "-q",
                    "-a",
                    "hw:2,0",
                    str(sound_file),
                ],
                check=True,
                timeout=30,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )

            print(f"効果音を再生しました: {filename}")

        except FileNotFoundError:
            print("[ERROR] mpg123がインストールされていません")

        except subprocess.TimeoutExpired:
            print(f"[ERROR] 音声再生がタイムアウトしました: {filename}")

        except subprocess.CalledProcessError as e:
            print(f"[ERROR] MP3再生に失敗しました: {filename}")
            if e.stderr:
                print(e.stderr.strip())

        except Exception as e:
            print(f"[ERROR] MP3再生中にエラーが発生しました: {e}")

    threading.Thread(
        target=playback,
        daemon=True,
    ).start()


# ---------------------------------------------------------
# LSM9DS1 センサー設定
# ---------------------------------------------------------

LSM9DS1_ADDR = 0x6A
WHO_AM_I = 0x0F
CTRL_REG1_G = 0x10
CTRL_REG6_XL = 0x20
OUT_X_L_G = 0x18
OUT_X_L_XL = 0x28

GYRO_SCALE = 245.0 / 32768.0
ACCEL_SCALE = 2.0 / 32768.0

GYRO_THRESHOLD = 5.0
ACCEL_THRESHOLD = 5.0

bus = smbus2.SMBus(1)


def write_register(register, value):
    """LSM9DS1のレジスタに値を書き込む。"""
    bus.write_byte_data(LSM9DS1_ADDR, register, value)


def read_register(register):
    """LSM9DS1のレジスタから値を読み取る。"""
    return bus.read_byte_data(LSM9DS1_ADDR, register)


def read_registers(register, length):
    """LSM9DS1から複数バイトのデータを読み取る。"""
    return bus.read_i2c_block_data(
        LSM9DS1_ADDR, register | 0x80, length
    )


def convert_signed_16bit(low, high):
    """16ビットの符号付きデータに変換する。"""
    value = (high << 8) | low

    if value >= 32768:
        value -= 65536

    return value


def init_lsm9ds1():
    """LSM9DS1を初期化する。"""
    try:
        who_am_i = read_register(WHO_AM_I)
        print(f"LSM9DS1 WHO_AM_I: 0x{who_am_i:02X}")

        if who_am_i != 0x68:
            print("[ERROR] LSM9DS1を確認できません")
            return False

        write_register(CTRL_REG1_G, 0x60)
        write_register(CTRL_REG6_XL, 0x60)

        time.sleep(0.1)
        print("LSM9DS1初期化完了")
        return True

    except Exception as e:
        print(f"[ERROR] LSM9DS1初期化失敗: {e}")
        return False


def get_accel_data():
    """LSM9DS1から加速度を取得する。"""
    data = read_registers(OUT_X_L_XL, 6)

    raw_x = convert_signed_16bit(data[0], data[1])
    raw_y = convert_signed_16bit(data[2], data[3])
    raw_z = convert_signed_16bit(data[4], data[5])

    return (
        raw_x * ACCEL_SCALE,
        raw_y * ACCEL_SCALE,
        raw_z * ACCEL_SCALE,
    )


def get_gyro_data():
    """LSM9DS1からジャイロを取得する。"""
    data = read_registers(OUT_X_L_G, 6)

    raw_x = convert_signed_16bit(data[0], data[1])
    raw_y = convert_signed_16bit(data[2], data[3])
    raw_z = convert_signed_16bit(data[4], data[5])

    return (
        raw_x * GYRO_SCALE,
        raw_y * GYRO_SCALE,
        raw_z * GYRO_SCALE,
    )


def get_sensor_signal():
    """加速度とジャイロから異常を判定する。"""
    acc_x, acc_y, _ = get_accel_data()
    horizontal_acc = math.sqrt(acc_x ** 2 + acc_y ** 2)

    gyro_x, gyro_y, gyro_z = get_gyro_data()
    gyro_motion = math.sqrt(
        gyro_x ** 2 + gyro_y ** 2 + gyro_z ** 2
    )

    status = (
        "Warning"
        if gyro_motion >= GYRO_THRESHOLD
        or horizontal_acc >= ACCEL_THRESHOLD
        else "Safe"
    )

    return status, gyro_motion, horizontal_acc


# ---------------------------------------------------------
# 貸出状態・Sense HAT
# ---------------------------------------------------------

sense = SenseHat()

is_borrowed = False
monitoring_enabled = False
warning_active = False
# 通信サーバーは稼働したまま、本体機能だけを切り替える
body_enabled = False


def save_rental_state():
    """貸出状態をファイルに保存する。"""
    temporary_file = RENTAL_STATE_FILE + ".tmp"

    try:
        with open(temporary_file, "w", encoding="utf-8") as file:
            json.dump(
                {"is_borrowed": is_borrowed},
                file
            )

        # 書き込み途中のファイルが残らないように置き換える
        os.replace(temporary_file, RENTAL_STATE_FILE)

    except Exception as e:
        print(f"[ERROR] 貸出状態の保存に失敗しました: {e}")

        try:
            if os.path.exists(temporary_file):
                os.remove(temporary_file)
        except OSError:
            pass


def load_rental_state():
    """保存済みの貸出状態を読み込む。"""
    try:
        with open(RENTAL_STATE_FILE, "r", encoding="utf-8") as file:
            data = json.load(file)

        return data.get("is_borrowed") is True

    except FileNotFoundError:
        return False

    except Exception as e:
        print(f"[WARNING] 貸出状態を読み込めません: {e}")
        return False


def show_unborrowed():
    """未貸出：左上の1ピクセルだけ灰色にする。"""
    pixels = [(0, 0, 0)] * 64
    pixels[0] = (80, 80, 80)
    sense.set_pixels(pixels)


def show_borrowed():
    """貸出中・見守り停止：全体を灰色にする。"""
    sense.clear(80, 80, 80)


def show_monitoring():
    """見守り中：全体を緑色にする。"""
    sense.clear(0, 255, 0)


def show_warning():
    """異常検知中：全体を赤色にする。"""
    sense.clear(255, 0, 0)


def is_monitoring():
    """現在の見守り状態を返す。"""
    return monitoring_enabled


def set_monitoring_state(enabled):
    """見守り状態を更新し、状態ファイルに保存する。"""
    global monitoring_enabled

    changed = monitoring_enabled != enabled
    monitoring_enabled = enabled

    try:
        with open(MONITORING_STATE_FILE, "w") as file:
            file.write("ON" if enabled else "OFF")
    except OSError as e:
        print(f"[WARNING] 監視状態ファイルの更新失敗: {e}")

    if changed:
        print(f"センサー監視: {'ON' if enabled else 'OFF'}")


# ---------------------------------------------------------
# 通信クライアント管理
# ---------------------------------------------------------

connected_clients = set()

# Bluetoothソケットはスレッドからも操作するためロックを使用
bluetooth_clients = set()
bluetooth_clients_lock = threading.Lock()

main_event_loop = None
bluetooth_server_socket = None

# 同じ要求IDの命令を別経路で受信しても一度だけ処理する
command_lock = None
command_results = {}
COMMAND_CACHE_LIMIT = 300


async def execute_app_command(message):
    """要求ID付きの命令を処理し、実行結果と最新状態を返す。"""
    global command_lock
    if command_lock is None:
        command_lock = asyncio.Lock()

    if not message.startswith("CMD:"):
        # 古いアプリとの互換性を維持する
        async with command_lock:
            handled = await process_command(message)
            return handled, None

    parts = message.split(":", 2)
    if len(parts) != 3 or not parts[1] or len(parts[1]) > 80:
        return False, None
    request_id, command = parts[1], parts[2]
    if command not in ("status", "borrow", "start", "stop", "return", "acknowledge"):
        return False, f"ACK:{request_id}:ERROR:未対応の命令です"

    async with command_lock:
        if request_id in command_results:
            return True, command_results[request_id]
        # 処理できない命令を成功扱いにしない
        if command in ("borrow", "start") and not body_enabled:
            result = f"ACK:{request_id}:ERROR:モニ太本体が停止中です"
        elif command == "start" and not is_borrowed:
            result = f"ACK:{request_id}:ERROR:未貸出です"
        elif command == "acknowledge" and not (is_borrowed and is_monitoring()):
            result = f"ACK:{request_id}:ERROR:見守り中ではありません"
        else:
            handled = await process_command(command)
            result = f"ACK:{request_id}:" + ("OK" if handled else "ERROR:処理できません")
        command_results[request_id] = result
        if len(command_results) > COMMAND_CACHE_LIMIT:
            command_results.pop(next(iter(command_results)))
        return True, result



def current_network_info_message():
    """Bluetooth経由でスマホへ現在のPiのIPv4アドレスを返す。"""
    addresses = []
    try:
        # NetworkManagerから接続中のインターフェースのIPv4アドレスを取得する。
        result = subprocess.run(
            ["/usr/bin/nmcli", "-g", "IP4.ADDRESS", "device", "show", "wlan0"],
            capture_output=True, text=True, timeout=4, check=False,
        )
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                ip = line.strip().split("/", 1)[0]
                try:
                    socket.inet_aton(ip)
                    if ip and ip not in addresses and not ip.startswith("127."):
                        addresses.append(ip)
                except OSError:
                    pass
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"[WARNING] IPアドレス取得失敗: {error}")
    return "NETINFO:" + json.dumps({"ipv4": addresses}, ensure_ascii=False)


def current_state_message():
    """現在の貸出・見守り・異常状態を文字列にする。"""
    return (
        f"STATE,{int(is_borrowed)},"
        f"{int(is_monitoring())},{int(warning_active)}"
    )


def send_bluetooth_message(client, message):
    """Bluetooth接続中の端末へ1行のメッセージを送る。"""
    try:
        client.sendall((message + "\n").encode("utf-8"))
        return True
    except OSError:
        return False


def broadcast_bluetooth_message(message):
    """接続中のすべてのBluetooth端末へ状態を通知する。"""
    with bluetooth_clients_lock:
        clients = tuple(bluetooth_clients)

    for client in clients:
        if not send_bluetooth_message(client, message):
            with bluetooth_clients_lock:
                bluetooth_clients.discard(client)

            try:
                client.close()
            except OSError:
                pass


# ---------------------------------------------------------
# Bluetooth経由の管理操作
# 管理命令はBluetooth接続からだけ受け付ける。
# ---------------------------------------------------------

def run_admin_command(request):
    """管理者アプリからの要求を処理する。"""
    global body_enabled, warning_active
    action = request.get("action", "")
    try:
        if action == "body_status":
            return {"ok": True, "message": "起動中" if body_enabled else "停止中"}
        if action == "body_action":
            operation = request.get("operation")
            if operation not in ("start", "stop"):
                raise ValueError("本体操作が不正です")
            body_enabled = operation == "start"
            if not body_enabled:
                warning_active = False
                set_monitoring_state(False)
            return {"ok": True, "message": "本体を起動しました" if body_enabled else "本体を停止しました"}
        if action in ("wifi_status", "wifi_saved"):
            # Wi-Fiの接続状態とNetworkManagerに保存された接続先を取得する。
            active = subprocess.run(
                ["/usr/bin/nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"],
                capture_output=True, text=True, timeout=8, check=False,
            )
            if active.returncode:
                raise RuntimeError(active.stderr.strip() or "Wi-Fi状態を取得できません")
            ssid = None
            for line in active.stdout.splitlines():
                if line.startswith("wlan0:"):
                    fields = __import__("re").split(r"(?<!\\):", line)
                    if len(fields) >= 4 and fields[2] == "connected":
                        ssid = ":".join(fields[3:]).replace(r"\:", ":")
                    break
            profiles = subprocess.run(
                ["/usr/bin/nmcli", "-t", "-f", "UUID,TYPE,NAME", "connection", "show"],
                capture_output=True, text=True, timeout=8, check=False,
            )
            if profiles.returncode:
                raise RuntimeError(profiles.stderr.strip() or "保存済みWi-Fiを取得できません")
            saved = []
            for line in profiles.stdout.splitlines():
                fields = __import__("re").split(r"(?<!\\):", line, maxsplit=2)
                if len(fields) == 3 and fields[1] in ("802-11-wireless", "wifi"):
                    saved.append({"uuid": fields[0], "ssid": fields[2].replace(r"\:", ":")})
            with bluetooth_clients_lock:
                bt_connected = bool(bluetooth_clients)
            return {"ok": True, "message": "通信状態を取得しました", "ssid": ssid,
                    "ip": (json.loads(current_network_info_message()[8:])["ipv4"] or [None])[0], "bluetooth_connected": bt_connected,
                    "saved": saved}
        if action == "wifi_saved_connect":
            uuid = request.get("uuid", "")
            if not isinstance(uuid, str) or not __import__("re").fullmatch(r"[0-9a-fA-F-]{36}", uuid):
                raise ValueError("登録済みWi-Fiの識別子が不正です")
            result = subprocess.run(
                ["/usr/bin/nmcli", "--wait", "25", "connection", "up", "uuid", uuid, "ifname", "wlan0"],
                capture_output=True, text=True, timeout=35, check=False,
            )
            return {"ok": result.returncode == 0, "message": result.stdout.strip() or result.stderr.strip() or "接続しました"}
        if action == "wifi_saved_delete":
            uuid = request.get("uuid", "")
            if not isinstance(uuid, str) or not __import__("re").fullmatch(r"[0-9a-fA-F-]{36}", uuid):
                raise ValueError("登録済みWi-Fiの識別子が不正です")
            result = subprocess.run(
                ["/usr/bin/nmcli", "connection", "delete", "uuid", uuid],
                capture_output=True, text=True, timeout=12, check=False,
            )
            return {"ok": result.returncode == 0, "message": result.stdout.strip() or result.stderr.strip() or "削除しました"}
        if action == "wifi_scan":
            result = subprocess.run(
                ["/usr/bin/nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "yes"],
                capture_output=True, text=True, timeout=20, check=False,
            )
            if result.returncode:
                raise RuntimeError(result.stderr.strip() or "Wi-Fiを検索できません")
            networks = []
            for line in result.stdout.splitlines():
                # nmcli -t はコロンをエスケープするため、SSID内のコロンを保護する
                fields = __import__("re").split(r"(?<!\\):", line)
                if len(fields) >= 4 and fields[1] and fields[1] not in [n["ssid"] for n in networks]:
                    networks.append({"ssid": fields[1].replace(r"\:", ":"), "signal": fields[2], "security": fields[3]})
            return {"ok": True, "networks": networks}
        if action == "wifi_connect":
            ssid = request.get("ssid", "")
            password = request.get("password", "")
            if not isinstance(ssid, str) or not ssid or len(ssid) > 32 or not isinstance(password, str) or len(password) > 128:
                raise ValueError("SSIDまたはパスワードが不正です")
            command = ["/usr/bin/nmcli", "--wait", "25", "device", "wifi", "connect", ssid]
            if password:
                command.extend(["password", password])
            result = subprocess.run(command, capture_output=True, text=True, timeout=35, check=False)
            return {"ok": result.returncode == 0, "message": result.stdout.strip() or result.stderr.strip() or "接続を試しました"}
        if action == "service_status":
            service = request.get("service", "")
            if service not in ("return",):
                raise ValueError("本体はbody_actionで操作してください")
            unit = "monita-return.service"
            result = subprocess.run(["/usr/bin/systemctl", "is-active", unit], capture_output=True, text=True, timeout=5, check=False)
            return {"ok": True, "message": result.stdout.strip() or "unknown"}
        if action == "service_action":
            service = request.get("service", "")
            operation = request.get("operation", "")
            if service not in ("monita", "return") or operation not in ("start", "stop"):
                raise ValueError("操作が不正です")
            unit = "monita.service" if service == "monita" else "monita-return.service"
            # 自分自身の停止はBluetooth接続も切断するため、アプリ側で確認する
            result = subprocess.run(["/usr/bin/systemctl", "--no-block", operation, unit], capture_output=True, text=True, timeout=10, check=False)
            return {"ok": result.returncode == 0, "message": result.stderr.strip() or result.stdout.strip() or "命令を送信しました"}
        if action == "shutdown":
            # 応答を送る時間を確保してからシャットダウンする
            def shutdown_later():
                time.sleep(2)
                subprocess.run(["/usr/sbin/shutdown", "-h", "now"], check=False)
            threading.Thread(target=shutdown_later, daemon=True).start()
            return {"ok": True, "message": "シャットダウンを開始します"}
        raise ValueError("未対応の管理命令です")
    except (OSError, subprocess.TimeoutExpired, ValueError, RuntimeError) as error:
        return {"ok": False, "message": str(error)}


# ---------------------------------------------------------
# WebSocketフレーム処理
# ---------------------------------------------------------

def create_handshake_response(headers):
    """WebSocketの接続応答を作成する。"""
    key = headers.get("sec-websocket-key", "").strip()

    if not key:
        raise ValueError("WebSocketキーがありません")

    guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    accept_key = base64.b64encode(
        hashlib.sha1((key + guid).encode("utf-8")).digest()
    ).decode("ascii")

    return (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Accept: {accept_key}\r\n"
        "\r\n"
    ).encode("ascii")


async def read_websocket_frame(reader):
    """WebSocketフレームを読み取る。"""
    header = await reader.readexactly(2)

    opcode = header[0] & 0x0F
    masked = bool(header[1] & 0x80)
    payload_length = header[1] & 0x7F

    if payload_length == 126:
        payload_length = int.from_bytes(
            await reader.readexactly(2), "big"
        )
    elif payload_length == 127:
        payload_length = int.from_bytes(
            await reader.readexactly(8), "big"
        )

    if payload_length > 1024 * 1024:
        raise ValueError("WebSocketデータが大きすぎます")

    mask = await reader.readexactly(4) if masked else None
    payload = await reader.readexactly(payload_length)

    if mask is not None:
        payload = bytes(
            byte ^ mask[i % 4] for i, byte in enumerate(payload)
        )

    return opcode, payload


def encode_control_frame(opcode, payload=b""):
    """WebSocket制御フレームを作成する。"""
    if len(payload) > 125:
        raise ValueError("制御フレームが大きすぎます")

    return bytes([0x80 | opcode, len(payload)]) + payload


def encode_frame(message):
    """WebSocket送信用のテキストフレームを作成する。"""
    data = message.encode("utf-8")
    length = len(data)
    header = bytearray([0x81])

    if length <= 125:
        header.append(length)
    elif length <= 65535:
        header.append(126)
        header.extend(length.to_bytes(2, "big"))
    else:
        header.append(127)
        header.extend(length.to_bytes(8, "big"))

    return bytes(header) + data


async def send_sensor_status(message):
    """WebSocketとBluetoothの両方へ状態を通知する。"""
    disconnected = set()

    for writer in tuple(connected_clients):
        try:
            writer.write(encode_frame(message))
            await writer.drain()
        except Exception as e:
            print(f"[WARNING] WebSocket送信失敗: {e}")
            disconnected.add(writer)

    for writer in disconnected:
        connected_clients.discard(writer)
        writer.close()

    # Bluetoothには改行区切りのテキストとして送る
    broadcast_bluetooth_message(message)


async def send_current_state(writer):
    """WebSocket接続先へ現在の状態を送る。"""
    message = current_state_message()

    try:
        writer.write(encode_frame(message))
        await writer.drain()
        print(f"現在の状態を送信: {message}")
    except Exception as e:
        print(f"[WARNING] 状態送信失敗: {e}")


async def broadcast_current_state():
    """両通信方式の接続先へ現在の状態を送る。"""
    await send_sensor_status(current_state_message())


# ---------------------------------------------------------
# 共通命令処理
# ---------------------------------------------------------

async def process_command(message):
    """WebSocketとBluetoothで共通の命令を処理する。"""
    global is_borrowed, warning_active

    if message == "borrow" and not body_enabled:
        print("[WARNING] モニ太本体が停止中です")
        return True
    if message == "start" and not body_enabled:
        print("[WARNING] モニ太本体が停止中です")
        return True

    if message == "borrow":
        if not is_borrowed:
            is_borrowed = True
            warning_active = False
            set_monitoring_state(False)
            save_rental_state()
            print("スマホ命令：貸出状態を保存しました")

            # 貸し出し確定時にMP3を再生
            play_mp3("borrow.mp3")
        else:
            print("スマホ命令：貸出状態を維持")

        return True

    if message == "status":
        return True

    if message == "return":
        return await return_monita()

    if message == "start":
        if not is_borrowed:
            print("[WARNING] 未貸出のため見守りを開始できません")
            return True

        warning_active = False
        set_monitoring_state(True)
        print("スマホ命令：見守り開始")
        return True

    if message == "stop":
        warning_active = False
        set_monitoring_state(False)
        print("スマホ命令：見守り停止")
        return True

    if message == "acknowledge":
        if is_borrowed and is_monitoring():
            print("スマホ命令：異常確認・監視リセット")

            warning_active = False
            set_monitoring_state(False)
            await broadcast_current_state()

            await asyncio.sleep(0.3)

            if is_borrowed:
                set_monitoring_state(True)
                print("センサー監視を再スタートしました")
            else:
                print("[WARNING] 返却済みのため監視を再開しません")
        else:
            print("[WARNING] 見守り中ではないためリセットしません")

        return True

    print(f"未対応の命令: {message}")
    return False


# ---------------------------------------------------------
# 返却処理
# ---------------------------------------------------------

async def return_monita():
    """返却状態に統一し、接続中のアプリへ返却完了を通知する。"""
    global is_borrowed, warning_active

    was_borrowed = is_borrowed

    # すでに未貸出でも返却処理を完了できるようにする
    is_borrowed = False
    warning_active = False
    set_monitoring_state(False)

    # 未貸出状態を保存する
    save_rental_state()

    # 返却処理完了時にMP3を再生
    play_mp3("return.mp3")

    if was_borrowed:
        print("返却処理：貸出状態を解除しました")
    else:
        print("返却処理：すでに未貸出です。返却状態を再設定します")

    # Sense HATを未貸出の表示に戻す
    try:
        await asyncio.get_running_loop().run_in_executor(
            None, show_unborrowed
        )
    except Exception as e:
        print(f"[WARNING] Sense HAT更新失敗: {e}")

    # 接続中のアプリへ返却完了を通知する
    await send_sensor_status("RETURNED")

    # 最新の状態を通知する
    await broadcast_current_state()

    return True


# ---------------------------------------------------------
# 返却サーバー用HTTP受付
#
# 将来の返却箱連携用として残している。
# 現段階のユーザーアプリの返却処理では使用しない。
# ---------------------------------------------------------

async def send_http_response(writer, status, data):
    """返却サーバーへHTTP形式の結果を返す。"""
    reason = {
        200: "OK",
        400: "Bad Request",
        404: "Not Found",
        409: "Conflict",
        500: "Internal Server Error",
    }.get(status, "Error")

    body = json.dumps(
        data, ensure_ascii=False
    ).encode("utf-8")

    head = (
        f"HTTP/1.1 {status} {reason}\r\n"
        "Content-Type: application/json; charset=utf-8\r\n"
        f"Content-Length: {len(body)}\r\n"
        "Connection: close\r\n"
        "\r\n"
    ).encode("ascii")

    writer.write(head + body)
    await writer.drain()


async def handle_return_control(reader, writer):
    """将来の返却サーバー連携用HTTP返却命令を受け付ける。"""
    try:
        request_head = await asyncio.wait_for(
            reader.readuntil(b"\r\n\r\n"), timeout=5
        )

        request_text = request_head.decode(
            "utf-8", errors="replace"
        )
        request_line = request_text.split("\r\n", 1)[0]
        parts = request_line.split()

        if len(parts) != 3:
            await send_http_response(
                writer, 400,
                {
                    "success": False,
                    "message": "不正なリクエストです",
                },
            )
            return

        method, path, _ = parts

        if method != "POST" or path != "/return":
            await send_http_response(
                writer, 404,
                {
                    "success": False,
                    "message": "対象の処理がありません",
                },
            )
            return

        headers = {}

        for line in request_text.split("\r\n")[1:]:
            if ":" in line:
                key, value = line.split(":", 1)
                headers[key.strip().lower()] = value.strip()

        content_length = int(headers.get("content-length", "0"))

        if content_length < 0 or content_length > 1024:
            await send_http_response(
                writer, 400,
                {
                    "success": False,
                    "message": "リクエストサイズが不正です",
                },
            )
            return

        if content_length:
            await asyncio.wait_for(
                reader.readexactly(content_length), timeout=5
            )

        await send_http_response(
            writer, 409,
            {
                "success": False,
                "message": "返却サーバーとの連携は現在保留中です",
            },
        )

    except (asyncio.TimeoutError, asyncio.IncompleteReadError):
        print("[WARNING] 返却通信がタイムアウトしました")

    except Exception as e:
        print(f"[ERROR] 返却処理に失敗: {e}")

        try:
            await send_http_response(
                writer, 500,
                {
                    "success": False,
                    "message": "返却処理に失敗しました",
                },
            )
        except Exception:
            pass

    finally:
        writer.close()

        try:
            await writer.wait_closed()
        except Exception:
            pass


# ---------------------------------------------------------
# センサー監視
# ---------------------------------------------------------

async def monitor_sensor():
    """センサー監視とSense HATの表示を管理する。"""
    global warning_active

    previous_display = None
    loop = asyncio.get_running_loop()

    while True:
        if not body_enabled:
            warning_active = False
            if previous_display != "off":
                await loop.run_in_executor(None, sense.clear, 0, 0, 0)
                previous_display = "off"
            await asyncio.sleep(0.2)
            continue

        if not is_borrowed:
            warning_active = False

            if previous_display != "unborrowed":
                await loop.run_in_executor(
                    None, show_unborrowed
                )
                previous_display = "unborrowed"

            await asyncio.sleep(0.1)
            continue

        if not is_monitoring():
            warning_active = False

            if previous_display != "borrowed":
                await loop.run_in_executor(
                    None, show_borrowed
                )
                previous_display = "borrowed"

            await asyncio.sleep(0.1)
            continue

        try:
            status, gyro_motion, horizontal_acc = (
                await loop.run_in_executor(
                    None, get_sensor_signal
                )
            )

            if not is_borrowed or not is_monitoring():
                await asyncio.sleep(0.1)
                continue

            print(
                f"[LSM9DS1] Gyro: {gyro_motion:.2f} deg/s | "
                f"Accel: {horizontal_acc:.2f} G | "
                f"Status: {status}"
            )

            if status == "Warning":
                warning_active = True

            if warning_active:
                if previous_display != "warning":
                    await loop.run_in_executor(
                        None, show_warning
                    )
                    previous_display = "warning"
            else:
                if previous_display != "monitoring":
                    await loop.run_in_executor(
                        None, show_monitoring
                    )
                    previous_display = "monitoring"

            await send_sensor_status(
                f"{status},{gyro_motion:.2f},{horizontal_acc:.2f}"
            )
            await broadcast_current_state()

        except Exception as e:
            print(f"[ERROR] LSM9DS1読み取り失敗: {e}")

        await asyncio.sleep(0.1)


# ---------------------------------------------------------
# WebSocketクライアント処理
# ---------------------------------------------------------

async def handle_client(reader, writer):
    """AndroidアプリなどのWebSocket接続を処理する。"""
    client_addr = writer.get_extra_info("peername")

    if client_addr:
        print(f"[接続あり] クライアントIP: {client_addr[0]}")

    try:
        request_data = await asyncio.wait_for(
            reader.readuntil(b"\r\n\r\n"), timeout=5
        )
        request_text = request_data.decode(
            "utf-8", errors="ignore"
        )

        headers = {}

        for line in request_text.split("\r\n")[1:]:
            if ":" in line:
                key, value = line.split(":", 1)
                headers[key.strip().lower()] = value.strip()

        if (
            headers.get("upgrade", "").lower() != "websocket"
            or "upgrade" not in headers.get(
                "connection", ""
            ).lower()
            or not headers.get("sec-websocket-key")
        ):
            raise ValueError("WebSocketハンドシェイクが不正です")

        writer.write(create_handshake_response(headers))
        await writer.drain()

        connected_clients.add(writer)
        print("[接続完了] WebSocket")

        await send_current_state(writer)

        while True:
            opcode, payload = await read_websocket_frame(reader)

            if opcode == 8:
                try:
                    writer.write(
                        encode_control_frame(8, payload[:125])
                    )
                    await writer.drain()
                except Exception:
                    pass

                break

            if opcode == 9:
                writer.write(encode_control_frame(10, payload))
                await writer.drain()
                continue

            if opcode != 1:
                continue

            message = payload.decode(
                "utf-8", errors="ignore"
            ).strip()

            print(f"スマホから受信した命令: {message}")

            handled, reply = await execute_app_command(message)
            if reply is not None:
                writer.write(encode_frame(reply))
                await writer.drain()
            if handled:
                await send_current_state(writer)

    except asyncio.IncompleteReadError:
        pass

    except asyncio.TimeoutError:
        print("[ERROR] WebSocket接続がタイムアウトしました")

    except Exception:
        traceback.print_exc()

    finally:
        connected_clients.discard(writer)
        writer.close()

        try:
            await writer.wait_closed()
        except Exception:
            pass

        print("WebSocketクライアントが切断しました")


# ---------------------------------------------------------
# Bluetooth Classic RFCOMMサーバー
# ---------------------------------------------------------

def handle_bluetooth_client(client, address, loop):
    """Bluetooth端末からの命令を受け付けるスレッド。"""
    print(f"[接続完了] Bluetooth: {address}")

    with bluetooth_clients_lock:
        bluetooth_clients.add(client)

    send_bluetooth_message(
        client, current_state_message()
    )

    buffer = b""

    try:
        while True:
            data = client.recv(1024)

            if not data:
                break

            buffer += data

            while b"\n" in buffer:
                raw_message, buffer = buffer.split(b"\n", 1)

                message = raw_message.decode(
                    "utf-8", errors="replace"
                ).strip()

                if not message:
                    continue

                # Bluetoothで現在のIPアドレスを通知する。Wi-Fiがなくても応答可能。
                if message == "NETINFO":
                    send_bluetooth_message(client, current_network_info_message())
                    continue

                # 管理要求はBluetooth限定。Wi-Fi側からは実行できない。
                if message.startswith("ADMIN:"):
                    try:
                        request = json.loads(message[6:])
                        if not isinstance(request, dict):
                            raise ValueError("管理要求が不正です")
                        request_id = request.get("id")
                        response = run_admin_command(request)
                        response["id"] = request_id
                    except (ValueError, json.JSONDecodeError) as error:
                        response = {"ok": False, "message": str(error), "id": None}
                    send_bluetooth_message(client, "ADMIN_RESULT:" + json.dumps(response, ensure_ascii=False))
                    continue

                print(f"Bluetoothから受信した命令: {message}")

                future = asyncio.run_coroutine_threadsafe(
                    execute_app_command(message), loop
                )

                try:
                    should_reply, reply = future.result(timeout=10)

                    if reply is not None:
                        send_bluetooth_message(client, reply)
                    if should_reply:
                        send_bluetooth_message(client, current_state_message())

                except Exception as e:
                    print(
                        f"[WARNING] Bluetooth命令処理失敗: {e}"
                    )

    except OSError as e:
        print(f"[WARNING] Bluetooth通信終了: {e}")

    finally:
        with bluetooth_clients_lock:
            bluetooth_clients.discard(client)

        try:
            client.close()
        except OSError:
            pass

        print("Bluetoothクライアントが切断しました")


def ensure_bluetooth_serial_service():
    """SDPにRFCOMMチャンネル3のSerial Portサービスを登録する。"""
    # sdptoolの登録はBluetoothデーモンの再起動で消えるため、起動時に確認する。
    result = subprocess.run(
        ["/usr/bin/sdptool", "browse", "local"],
        capture_output=True, text=True, timeout=15,
    )
    if result.returncode != 0:
        raise RuntimeError(f"SDP確認失敗: {result.stderr.strip()}")

    # Serial Portサービスのレコードだけを確認し、チャンネル3の重複登録を防ぐ。
    records = result.stdout.split("Service Name:")
    for record in records[1:]:
        if record.startswith(" Serial Port\n") and "Channel: 3" in record:
            print("Bluetooth SDP: Serial Port（チャンネル3）は登録済み")
            return

    registered = subprocess.run(
        ["/usr/bin/sdptool", "add", "--channel=3", "SP"],
        capture_output=True, text=True, timeout=15,
    )
    if registered.returncode != 0 or "registered" not in registered.stdout.lower():
        raise RuntimeError(
            "Bluetooth SDP登録失敗: "
            + (registered.stderr.strip() or registered.stdout.strip())
        )
    print("Bluetooth SDP: Serial Port（チャンネル3）を登録しました")


def bluetooth_server_thread(loop):
    """Bluetooth Classic RFCOMMのチャンネル3で接続を受け付ける。"""
    global bluetooth_server_socket

    if bluetooth is None:
        print("[WARNING] PyBluezがないためBluetoothサーバーを起動できません")
        return

    server = None
    try:
        # PyBluezのadvertise_serviceはこの環境で失敗するため使用しない。
        # AndroidのSerial Port Profile接続と一致する固定チャンネルを使う。
        server = bluetooth.BluetoothSocket(bluetooth.RFCOMM)
        bluetooth_server_socket = server
        server.bind(("B8:27:EB:E8:32:44", BLUETOOTH_RFCOMM_CHANNEL))
        server.listen(5)

        ensure_bluetooth_serial_service()
        print(f"Bluetooth Classicサーバー起動: RFCOMMチャンネル{BLUETOOTH_RFCOMM_CHANNEL}")
        print(f"Bluetoothサービス: Serial Port / UUID {BLUETOOTH_SERVICE_UUID}")

        while True:
            client, address = server.accept()
            threading.Thread(
                target=handle_bluetooth_client,
                args=(client, address, loop),
                daemon=True,
            ).start()
    except Exception as e:
        print(f"[ERROR] Bluetoothサーバー起動・通信失敗: {e}")
    finally:
        if server is not None:
            try:
                server.close()
            except OSError:
                pass


# ---------------------------------------------------------
# メイン処理
# ---------------------------------------------------------

async def main():
    """WebSocket・Bluetooth・返却受付・センサー監視を起動する。"""
    global is_borrowed, warning_active, body_enabled

    loop = asyncio.get_running_loop()

    if not init_lsm9ds1():
        print(
            "[WARNING] LSM9DS1を初期化できません。"
            "センサー読み取りを継続します。"
        )

    # 再起動後も保存済みの貸出状態を復元する
    is_borrowed = load_rental_state()

    # 起動直後は通信だけ動作させ、本体機能を停止する
    body_enabled = False
    warning_active = False
    set_monitoring_state(False)

    await loop.run_in_executor(None, sense.clear, 0, 0, 0)
    print("モニ太本体：停止中（通信のみ待機）")

    # Androidアプリ用WebSocketサーバー
    server = await asyncio.start_server(
        handle_client, "0.0.0.0", SERVER_PORT
    )

    # 将来の返却サーバー連携用受付口
    return_server = await asyncio.start_server(
        handle_return_control,
        "127.0.0.1",
        RETURN_CONTROL_PORT,
    )

    # Bluetooth Classicサーバーを別スレッドで起動
    threading.Thread(
        target=bluetooth_server_thread,
        args=(loop,),
        daemon=True,
    ).start()

    print(f"WebSocketサーバー起動: {SERVER_PORT}")
    print(
        f"返却連携用受付: 127.0.0.1:{RETURN_CONTROL_PORT}"
        "（現在は保留）"
    )

    asyncio.create_task(monitor_sensor())

    async with server, return_server:
        await asyncio.gather(
            server.serve_forever(),
            return_server.serve_forever(),
        )


# ---------------------------------------------------------
# 終了処理
# ---------------------------------------------------------

def handle_shutdown_signal(signum, frame):
    """停止シグナルを受け取ったら終了処理を実行する。"""
    raise SystemExit(0)


if __name__ == "__main__":
    # systemdから停止されたときも終了処理を実行する
    signal.signal(signal.SIGTERM, handle_shutdown_signal)

    try:
        asyncio.run(main())

    except KeyboardInterrupt:
        print("プログラムを終了します")

    finally:
        # 見守りを停止状態にする
        try:
            set_monitoring_state(False)
        except Exception:
            pass

        # Sense HATのLEDをすべて消灯する
        try:
            sense.clear(0, 0, 0)
        except Exception:
            pass

        # I2Cバスを閉じる
        try:
            bus.close()
        except Exception:
            pass
