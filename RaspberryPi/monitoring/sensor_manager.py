class SensorManager:
    def read_state(self):
        # 使用センサーが確定するまで、未設定を明示する。
        return {'available':False,'reason':'センサー未設定'}