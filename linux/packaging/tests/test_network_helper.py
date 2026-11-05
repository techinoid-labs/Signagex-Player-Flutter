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

class HotspotNetworkManager(FakeNetworkManager):
    """Adds the access-point profile, scans and activation results to the fake."""
    def __init__(self, devices, scan='', up_ok=True, profiles=None):
        super().__init__(profiles or {}, devices, up_ok=up_ok)
        self.scan, self.loaded, self.active = scan, False, set()
    def __call__(self, *args, timeout=60):
        self.calls.append(args)
        if args[:4] == ('-t', '-f', 'UUID', 'connection'): return done('\n'.join(self.active))
        if args[:4] == ('-t', '-f', 'SSID,SIGNAL,SECURITY', 'device'): return done(self.scan)
        if args[:2] == ('connection', 'load'): self.loaded = True; return done()
        if args[:2] == ('connection', 'delete') and args[2] == helper.HOTSPOT_UUID:
            self.loaded = False; self.active.discard(helper.HOTSPOT_UUID); return done()
        if 'up' in args and helper.HOTSPOT_UUID in args:
            if self.up_ok: self.active.add(helper.HOTSPOT_UUID)
            return done(code=0 if self.up_ok else 4)
        self.calls.pop()
        return super().__call__(*args, timeout=timeout)

class HotspotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = pathlib.Path(self.temporary.name)
        patch.object(helper, 'HOTSPOT_PROFILE', root/'nm'/'signagex-setup-hotspot.nmconnection').start()
        patch.object(helper, 'HOTSPOT_STATE', root/'run'/'hotspot.json').start()
        patch.object(helper, 'PROFILES', root/'profiles').start()
        patch.object(helper.time, 'sleep', lambda _: None).start()
        self.forwarding = []
        patch.object(helper, 'disable_forwarding', self.forwarding.append).start()
        self.commands = []
        def run(command, **_):
            self.commands.append(command); return done('Status: active\n' if command == ['ufw', 'status'] else '')
        patch.object(helper.subprocess, 'run', run).start()
        patch.object(helper.subprocess, 'check_call', lambda command: self.commands.append(command)).start()
        patch.object(helper.shutil, 'which', lambda name: '/usr/sbin/' + name).start()
        self.fake = HotspotNetworkManager([('enp2s0', 'ethernet', 'unavailable'), ('wlp3s0', 'wifi', 'disconnected')],
                                          scan='Office:70:WPA2\nOffice:40:WPA2\nCafe:55:\nCorp\\:HQ:90:WPA2 802.1X\nSignageX-Setup-ZZZZ:99:WPA2\n:30:WPA2\n')
        patch.object(helper, 'nmcli', self.fake).start()
        patch.object(helper, 'reaches_api', lambda device: False).start()
    def tearDown(self):
        patch.stopall(); self.temporary.cleanup()

    def test_validates_hotspot_requests(self):
        self.assertEqual(helper.validate({'job': 'h-1', 'op': 'hotspot_start', 'suffix': 'ab12'}), {'job': 'h-1', 'op': 'hotspot_start', 'suffix': 'AB12'})
        self.assertEqual(helper.validate({'job': 'h-1', 'op': 'hotspot_stop', 'ssid': 'ignored'}), {'job': 'h-1', 'op': 'hotspot_stop'})
        for suffix in ('abc', 'ab;d', 'abcde', None, 1234):
            with self.assertRaises(ValueError, msg=suffix): helper.validate({'job': 'h', 'op': 'hotspot_start', 'suffix': suffix})

    def test_keyfile_is_a_wpa2_access_point_without_routing_or_ipv6(self):
        text = helper.hotspot_keyfile('SignageX-Setup-AB12', 'pw', 'wlp3s0')
        for line in ('mode=ap', 'ssid=SignageX-Setup-AB12', 'key-mgmt=wpa-psk', 'proto=rsn', 'method=shared',
                     'address1=10.42.0.1/24', 'method=disabled', 'autoconnect=false', 'interface-name=wlp3s0'):
            self.assertIn(line + '\n', text)

    def test_nearby_networks_are_unique_strongest_first(self):
        self.assertEqual(helper.nearby_networks('wlp3s0'), [
            {'ssid': 'Corp:HQ', 'signal': 90, 'security': 'enterprise'},
            {'ssid': 'Office', 'signal': 70, 'security': 'wpa'},
            {'ssid': 'Cafe', 'signal': 55, 'security': 'open'}])

    def test_start_opens_hotspot_and_firewall_on_the_hotspot_interface_only(self):
        state = helper.hotspot_start('AB12')
        self.assertEqual(state['ssid'], 'SignageX-Setup-AB12')
        self.assertEqual(len(state['password']), 12)
        self.assertTrue(set(state['password']) <= set(helper.PASSWORD_ALPHABET))
        self.assertEqual((state['address'], state['port']), ('10.42.0.1', 8080))
        self.assertEqual(state['networks'][0]['ssid'], 'Corp:HQ')
        self.assertEqual(helper.HOTSPOT_PROFILE.stat().st_mode & 0o777, 0o600)
        self.assertEqual(helper.HOTSPOT_STATE.stat().st_mode & 0o777, 0o600)
        self.assertIn('psk=' + state['password'], helper.HOTSPOT_PROFILE.read_text())
        self.assertEqual(self.forwarding, ['wlp3s0'])
        timer = next(i for i, c in enumerate(self.commands) if c[0] == 'systemd-run')
        self.assertIn('--on-active=15min', self.commands[timer])
        allows = [c for c in self.commands if c[:2] == ['ufw', 'allow']]
        self.assertEqual(len(allows), 3)
        self.assertTrue(all(c[2:5] == ['in', 'on', 'wlp3s0'] for c in allows))
        self.assertTrue(timer < self.commands.index(allows[0]), 'the stop timer is armed before anything is opened')
        everything = [' '.join(c) for c in self.commands] + [' '.join(c) for c in self.fake.calls]
        self.assertFalse(any(state['password'] in c for c in everything), 'password must never reach a command line')

    def test_start_returns_the_running_hotspot_unchanged(self):
        first = helper.hotspot_start('AB12')
        self.commands.clear()
        self.assertEqual(helper.hotspot_start('AB12'), first)
        self.assertFalse(any(c[0] in ('systemd-run', 'ufw') and c[1:2] != ['status'] for c in self.commands))

    def test_password_is_kept_for_the_boot(self):
        first = helper.hotspot_start('AB12')['password']
        helper.hotspot_stop()
        self.assertNotIn('networks', json.loads(helper.HOTSPOT_STATE.read_text()))
        self.assertEqual(helper.hotspot_start('AB12')['password'], first)

    def test_refuses_while_online(self):
        with patch.object(helper, 'reaches_api', lambda device: True), self.assertRaisesRegex(RuntimeError, 'online'):
            helper.hotspot_start('AB12')
        self.assertFalse(helper.HOTSPOT_PROFILE.exists())

    def test_failed_start_cleans_up(self):
        self.fake.up_ok = False
        with self.assertRaisesRegex(RuntimeError, 'Could not start'):
            helper.hotspot_start('AB12')
        self.assertFalse(helper.HOTSPOT_PROFILE.exists())
        self.assertEqual(len([c for c in self.commands if c[:3] == ['ufw', 'delete', 'allow']]), 3)
        self.assertIn(['systemctl', 'stop', 'signagex-setup-hotspot-expire.timer'], self.commands)

    def test_stop_removes_profile_rules_and_timer(self):
        helper.hotspot_start('AB12')
        self.commands.clear()
        self.assertEqual(helper.hotspot_stop(), 'Setup hotspot stopped')
        self.assertFalse(self.fake.loaded)
        self.assertEqual(len([c for c in self.commands if c[:3] == ['ufw', 'delete', 'allow']]), 3)
        self.assertIn(['systemctl', 'stop', 'signagex-setup-hotspot-expire.timer'], self.commands)

    def test_wifi_from_the_setup_page_ends_the_hotspot(self):
        helper.hotspot_start('AB12')
        self.fake.profiles[helper.HOTSPOT_UUID] = ('SignageX-Setup-AB12', True)
        with patch.object(helper, 'reaches_api', lambda device: True):
            helper.add({'job': 'j', 'op': 'wifi_add', 'ssid': 'Office', 'password': 'secret123', 'hidden': False, 'connect': True})
        self.assertFalse(self.fake.loaded)

    def test_failed_wifi_from_the_setup_page_brings_the_hotspot_back(self):
        helper.hotspot_start('AB12')
        self.fake.profiles[helper.HOTSPOT_UUID] = ('SignageX-Setup-AB12', True)
        self.forwarding.clear()
        with patch.object(helper.time, 'monotonic', side_effect=[0, 0, 100]), self.assertRaisesRegex(RuntimeError, 'Restored'):
            helper.add({'job': 'j', 'op': 'wifi_add', 'ssid': 'Office', 'password': 'wrongpass', 'hidden': False, 'connect': True})
        self.assertTrue(self.fake.loaded)
        self.assertIn(helper.HOTSPOT_UUID, self.fake.active)
        self.assertEqual(self.forwarding, ['wlp3s0'])

    def test_answer_goes_to_stdout_only(self):
        with patch('builtins.print') as output:
            helper.hotspot({'job': 'h', 'op': 'hotspot_start', 'suffix': 'AB12'})
        answer = json.loads(output.call_args[0][0])
        self.assertEqual(answer['phase'], 'applied')
        self.assertEqual(answer['hotspot']['ssid'], 'SignageX-Setup-AB12')

if __name__ == '__main__':
    unittest.main()
