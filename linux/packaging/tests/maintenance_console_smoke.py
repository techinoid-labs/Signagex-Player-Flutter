"""Run with xvfb-run on Ubuntu. No root, network changes, SSH or real terminal."""
import importlib.machinery
import importlib.util
import pathlib
import sys
import traceback
from unittest.mock import patch

import gi
gi.require_version('Gtk', '3.0')
gi.require_version('Gdk', '3.0')
from gi.repository import Gdk, GLib, Gtk

path = pathlib.Path(__file__).parents[1]/'maintenance-console'
loader = importlib.machinery.SourceFileLoader('console_smoke', str(path))
spec = importlib.util.spec_from_loader('console_smoke', loader)
console = importlib.util.module_from_spec(spec)
loader.exec_module(console)
console.connections = lambda: 'signage-x86-test\nNo network connection (offline test)'
console.nearby_networks = lambda: ['Office Wi-Fi', 'Café guest']
requests, terminals, failures = [], [], []


def request(value):
    requests.append(value)
    return {'phase': 'applied', 'detail': 'Test operation completed'}


console.helper_request = request
stage, ticks = 0, 0


def step():
    global stage, ticks
    ticks += 1
    try:
        assert ticks < 150, 'Console timed out'
        app = Gtk.Application.get_default()
        if app is None or app.window is None or app.busy:
            return True
        if stage == 0:
            assert not app.controls.get_visible(), 'Protected controls visible before PIN'
            app.pin_entry.set_text('7348259061')
            app.unlock()
        elif stage == 1:
            assert app.controls.get_visible(), 'Unlock failed'
            app.scan()
        elif stage == 2:
            assert app.ssid.get_model()[0][0] == 'Office Wi-Fi'
            app.ssid.get_child().set_text('Office Wi-Fi')
            app.password.set_text('local-test-pass')
            app.connect_wifi()
        elif stage == 3:
            assert requests[-1]['op'] == 'wifi_connect'
            assert requests[-1]['ssid'] == 'Office Wi-Fi'
            assert app.password.get_text() == ''
            app.action('ssh_on')
        elif stage == 4:
            assert requests[-1]['op'] == 'ssh_on'
            app.terminal()
        elif stage == 5:
            assert terminals and terminals[0][0] == '/usr/bin/xterm'
            assert '/usr/bin/timeout' in terminals[0]
            assert 'sudo' not in terminals[0] and 'pkexec' not in terminals[0]
            assert app.pin == '' and not app.controls.get_visible()
            app.pin_entry.set_text('7348259061')
            app.unlock()
        elif stage == 6:
            # Capture the real GTK widget layout, then test automatic locking.
            destination = sys.argv[1] if len(sys.argv) > 1 else '/tmp/signagex-maintenance.png'
            window = app.window.get_window()
            Gdk.pixbuf_get_from_window(window, 0, 0, window.get_width(), window.get_height()).savev(destination, 'png', [], [])
            app.touched -= 121
            app.expire()
            assert app.pin == '' and not app.controls.get_visible()
            app.window.destroy()
            return False
        stage += 1
    except Exception:
        failures.append(traceback.format_exc())
        if Gtk.Application.get_default():
            Gtk.Application.get_default().quit()
        return False
    return True


GLib.timeout_add(100, step)
with patch.object(console.subprocess, 'Popen', side_effect=lambda args, **_: terminals.append(args)):
    console.main()
if failures:
    raise AssertionError('\n'.join(failures))
assert stage == 6, 'Console closed before completing the test'
print('GTK offline console: unlock, scan, connect, SSH action, restricted terminal and idle lock passed')
