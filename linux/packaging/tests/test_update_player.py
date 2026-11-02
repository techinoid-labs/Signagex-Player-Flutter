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

    def test_transaction_runs_outside_player_control_group(self):
        with patch('os.geteuid',return_value=0), patch('sys.argv',['update-player']), patch.dict('os.environ',{'PKEXEC_UID':'1000','SIGNAGEX_UPDATE_SERVICE':''}), patch('subprocess.check_call') as command:
            updater['main']()
            arguments = command.call_args.args[0]
            self.assertEqual(arguments[-1], '/usr/lib/signagex-player/update-player')
            self.assertIn('--unit=signagex-managed-update', arguments)
            self.assertIn('--setenv=PKEXEC_UID=1000', arguments)
            self.assertIn('--wait', arguments)
if __name__ == '__main__': unittest.main()
