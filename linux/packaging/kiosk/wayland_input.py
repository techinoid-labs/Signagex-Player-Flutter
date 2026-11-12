#!/usr/bin/python3
"""Remote-view input for Wayland kiosks (cage), through uinput.

xdotool only reaches X11 clients, and relative tools such as ydotool are bent
by the compositor's pointer acceleration, which cage gives no way to turn off.
This creates the kind of device a virtual machine's "tablet" mouse is: an
absolute pointer (ABS_X/ABS_Y over the whole output, plus buttons) and a
keyboard. The compositor maps absolute pointer positions straight onto the
output, so a 0..1 fraction lands on the same pixel at any resolution or scale.

Needs python3-evdev and write access to /dev/uinput (the Wayland kiosk
installer adds a udev rule and the signagex-input group).

Command line (used by the Dart player; the remote-view adapter imports it):
  wayland_input.py check
  wayland_input.py tap X Y            X, Y are fractions 0..1 of the output
  wayland_input.py move X Y
  wayland_input.py drag X1 Y1 X2 Y2 [HOLD_MS]
  wayland_input.py type               text on stdin (never argv), max 512 chars
  wayland_input.py key alt+Left
Typed text and coordinates are never logged.
"""
import math, os, sys, time

try:
    from evdev import AbsInfo, UInput, ecodes as e
except ImportError:  # reported by `check`; the rest of the module still imports
    AbsInfo = UInput = e = None

ABS_MAX = 65535
MAX_TEXT = 512
# Time for the compositor to see a freshly created device before using it.
SETTLE_SECONDS = 0.4


def missing():
    """Why input can't work here, or None when it can."""
    if UInput is None:
        return 'python3-evdev is not installed (sudo apt install python3-evdev)'
    if not os.access('/dev/uinput', os.W_OK):
        return '/dev/uinput is not writable (run the Wayland kiosk installer, then log in again)'
    return None


def fraction(value):
    value = float(value)
    if not math.isfinite(value) or not 0 <= value <= 1:
        raise ValueError('coordinates must be fractions between 0 and 1')
    return value


def absolute(value):
    return int(round(fraction(value) * ABS_MAX))


# US keyboard layout: character -> (key name, shift).
_SHIFTED = {'!': '1', '@': '2', '#': '3', '$': '4', '%': '5', '^': '6', '&': '7', '*': '8',
            '(': '9', ')': '0', '_': 'MINUS', '+': 'EQUAL', '{': 'LEFTBRACE', '}': 'RIGHTBRACE',
            '|': 'BACKSLASH', ':': 'SEMICOLON', '"': 'APOSTROPHE', '<': 'COMMA', '>': 'DOT',
            '?': 'SLASH', '~': 'GRAVE'}
_PLAIN = {' ': 'SPACE', '-': 'MINUS', '=': 'EQUAL', '[': 'LEFTBRACE', ']': 'RIGHTBRACE',
          '\\': 'BACKSLASH', ';': 'SEMICOLON', "'": 'APOSTROPHE', ',': 'COMMA', '.': 'DOT',
          '/': 'SLASH', '`': 'GRAVE', '\n': 'ENTER', '\t': 'TAB'}


def key_for(char):
    """(KEY_ name, shift) for one character, or None if it can't be typed."""
    if 'a' <= char <= 'z': return 'KEY_' + char.upper(), False
    if 'A' <= char <= 'Z': return 'KEY_' + char, True
    if '0' <= char <= '9': return 'KEY_' + char, False
    if char in _PLAIN: return 'KEY_' + _PLAIN[char], False
    if char in _SHIFTED: return 'KEY_' + _SHIFTED[char], True
    return None


_MODIFIERS = {'alt': 'KEY_LEFTALT', 'ctrl': 'KEY_LEFTCTRL', 'control': 'KEY_LEFTCTRL',
              'shift': 'KEY_LEFTSHIFT', 'super': 'KEY_LEFTMETA'}
_NAMED = {'left': 'KEY_LEFT', 'right': 'KEY_RIGHT', 'up': 'KEY_UP', 'down': 'KEY_DOWN',
          'return': 'KEY_ENTER', 'enter': 'KEY_ENTER', 'escape': 'KEY_ESC', 'esc': 'KEY_ESC',
          'backspace': 'KEY_BACKSPACE', 'tab': 'KEY_TAB', 'home': 'KEY_HOME', 'end': 'KEY_END',
          'delete': 'KEY_DELETE', 'space': 'KEY_SPACE'}


def combo_keys(combo):
    """'alt+Left' -> ['KEY_LEFTALT', 'KEY_LEFT']."""
    parts = [part.strip().lower() for part in str(combo).split('+') if part.strip()]
    if not parts or len(parts) > 4: raise ValueError('invalid key combination')
    names = []
    for part in parts[:-1]:
        if part not in _MODIFIERS: raise ValueError('invalid modifier')
        names.append(_MODIFIERS[part])
    last = parts[-1]
    if last in _NAMED: names.append(_NAMED[last])
    elif len(last) == 1 and key_for(last): names.append(key_for(last)[0])
    else: raise ValueError('invalid key')
    return names


