import importlib.util, io, pathlib, types, unittest
from collections import namedtuple
from unittest.mock import patch

path = pathlib.Path(__file__).parents[1]/'kiosk/wayland_input.py'
spec = importlib.util.spec_from_file_location('wayland_input', path)
wi = importlib.util.module_from_spec(spec); spec.loader.exec_module(wi)

# A stand-in for evdev.ecodes, so the tests run without python3-evdev.
names = ['EV_SYN', 'SYN_REPORT', 'EV_KEY', 'EV_ABS', 'ABS_X', 'ABS_Y', 'BTN_LEFT', 'BTN_RIGHT', 'BTN_MIDDLE']
codes = {name: index for index, name in enumerate(names)}
class Codes(types.SimpleNamespace):
    def __getattr__(self, name):  # any KEY_* gets a stable number
        if name.startswith('KEY_'): return 1000 + sum(map(ord, name))
        raise AttributeError(name)
FakeCodes = Codes(**codes)
FakeAbsInfo = namedtuple('AbsInfo', 'value min max fuzz flat resolution')

class Device:
    def __init__(self, events, name): self.events, self.name, self.written, self.closed = events, name, [], False
    def write(self, *event): self.written.append(event)
    def close(self): self.closed = True

class WaylandInputTests(unittest.TestCase):
    def setUp(self):
        self.patches = [patch.object(wi, 'e', FakeCodes), patch.object(wi, 'AbsInfo', FakeAbsInfo)]
        for p in self.patches: p.start()
        self.devices = []
        def factory(events, name): device = Device(events, name); self.devices.append(device); return device
        self.input = wi.WaylandInput(factory=factory, sleep=lambda _: None)
    def tearDown(self):
        for p in self.patches: p.stop()

    def test_fractions_map_onto_the_whole_absolute_axis(self):
        self.assertEqual(wi.absolute(0), 0)
        self.assertEqual(wi.absolute(1), wi.ABS_MAX)
        self.assertEqual(wi.absolute('0.5'), round(wi.ABS_MAX/2))
        for bad in (-0.1, 1.1, float('nan'), 'x'):
            with self.assertRaises(ValueError): wi.absolute(bad)

    def test_pointer_is_an_absolute_mouse_not_a_touchscreen(self):
        self.input.tap(0.5, 0.25)
        pointer = self.devices[0]
        self.assertEqual(pointer.name, 'SignageX remote pointer')
        self.assertIn(FakeCodes.BTN_LEFT, pointer.events[FakeCodes.EV_KEY])
        axes = dict(pointer.events[FakeCodes.EV_ABS])
        self.assertEqual(axes[FakeCodes.ABS_X].max, wi.ABS_MAX)
        self.assertEqual(pointer.written[:3], [(FakeCodes.EV_ABS, FakeCodes.ABS_X, round(wi.ABS_MAX*0.5)),
                                               (FakeCodes.EV_ABS, FakeCodes.ABS_Y, round(wi.ABS_MAX*0.25)),
                                               (FakeCodes.EV_SYN, FakeCodes.SYN_REPORT, 0)])
        presses = [w for w in pointer.written if w[:2] == (FakeCodes.EV_KEY, FakeCodes.BTN_LEFT)]
        self.assertEqual([w[2] for w in presses], [1, 0])

    def test_device_is_created_once_and_reused(self):
        self.input.tap(0.1, 0.1); self.input.move(0.2, 0.2)
        self.assertEqual(len(self.devices), 1)
        self.input.close()
        self.assertTrue(self.devices[0].closed)

    def test_drag_always_releases_the_button(self):
        self.input.drag(0.1, 0.1, 0.9, 0.9, 100)
        presses = [w[2] for w in self.devices[0].written if w[:2] == (FakeCodes.EV_KEY, FakeCodes.BTN_LEFT)]
        self.assertEqual(presses, [1, 0])
        last_x = [w[2] for w in self.devices[0].written if w[:2] == (FakeCodes.EV_ABS, FakeCodes.ABS_X)][-1]
        self.assertEqual(last_x, round(wi.ABS_MAX*0.9))

    def test_typing_uses_shift_for_capitals_and_skips_what_it_cannot_type(self):
        skipped = self.input.type('Hi!é')
        self.assertEqual(skipped, 1)
        keyboard = self.devices[0]
        downs = [w[1] for w in keyboard.written if w[0] == FakeCodes.EV_KEY and w[2] == 1]
        self.assertEqual(downs[:2], [FakeCodes.KEY_LEFTSHIFT, FakeCodes.KEY_H])
        for bad in ('x'*513, 'a\0b', 5):
            with self.assertRaises(ValueError): self.input.type(bad)

    def test_key_combinations(self):
        self.assertEqual(wi.combo_keys('alt+Left'), ['KEY_LEFTALT', 'KEY_LEFT'])
        self.assertEqual(wi.combo_keys('ctrl+shift+a'), ['KEY_LEFTCTRL', 'KEY_LEFTSHIFT', 'KEY_A'])
        for bad in ('', 'hyper+Left', 'alt+NotAKey', 'a+b+c+d+e'):
            with self.assertRaises(ValueError): wi.combo_keys(bad)

    def test_command_line_reports_missing_pieces_and_reads_text_from_stdin(self):
        with patch.object(wi, 'missing', return_value='no uinput'):
            self.assertEqual(wi.main(['check']), 1)
            self.assertEqual(wi.main(['tap', '0.5', '0.5']), 1)
        typed = []
        class Fake:
            def __init__(self): pass
            def type(self, text): typed.append(text); return 0
            def close(self): pass
        with patch.object(wi, 'missing', return_value=None), patch.object(wi, 'WaylandInput', Fake), \
             patch.object(wi.time, 'sleep'):
            self.assertEqual(wi.main(['type'], stdin=io.StringIO('hello')), 0)
            self.assertEqual(wi.main(['bogus']), 2)
        self.assertEqual(typed, ['hello'])

if __name__ == '__main__': unittest.main()
