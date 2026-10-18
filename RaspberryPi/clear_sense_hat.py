#!/usr/bin/python3

from sense_hat import SenseHat


def main():
    """Sense HATのLEDをすべて消灯する。"""
    sense = SenseHat()
    sense.clear(0, 0, 0)


if __name__ == "__main__":
    main()





sudo nano /etc/systemd/system/monita.service








[Unit]
Description=Rental Monita Sensor Monitoring
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/home/raspi6/raspi/monita
ExecStart=/usr/bin/python3 -u /home/raspi6/raspi/monita/monita.py
ExecStop=/usr/bin/python3 /home/raspi6/raspi/monita/clear_sense_hat.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
