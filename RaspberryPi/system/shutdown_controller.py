import subprocess
def shutdown_pi3():
    return subprocess.run(['sudo','/usr/sbin/shutdown','-h','now'],check=False).returncode==0