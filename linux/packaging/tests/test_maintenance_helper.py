import importlib.machinery
import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch


def load(name, path):
    loader = importlib.machinery.SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


packaging = pathlib.Path(__file__).parents[1]
helper = load('maintenance_helper', packaging/'maintenance-helper')
installer = load('maintenance_installer', packaging/'kiosk/enable-maintenance.py')


class MaintenanceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.patches = [patch.object(helper, 'CONFIG', self.root/'etc/maintenance.json'),
                        patch.object(helper, 'STATE', self.root/'state'),
                        patch.object(helper.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=1001))]
        for item in self.patches:
            item.start()
        helper.configure('kiosk', '7348259061')

    def tearDown(self):
        for item in self.patches:
            item.stop()
        self.temp.cleanup()

    def request(self, op='unlock', **values):
        return {'op': op, 'pin': '7348259061', **values}

    def test_no_default_and_no_plaintext_pin(self):
        content = helper.CONFIG.read_text()
        self.assertNotIn('7348259061', content)
        self.assertEqual(helper.CONFIG.stat().st_mode & 0o777, 0o600)
        helper.CONFIG.unlink()
        with self.assertRaisesRegex(ValueError, 'not configured'):
            helper.dispatch(self.request(), 1001)

    def test_pin_and_bound_user_required_for_every_operation(self):
        for op in ('unlock', 'status', 'wifi_connect', 'ssh_on', 'ssh_off', 'terminal'):
            with self.subTest(op=op), patch.object(helper, 'command') as command:
                with self.assertRaisesRegex(ValueError, 'Incorrect'):
                    helper.dispatch(self.request(op, pin='12345678'), 1001)
                (helper.STATE/'attempts.json').unlink(missing_ok=True)
                with self.assertRaisesRegex(ValueError, 'not the configured'):
                    helper.dispatch(self.request(op), 1002)
                command.assert_not_called()

    def test_five_failed_attempts_lock_out_correct_pin_across_invocations(self):
        with patch.object(helper.time, 'time', return_value=1000):
            for _ in range(5):
                with self.assertRaises(ValueError):
                    helper.authenticate('11111111', 1001)
            with self.assertRaisesRegex(ValueError, 'five minutes'):
                helper.authenticate('7348259061', 1001)
        with patch.object(helper.time, 'time', return_value=1301):
            helper.authenticate('7348259061', 1001)
        self.assertFalse((helper.STATE/'attempts.json').exists())

    def test_no_arbitrary_shell_or_root_terminal(self):
        for op in ('shell', 'reboot', '/bin/bash', 'terminal; reboot'):
            with self.assertRaisesRegex(ValueError, 'Unsupported'):
                helper.dispatch(self.request(op, command='id'), 1001)
        with patch.object(helper.subprocess, 'run') as run:
            answer = helper.dispatch(self.request('terminal', command='sudo bash'), 1001)
            self.assertEqual(answer['phase'], 'applied')
            run.assert_not_called()

    def test_wifi_reuses_rollback_helper_without_pin_or_password_in_argv(self):
        answer = {'phase': 'failed', 'detail': 'Restored previous connection.'}
        with patch.object(helper.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0, json.dumps(answer), '')) as run:
            ssid = 'Office;$(touch /tmp/never)'
            result = helper.dispatch(self.request('wifi_connect', ssid=ssid, password='secret123'), 1001)
            args, kwargs = run.call_args
            self.assertEqual(args[0], [helper.NETWORK])
            request = json.loads(kwargs['input'])
            self.assertEqual(request['ssid'], ssid)
            self.assertEqual(request['password'], 'secret123')
            self.assertNotIn('pin', request)
            self.assertNotIn('7348259061', kwargs['input'])
            self.assertNotIn('shell', kwargs)
            self.assertEqual(result, answer)

    def test_wifi_helper_error_does_not_expose_stderr_or_credentials(self):
        with patch.object(helper.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'secret123')):
            with self.assertRaisesRegex(RuntimeError, 'Network helper unavailable') as failure:
                helper.dispatch(self.request('wifi_connect', ssid='Office', password='secret123'), 1001)
        self.assertNotIn('secret123', str(failure.exception))

    def test_ssh_countdown_is_armed_before_start_and_does_not_enable_on_boot(self):
        calls = []
        def command(args, **kwargs):
            calls.append(args)
            return subprocess.CompletedProcess(args, 3 if 'is-active' in args else 0, '', '')
        with patch.object(helper, 'command', side_effect=command):
            helper.dispatch(self.request('ssh_on'), 1001)
        timer = next(i for i, args in enumerate(calls) if args[0] == 'systemd-run')
        start = calls.index(['systemctl', 'start', 'ssh.service'])
        self.assertLess(timer, start)
        self.assertIn('--on-active=15m', calls[timer])
        self.assertFalse(any('enable' in args for args in calls))

    def test_failed_expiry_timer_never_starts_ssh(self):
        calls = []
        def command(args, **kwargs):
            calls.append(args)
            return subprocess.CompletedProcess(args, 1, '', '')
        with patch.object(helper, 'command', side_effect=command):
            with self.assertRaisesRegex(RuntimeError, 'not enabled'):
                helper.dispatch(self.request('ssh_on'), 1001)
        self.assertNotIn(['systemctl', 'start', 'ssh.service'], calls)

    def test_expiry_preserves_preexisting_admin_ssh_and_stops_new_service(self):
        helper.write_private(helper.STATE/'ssh-lease.json', {'active': {'ssh.socket': True, 'ssh.service': False}})
        calls = []
        def command(args, **kwargs):
            calls.append(args)
            return subprocess.CompletedProcess(args, 0, '', '')
        with patch.object(helper, 'command', side_effect=command):
            helper.expire_ssh()
        self.assertNotIn(['systemctl', 'stop', 'ssh.socket'], calls)
        self.assertIn(['systemctl', 'stop', 'ssh.service'], calls)

    def test_missing_inactive_socket_does_not_prevent_service_shutdown(self):
        calls = []
        def command(args, **kwargs):
            calls.append(args)
            return subprocess.CompletedProcess(args, 3 if 'is-active' in args and args[-1] == 'ssh.socket' else 0, '', '')
        with patch.object(helper, 'command', side_effect=command):
            helper.dispatch(self.request('ssh_off'), 1001)
        self.assertIn(['systemctl', 'stop', 'ssh.service'], calls)
        self.assertNotIn(['systemctl', 'stop', 'ssh.socket'], calls)

    def test_openbox_binding_is_idempotent_and_preserves_existing_bindings(self):
        path = self.root/'rc.xml'
        path.write_text('<openbox_config xmlns="http://openbox.org/3.4/rc"><keyboard>'
                        '<keybind key="C-A-t"><action name="Execute"><command>existing</command></action></keybind>'
                        '</keyboard></openbox_config>')
        installer.add_binding(path)
        installer.add_binding(path)
        self.assertEqual(path.read_text().count('key="C-A-m"'), 1)
        self.assertIn('existing', path.read_text())
        self.assertIn('/usr/bin/signagex-maintenance', path.read_text())


if __name__ == '__main__':
    unittest.main()