def _keyboard_keys():
    names = {'KEY_LEFTSHIFT', *(_MODIFIERS.values()), *(_NAMED.values())}
    for code in range(32, 127):
        found = key_for(chr(code))
        if found: names.add(found[0])
    names.update({'KEY_ENTER', 'KEY_TAB'})
    return sorted(names)


class WaylandInput:
    """One absolute pointer and one keyboard, created on first use and kept."""

    def __init__(self, factory=None, sleep=time.sleep, settle=SETTLE_SECONDS):
        self.factory = factory or UInput
        self.sleep, self.settle = sleep, settle
        self.pointer = self.keyboard = None

    def _code(self, name):
        return getattr(e, name)

    def _pointer(self):
        if self.pointer is None:
            if self.factory is None: raise RuntimeError(missing() or 'uinput unavailable')
            axis = AbsInfo(value=0, min=0, max=ABS_MAX, fuzz=0, flat=0, resolution=0)
            self.pointer = self.factory(
                {e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE],
                 e.EV_ABS: [(e.ABS_X, axis), (e.ABS_Y, axis)]},
                name='SignageX remote pointer')
            self.sleep(self.settle)
        return self.pointer

    def _keyboard(self):
        if self.keyboard is None:
            if self.factory is None: raise RuntimeError(missing() or 'uinput unavailable')
            self.keyboard = self.factory({e.EV_KEY: [self._code(name) for name in _keyboard_keys()]},
                                         name='SignageX remote keyboard')
            self.sleep(self.settle)
        return self.keyboard

    def _sync(self, device):
        device.write(e.EV_SYN, e.SYN_REPORT, 0)

    def move(self, x, y):
        device = self._pointer()
        device.write(e.EV_ABS, e.ABS_X, absolute(x))
        device.write(e.EV_ABS, e.ABS_Y, absolute(y))
        self._sync(device)

    def _button(self, down):
        device = self._pointer()
        device.write(e.EV_KEY, e.BTN_LEFT, 1 if down else 0)
        self._sync(device)

    def tap(self, x, y):
        self.move(x, y)
        self.sleep(0.03)
        self._button(True)
        self.sleep(0.04)
        self._button(False)

    def drag(self, x1, y1, x2, y2, hold_ms=150):
        hold = max(0, min(5000, int(hold_ms))) / 1000
        start, end = (fraction(x1), fraction(y1)), (fraction(x2), fraction(y2))
        self.move(*start)
        self.sleep(0.03)
        self._button(True)
        try:
            steps = 12
            for step in range(1, steps + 1):
                self.sleep(hold / steps)
                self.move(start[0] + (end[0] - start[0]) * step / steps,
                          start[1] + (end[1] - start[1]) * step / steps)
        finally:
            self._button(False)

    def _press(self, names):
        device = self._keyboard()
        codes = [self._code(name) for name in names]
        for code in codes:
            device.write(e.EV_KEY, code, 1)
        self._sync(device)
        for code in reversed(codes):
            device.write(e.EV_KEY, code, 0)
        self._sync(device)

    def type(self, text):
        """Types what the US layout can; returns how many characters were skipped."""
        if not isinstance(text, str) or len(text) > MAX_TEXT or '\0' in text:
            raise ValueError('invalid text')
        skipped = 0
        for char in text:
            found = key_for(char)
            if not found:
                skipped += 1
                continue
            name, shift = found
            self._press(['KEY_LEFTSHIFT', name] if shift else [name])
            self.sleep(0.004)
        return skipped

    def key(self, combo):
        self._press(combo_keys(combo))

    def close(self):
        for device in (self.pointer, self.keyboard):
            if device is not None:
                try: device.close()
                except Exception: pass
        self.pointer = self.keyboard = None


def main(argv, stdin=sys.stdin):
    if not argv: print(__doc__.strip().splitlines()[0], file=sys.stderr); return 2
    command, arguments = argv[0], argv[1:]
    reason = missing()
    if command == 'check':
        if reason: print(reason); return 1
        return 0
    if reason: print(reason, file=sys.stderr); return 1
    device = WaylandInput()
    try:
        if command == 'tap' and len(arguments) == 2: device.tap(*arguments)
        elif command == 'move' and len(arguments) == 2: device.move(*arguments)
        elif command == 'drag' and len(arguments) in (4, 5): device.drag(*arguments[:4], *(arguments[4:] or [150]))
        elif command == 'type' and not arguments:
            skipped = device.type(stdin.read(MAX_TEXT + 1))
            if skipped: print(f'{skipped} characters could not be typed on a US layout', file=sys.stderr)
        elif command == 'key' and len(arguments) == 1: device.key(arguments[0])
        else: print('invalid command', file=sys.stderr); return 2
        # Let the compositor read the last events before the device goes away.
        time.sleep(0.05)
        return 0
    except ValueError as error:
        print(str(error), file=sys.stderr); return 2
    finally:
        device.close()


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
