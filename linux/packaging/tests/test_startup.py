"""Run user-service provisioning in an isolated home, never the real desktop."""
import json, os, pathlib, shutil, subprocess, tempfile, unittest

class StartupTests(unittest.TestCase):
    def test_relocated_bundle_and_appimage_keep_their_own_executable(self):
        source=pathlib.Path(__file__).resolve().parents[1]/'kiosk'
        for appimage in (False,True):
            with self.subTest(appimage=appimage),tempfile.TemporaryDirectory() as temporary:
                root=pathlib.Path(temporary)
                base=root/'test bundle'/'kiosk'; shutil.copytree(source,base)
                executable=base.parent/'signagex-player'; executable.write_text('#!/bin/sh\nexit 0\n');executable.chmod(0o755)
                persistent=root/'SignageX 100% $Player.AppImage'; persistent.write_bytes(executable.read_bytes());persistent.chmod(0o755)
                commands=root/'commands';commands.mkdir()
                systemctl=commands/'systemctl';systemctl.write_text('#!/bin/sh\nexit 0\n');systemctl.chmod(0o755)
                home=root/'home';home.mkdir()
                environment={**os.environ,'HOME':str(home),'PATH':str(commands)+os.pathsep+os.environ['PATH']}
                environment.pop('APPIMAGE',None)
                if appimage:environment['APPIMAGE']=str(persistent)
                result=subprocess.run(['sh',str(base/'install-user-service.sh')],env=environment,capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stderr)
                unit=(home/'.config/systemd/user/signagex-player.service').read_text()
                expected=str((persistent if appimage else executable).resolve()).replace('%','%%').replace('$','$$')
                self.assertIn('ExecStart='+json.dumps(expected),unit)
                self.assertIn('WatchdogSec=75',unit)
                self.assertTrue((home/'.local/bin/signagex-start-supervised').is_file())
                self.assertIn('signagex-start-supervised',(home/'.config/autostart/signagex-player.desktop').read_text())
