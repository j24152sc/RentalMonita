import subprocess
from pathlib import Path
class SpeakerController:
    def __init__(self,sounds_dir):self.sounds_dir=Path(sounds_dir)
    def play(self,filename):
        p=self.sounds_dir/filename
        if not p.is_file():return False
        try:subprocess.Popen(['aplay',str(p)],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);return True
        except OSError:return False