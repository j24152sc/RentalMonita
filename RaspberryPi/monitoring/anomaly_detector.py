def detect_anomaly(state):
    if not state or not state.get('available'):return {'anomaly':False,'reason':'センサー未設定'}
    # TODO: 実際のセンサーに合わせて閾値と判定ロジックを実装する。
    return {'anomaly':False,'reason':'異常なし'}