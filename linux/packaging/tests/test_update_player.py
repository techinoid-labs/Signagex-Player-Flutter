import pathlib, runpy, unittest
from unittest.mock import patch

updater = runpy.run_path(str(pathlib.Path(__file__).parents[1]/'update-player'))
class UpdatePolicyTests(unittest.TestCase):
    def test_only_https_and_known_hosts(self):
        check = updater['trusted_url']
        self.assertEqual(check('https://example.com/release', {'example.com'}),'https://example.com/release')
        for url in ['http://example.com/a','https://evil.com/a','https://example.com.evil.com/a','https://name:secret@example.com/a','https://example.com:444/a','file:///etc/passwd']:
            with self.subTest(url=url), self.assertRaises(ValueError): check(url,{'example.com'})
    def test_redirects_are_validated(self):
        handler=updater['RestrictedRedirect'](); handler.hosts={'example.com'}
        with self.assertRaises(ValueError): handler.redirect_request(None,None,302,'',{},'https://evil.com/release')
    def test_no_arbitrary_command_arguments(self):
        with patch('os.geteuid',return_value=0), patch('sys.argv',['update-player','/tmp/untrusted.deb']), self.assertRaises(ValueError): updater['main']()
    def test_package_and_health_versions_match_on_both_architectures(self):
        for build, version in [('v43','43'),('arm64-v19','0.arm64-v19'),('1.2.3','1.2.3')]:
            with self.subTest(build=build):
                self.assertEqual(updater['debian_version'](build),version)
                self.assertTrue(updater['healthy_release']({'pid':12,'timestamp':990,'build':build},12,version,1000))
        self.assertFalse(updater['healthy_release']({'pid':12,'timestamp':990,'build':'v42'},12,'43',1000))
    def test_stale_future_or_malformed_health_cannot_accept_an_upgrade(self):
        baseline={'pid':12,'timestamp':990,'build':'v43'}
        for change in [{'pid':13},{'pid':True},{'timestamp':979},{'timestamp':1001},
                       {'timestamp':float('nan')},{'timestamp':'990'},{'build':None}]:
            with self.subTest(change=change):
                self.assertFalse(updater['healthy_release']({**baseline,**change},12,'43',1000))
        self.assertFalse(updater['healthy_release'](None,12,'43',1000))
    def test_interrupted_install_restores_the_retained_exact_package(self):
        import json, tempfile
        namespace=updater['recover_interrupted_update'].__globals__
        with tempfile.TemporaryDirectory() as temporary:
            root=pathlib.Path(temporary); cache=root/'cache';cache.mkdir()
            state=root/'update-status.json';state.write_text(json.dumps({'status':'installing'}))
            channel=root/'channel.json';channel.write_text(json.dumps({'package':'signagex-player'}))
            rollback=cache/'rollback.deb';rollback.write_bytes(b'fixture')
            original=pathlib.Path
            def path(value):
                return state if str(value)=='/var/lib/signagex-player/update-status.json' else original(value)
            with patch.dict(namespace,{'CACHE':cache,'CONFIG':channel,'run':lambda *args: 'signagex-player' if args[0]=='dpkg-deb' else calls.append(args),'update_status':lambda *args:statuses.append(args)}), patch('pathlib.Path',side_effect=path):
                calls=[];statuses=[]
                updater['recover_interrupted_update']()
            self.assertEqual(calls,[('dpkg','-i',str(rollback))])
            self.assertEqual(statuses,[('rolled_back',)])

    def check_once(self, root, installed, feed_version='v15', now=False):
        """Run one service-mode check against a fake feed; returns (printed, fetched).
        A package download is simulated as a failure, as a broken release would be."""
        import json, types
        namespace=updater['main'].__globals__
        channel=root/'channel.json'
        channel.write_text(json.dumps({'manifest':'https://api.signagex.ai/v1/player-releases/latest?platform=linux','package':'signagex-player','architecture':'amd64','platform':'linux'}))
        fetched=[]; self.statuses=[]
        def download(url, destination, hosts):
            if pathlib.Path(destination).name == 'manifest.json':
                pathlib.Path(destination).write_text(json.dumps({'platform':'linux','version':feed_version,'sha256':'a'*64,'downloadUrl':'https://norwin.sfo3.digitaloceanspaces.com/release.deb'}))
                return ''
            fetched.append(url); raise RuntimeError('download failed')
        with patch.dict(namespace,{'CONFIG':channel,'CACHE':root/'cache','ATTEMPTS':root/'attempts.json','download':download,'run':lambda *args: installed,
                                   'update_status':lambda *args: self.statuses.append(args)}), \
             patch('os.geteuid',return_value=0), patch('sys.argv',['update-player']), \
             patch.dict('os.environ',{'PKEXEC_UID':'1000','SIGNAGEX_UPDATE_SERVICE':'1','SIGNAGEX_UPDATE_NOW':'1' if now else ''}), \
             patch('pwd.getpwuid',return_value=types.SimpleNamespace(pw_name='player')), patch('builtins.print') as output:
            try: updater['main']()
            except RuntimeError: pass
        return [call.args[0] for call in output.call_args_list], fetched

    def test_feed_build_id_is_compared_as_the_package_version(self):
        # The amd64 feed has published the CI build id ("v15"). Raw, dpkg sorts it
        # above every number: a player on 50 would fetch 15, then abort on the
        # Version check. Normalized, only a genuinely newer package is fetched.
        import tempfile
        for installed, printed, fetches in [('50',['up-to-date'],0),('15',['up-to-date'],0),('14',[],1)]:
            with self.subTest(installed=installed), tempfile.TemporaryDirectory() as temporary:
                self.assertEqual(self.check_once(pathlib.Path(temporary), installed), (printed, ['https://norwin.sfo3.digitaloceanspaces.com/release.deb']*fetches))

    def test_failed_release_backs_off_instead_of_redownloading_hourly(self):
        import json, tempfile, time
        with tempfile.TemporaryDirectory() as temporary:
            root=pathlib.Path(temporary)
            self.assertEqual(len(self.check_once(root,'14')[1]),1)
            state=json.loads((root/'attempts.json').read_text())
            self.assertEqual((state['version'],state['failures']),('15',1))
            self.assertTrue(time.time()+0.8*3600-5 <= state['next'] <= time.time()+1.2*3600+5)
            # The next hourly check of the same broken release downloads nothing.
            self.assertEqual(self.check_once(root,'14'),(['deferred'],[]))
            # A newer release is not held back by the old release's failures.
            self.assertEqual(len(self.check_once(root,'14',feed_version='v16')[1]),1)
            self.assertEqual(json.loads((root/'attempts.json').read_text())['failures'],1)

    def test_operator_request_retries_a_deferred_release_and_reports_phases(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            root=pathlib.Path(temporary)
            self.check_once(root,'14')
            self.assertEqual(self.statuses,[('downloading','15'),('failed','15')])
            self.assertEqual(self.check_once(root,'14'),(['deferred'],[]))
            # "Update now" from the CMS skips only the backoff, nothing else.
            self.assertEqual(len(self.check_once(root,'14',now=True)[1]),1)
            self.assertEqual(self.check_once(root,'50',now=True),(['up-to-date'],[]))

    def test_now_is_the_only_argument_and_is_forwarded_to_the_service(self):
        for argv in (['update-player','--now','x'],['update-player','--recover-now'],['update-player','--NOW']):
            with self.subTest(argv=argv), patch('os.geteuid',return_value=0), patch('sys.argv',argv), self.assertRaises(ValueError): updater['main']()
        with patch('os.geteuid',return_value=0), patch('sys.argv',['update-player','--now']), patch.dict('os.environ',{'PKEXEC_UID':'1000','SIGNAGEX_UPDATE_SERVICE':''}), patch('subprocess.check_call') as command:
            updater['main']()
            arguments=command.call_args.args[0]
            self.assertIn('--setenv=SIGNAGEX_UPDATE_NOW=1',arguments)
            self.assertEqual(arguments[-1],'/usr/lib/signagex-player/update-player')
        with patch('os.geteuid',return_value=0), patch('sys.argv',['update-player']), patch.dict('os.environ',{'PKEXEC_UID':'1000','SIGNAGEX_UPDATE_SERVICE':''}), patch('subprocess.check_call') as command:
            updater['main']()
            self.assertNotIn('--setenv=SIGNAGEX_UPDATE_NOW=1',command.call_args.args[0])

    def test_backoff_doubles_with_jitter_and_caps_at_a_day(self):
        import json, tempfile
        namespace=updater['record_failure'].__globals__
        with tempfile.TemporaryDirectory() as temporary:
            attempts=pathlib.Path(temporary)/'attempts.json'
            with patch.dict(namespace,{'ATTEMPTS':attempts}):
                for failures, base in [(1,3600),(2,7200),(3,14400),(5,57600),(6,86400),(9,86400)]:
                    attempts.write_text(json.dumps({'version':'15','failures':failures-1,'next':0}))
                    updater['record_failure']('15',1000)
                    state=json.loads(attempts.read_text())
                    self.assertEqual(state['failures'],failures)
                    self.assertTrue(1000+0.8*base <= state['next'] <= 1000+1.2*base, (failures, state))
                updater['clear_failures'](); updater['clear_failures']()
                self.assertFalse(attempts.exists())

    def test_transaction_runs_outside_player_control_group(self):
        with patch('os.geteuid',return_value=0), patch('sys.argv',['update-player']), patch.dict('os.environ',{'PKEXEC_UID':'1000','SIGNAGEX_UPDATE_SERVICE':''}), patch('subprocess.check_call') as command:
            updater['main']()
            arguments = command.call_args.args[0]
            self.assertEqual(arguments[-1], '/usr/lib/signagex-player/update-player')
            self.assertIn('--unit=signagex-managed-update', arguments)
            self.assertIn('--setenv=PKEXEC_UID=1000', arguments)
            self.assertIn('--wait', arguments)

    def test_rollback_is_built_fast_and_installs_the_same_files(self):
        # A real dpkg-deb build of a small package, with the flags the device uses.
        import shutil, subprocess, tempfile
        if not shutil.which('dpkg-deb'): self.skipTest('dpkg-deb not available')
        namespace = updater['main'].__globals__
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            previous = root/'previous'
            (previous/'DEBIAN').mkdir(parents=True)
            (previous/'DEBIAN'/'control').write_text('Package: signagex-player\nVersion: 68\nArchitecture: amd64\nMaintainer: SignageX <support@signagex.ai>\nDescription: test\n')
            (previous/'opt/signagex-player/lib').mkdir(parents=True)
            payload = previous/'opt/signagex-player/lib/libapp.so'
            payload.write_bytes(b'\x7fELF' + bytes(range(256))*4096)
            rollback = root/'rollback.deb'
            namespace['build_rollback'](previous, rollback)
            members = subprocess.run(['ar','t',str(rollback)], capture_output=True, text=True, check=True).stdout.split()
            self.assertIn('data.tar.gz', members)
            self.assertEqual(subprocess.run(['dpkg-deb','-f',str(rollback),'Version'], capture_output=True, text=True, check=True).stdout.strip(), '68')
            unpacked = root/'unpacked'
            subprocess.run(['dpkg-deb','-x',str(rollback),str(unpacked)], check=True)
            self.assertEqual((unpacked/'opt/signagex-player/lib/libapp.so').read_bytes(), payload.read_bytes())

    def test_space_check_counts_the_unpacked_copy_and_the_rollback(self):
        needed = updater['rollback_space_needed'](143_000_000, 540_000)
        # 143 MB candidate + 2 x 540 MB installed + 512 MiB margin.
        self.assertEqual(needed, 143_000_000 + 2*540_000*1024 + 512*1024*1024)
        self.assertGreater(needed, 143_000_000*3 + 512*1024*1024)
if __name__ == '__main__': unittest.main()
