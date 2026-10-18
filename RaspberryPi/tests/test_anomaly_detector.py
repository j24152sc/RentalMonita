from monitoring.anomaly_detector import detect_anomaly
def test_sensor_not_configured():
    assert detect_anomaly({'available':False})['anomaly'] is False