import importlib.machinery, importlib.util, json, pathlib, subprocess, tempfile, unittest
from unittest.mock import patch

path = pathlib.Path(__file__).parents[1]/'network-helper'
loader = importlib.machinery.SourceFileLoader('network_helper', str(path))
spec = importlib.util.spec_from_loader('network_helper', loader)
helper = importlib.util.module_from_spec(spec); loader.exec_module(helper)

def done(stdout='', code=0): return subprocess.CompletedProcess([], code, stdout, '')

class FakeNetworkManager:
    """Answers the nmcli calls the helper makes, from a small in-memory model."""
    def __init__(self, profiles, devices, gateways=None, up_ok=True):
        self.profiles, self.devices, self.gateways, self.up_ok = profiles, devices, gateways or {}, up_ok
        self.calls = []
    def __call__(self, *args, timeout=60):
        self.calls.append(args)
        if args[:5] == ('-t', '-f', 'UUID,TYPE,ACTIVE', 'connection', 'show'):
            return done('\n'.join(f"{u}:802-11-wireless:{'yes' if a else 'no'}" for u, (s, a) in self.profiles.items()))
        if args[:2] == ('-g', '802-11-wireless.ssid'):
            return done(self.profiles[args[-1]][0].replace(':', '\\:') + '\n')
        if args[:4] == ('-t', '-f', 'DEVICE,TYPE', 'device'):
            return done('\n'.join(f'{d}:{t}' for d, t, _ in self.devices))
        if args[:4] == ('-t', '-f', 'DEVICE,TYPE,STATE', 'device'):
            return done('\n'.join(f'{d}:{t}:{s}' for d, t, s in self.devices))
        if args[:2] == ('-g', 'IP4.GATEWAY'):
            return done(self.gateways.get(args[-1], ''))
        if args[:6] == ('-t', '-f', 'DEVICE,UUID', 'connection', 'show', '--active'):
            return done('\n'.join(f'wlp3s0:{u}' for u, (s, a) in self.profiles.items() if a))
        if args[:2] == ('connection', 'load'): return done()
        if args[:2] == ('connection', 'delete'):
            self.profiles.pop(args[2], None); return done()
        if 'up' in args: return done(code=0 if self.up_ok else 4)
        return done()

class ValidationTests(unittest.TestCase):
    def test_accepts_wpa_open_and_hex_passwords(self):
        for password in ('', 'correct horse', 'a' * 63, 'ab' * 32):
            self.assertEqual(helper.validate({'job': 'j-1', 'op': 'wifi_add', 'ssid': 'Office', 'password': password})['password'], password)
    def test_rejects_bad_input(self):
        bad = [{'job': 'j 1', 'op': 'wifi_add', 'ssid': 'x'}, {'job': 'j', 'op': 'rm -rf', 'ssid': 'x'},
               {'job': 'j', 'op': 'wifi_add', 'ssid': ''}, {'job': 'j', 'op': 'wifi_add', 'ssid': 'é' * 17},
               {'job': 'j', 'op': 'wifi_add', 'ssid': 'a\nb'}, {'job': 'j', 'op': 'wifi_add', 'ssid': 'x', 'password': 'short'},
               {'job': 'j', 'op': 'wifi_add', 'ssid': 'x', 'password': 'naïve-password'}, {'job': 'j', 'op': 'wifi_add', 'ssid': 'x', 'password': 'g' * 64}]
        for request in bad:
            with self.assertRaises(ValueError, msg=request): helper.validate(request)
    def test_remove_drops_any_password(self):
        self.assertEqual(helper.validate({'job': 'j', 'op': 'wifi_remove', 'ssid': 'x', 'password': 'secret123'})['password'], '')

class KeyfileTests(unittest.TestCase):
    def test_ssid_is_a_byte_list_and_password_is_escaped(self):
        text = helper.keyfile('Café;=[x]', ' pa\\ss', True, 'uuid-1')
        self.assertIn('ssid=' + ';'.join(str(b) for b in 'Café;=[x]'.encode()) + ';\n', text)
        self.assertIn('psk=\\spa\\\\ss\n', text)
        self.assertIn('hidden=true', text)
        self.assertIn('key-mgmt=wpa-psk', text)
    def test_open_network_has_no_security_section(self):
        self.assertNotIn('wifi-security', helper.keyfile('Guest', '', False, 'uuid-2'))
    def test_nmcli_fields_unescape(self):
        self.assertEqual(helper.fields('a\\:b:c\\\\d:'), ['a:b', 'c\\d', ''])

class ChangeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.profiles_dir = pathlib.Path(self.temporary.name)
        patch.object(helper, 'PROFILES', self.profiles_dir).start()
        patch.object(helper.time, 'sleep', lambda _: None).start()
    def tearDown(self):
        patch.stopall(); self.temporary.cleanup()
    def request(self, **changes):
        value = {'job': 'j', 'op': 'wifi_add', 'ssid': 'Office', 'password': 'secret123', 'hidden': False, 'connect': True}
        value.update(changes); return value

    def test_save_only_writes_root_only_profile_and_replaces_old_one(self):
        fake = FakeNetworkManager({'old': ('Office', False)}, [('enp2s0', 'ethernet', 'connected'), ('wlp3s0', 'wifi', 'disconnected')])
        with patch.object(helper, 'nmcli', fake):
            message = helper.add(self.request(connect=False))
        files = list(self.profiles_dir.iterdir())
        self.assertEqual(len(files), 1)
        self.assertEqual(files[0].stat().st_mode & 0o777, 0o600)
        self.assertIn('psk=secret123', files[0].read_text())
        self.assertNotIn('old', fake.profiles)
        self.assertIn('Saved', message)
        self.assertFalse(any('secret123' in ' '.join(call) for call in fake.calls), 'password must never reach a command line')

    def test_connect_succeeds_when_api_reachable(self):
        fake = FakeNetworkManager({}, [('wlp3s0', 'wifi', 'disconnected')])
        with patch.object(helper, 'nmcli', fake), patch.object(helper, 'reaches_api', lambda device: True):
            self.assertIn('Connected', helper.add(self.request()))
        self.assertEqual(len(list(self.profiles_dir.iterdir())), 1)

    def test_failed_connect_rolls_back_to_previous_network(self):
        fake = FakeNetworkManager({'home': ('Home', True)}, [('wlp3s0', 'wifi', 'connected')])
        with patch.object(helper, 'nmcli', fake), patch.object(helper, 'reaches_api', lambda device: False), \
             patch.object(helper.time, 'monotonic', side_effect=[0, 0, 100]):
            with self.assertRaisesRegex(RuntimeError, 'Restored previous connection'):
                helper.add(self.request())
        self.assertEqual(list(self.profiles_dir.iterdir()), [])
        self.assertIn(('-w', '30', 'connection', 'up', 'home'), fake.calls)
        self.assertIn('home', fake.profiles)

    def test_no_wifi_hardware(self):
        fake = FakeNetworkManager({}, [('enp2s0', 'ethernet', 'connected')])
        with patch.object(helper, 'nmcli', fake), self.assertRaisesRegex(RuntimeError, 'no Wi-Fi'):
            helper.add(self.request())

    def test_refuses_to_remove_the_only_connection(self):
        fake = FakeNetworkManager({'office': ('Office', True)}, [('wlp3s0', 'wifi', 'connected'), ('enp2s0', 'ethernet', 'disconnected')])
        with patch.object(helper, 'nmcli', fake), self.assertRaisesRegex(RuntimeError, 'only connection'):
            helper.remove(self.request(op='wifi_remove'))
        self.assertIn('office', fake.profiles)

    def test_removes_active_wifi_when_ethernet_is_up(self):
        fake = FakeNetworkManager({'office': ('Office', True)}, [('wlp3s0', 'wifi', 'connected'), ('enp2s0', 'ethernet', 'connected')],
                                  gateways={'enp2s0': '192.168.1.1'})
        with patch.object(helper, 'nmcli', fake):
            helper.remove(self.request(op='wifi_remove'))
        self.assertNotIn('office', fake.profiles)

    def test_remove_unknown_network(self):
        fake = FakeNetworkManager({}, [('wlp3s0', 'wifi', 'connected')])
        with patch.object(helper, 'nmcli', fake), self.assertRaisesRegex(RuntimeError, 'not saved'):
            helper.remove(self.request(op='wifi_remove'))

if __name__ == '__main__':
    unittest.main()
