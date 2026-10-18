
class SenseHatController:
    def __init__(self):
        try:
            from sense_hat import SenseHat
            self.sense = SenseHat()
        except Exception:
            self.sense = None

    def show_white(self):
        if self.sense:
            self.sense.clear(255, 255, 255)

    def show_warning(self):
        if self.sense:
            self.sense.clear(255, 40, 0)

    def clear(self):
        """Sense HAT‚ÌLED‚ğ‚·‚×‚ÄÁ“”‚·‚éB"""
        if self.sense:
            self.sense.clear(0, 0, 0)
