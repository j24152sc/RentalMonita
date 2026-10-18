class MonitoringController:
    def __init__(self,sensor,detector):self.sensor=sensor;self.detector=detector;self.active=False;self.last_anomaly=False
    def start(self):self.active=True;return {'monitoring':True}
    def stop(self):self.active=False;self.last_anomaly=False;return {'monitoring':False}
    def check(self):
        if not self.active:return {'monitoring':False,'anomaly':False}
        result=self.detector(self.sensor.read_state());self.last_anomaly=bool(result.get('anomaly'));return {'monitoring':True,**result}