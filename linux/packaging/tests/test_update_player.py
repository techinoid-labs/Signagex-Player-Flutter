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
if __name__ == '__main__': unittest.main()
