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
    return {'phase': 'applied', 'detail': 'Test operation completed',
            'pointer_visible': value.get('visible', False)}


console.helper_request = request
stage, ticks = 0, 0


def check_keyboard_focus(app):
    # Traverse the real GTK focus chain in both directions without activating
    # network, SSH or terminal buttons. Include the combo's editable field.
    entry = app.ssid.get_child()
    entry.grab_focus()
    visited = []
    for _ in range(48):
        current = app.window.get_focus()
        if current is not None:
            visited.append(current)
            if isinstance(current, (Gtk.Entry, Gtk.Button, Gtk.CheckButton, Gtk.Label)):
                context = current.get_style_context()
                width = context.get_property('outline-width', Gtk.StateFlags.FOCUSED)
                assert width == 3, f'{type(current).__name__}: focus outline {width}, state {current.get_state_flags()}'
        app.window.child_focus(Gtk.DirectionType.TAB_FORWARD)
    for target in (entry, app.password, app.hidden, app.pointer):
        assert target in visited, 'Tab skipped a maintenance field'
    assert app.pin_entry not in visited, 'Hidden PIN field received focus'
    entry.grab_focus()
    app.window.child_focus(Gtk.DirectionType.TAB_FORWARD)
    app.window.child_focus(Gtk.DirectionType.TAB_BACKWARD)
    assert app.window.get_focus() == entry, 'Shift+Tab did not reverse focus order'


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
            check_keyboard_focus(app)
            app.pointer.grab_focus()
            app.pointer.set_active(True)
        elif stage == 2:
            assert requests[-1]['op'] == 'pointer' and requests[-1]['visible'] is True
            assert app.pointer.get_active()
            assert app.window.get_focus() == app.pointer, 'Action lost keyboard focus'
            destination = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/tmp/signagex-maintenance.png')
            window = app.window.get_window()
            Gdk.pixbuf_get_from_window(window, 0, 0, window.get_width(), window.get_height()).savev(str(destination.with_name(destination.stem+'-focus.png')), 'png', [], [])
            app.scan()
        elif stage == 3:
            assert app.ssid.get_model()[0][0] == 'Office Wi-Fi'
            app.ssid.get_child().set_text('Office Wi-Fi')
            app.password.set_text('local-test-pass')
            app.connect_wifi()
        elif stage == 4:
            assert requests[-1]['op'] == 'wifi_connect'
            assert requests[-1]['ssid'] == 'Office Wi-Fi'
            assert app.password.get_text() == ''
            app.action('ssh_on')
        elif stage == 5:
            assert requests[-1]['op'] == 'ssh_on'
            app.terminal()
        elif stage == 6:
            assert terminals and terminals[0][0] == '/usr/bin/xterm'
            assert '/usr/bin/timeout' in terminals[0]
            assert 'sudo' not in terminals[0] and 'pkexec' not in terminals[0]
            assert app.pin == '' and not app.controls.get_visible()
            app.pin_entry.set_text('7348259061')
            app.unlock()
        elif stage == 7:
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
assert stage == 7, 'Console closed before completing the test'
print('GTK offline console: Tab/Shift+Tab focus, visible focus styles, focus retention, unlock, cursor visibility, scan, connect, SSH action, restricted terminal and idle lock passed')
