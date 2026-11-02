"""Packaging contract fixture only: never installs or executes the player."""
import io, json, os, pathlib, shutil, subprocess, tarfile, tempfile, unittest

@unittest.skipUnless(shutil.which('dpkg-deb'), 'requires Linux dpkg-deb')
class PackageContractTests(unittest.TestCase):
    def test_production_and_staging_helpers_match_the_package(self):
        source = pathlib.Path(__file__).resolve().parents[1]
        for suffix in ('', 'staging'):
            with self.subTest(channel=suffix or 'production'), tempfile.TemporaryDirectory() as temporary:
                root=pathlib.Path(temporary)
                shutil.copytree(source,root/'linux/packaging')
                bundle=root/'build/linux/arm64/release/bundle'
                bundle.mkdir(parents=True)
                (bundle/'lib').mkdir()
                shutil.copy2('/bin/true',bundle/'lib/libcef.so')  # Valid stripped ELF fixture, never a browser build.
                binary=bundle/'signagex-player'; binary.write_text('#!/bin/sh\nexit 0\n'); binary.chmod(0o755)
                output=root/'fixture.deb'
                result=subprocess.run(['bash',str(root/'linux/packaging/make_deb.sh'),'arm64-config-fixture',str(output),suffix],cwd=root,env={**os.environ,'DEB_ARCH':'arm64'},capture_output=True,text=True)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
                pkg='signagex-player'+('-staging' if suffix else '')
                arch=subprocess.check_output(['dpkg-deb','-f',str(output),'Architecture'],text=True).strip()
                self.assertEqual(arch,'arm64')
                data=subprocess.check_output(['dpkg-deb','--fsys-tarfile',str(output)])
                with tarfile.open(fileobj=io.BytesIO(data)) as archive:
                    manifest=json.load(archive.extractfile('./usr/lib/signagex-player/update-channel.json'))
                    self.assertEqual(manifest['package'],pkg)
                    self.assertEqual(manifest['platform'],'linux-arm64')
                    self.assertEqual(manifest['architecture'],'arm64')
                    self.assertIn('stage.signagexai.com' if suffix else 'api.signagex.ai',manifest['manifest'])
                    helper=archive.getmember('./usr/lib/signagex-player/update-player')
                    self.assertEqual((helper.uid,helper.gid,helper.mode),(0,0,0o755))
                    service=archive.extractfile(f'./opt/{pkg}/kiosk/signagex-player.service').read().decode()
                    self.assertIn('ExecStart=/usr/bin/'+pkg+'\n',service)
                    self.assertIn('WatchdogSec=75',service)
                dependencies=subprocess.check_output(['dpkg-deb','-f',str(output),'Depends'],text=True)
                self.assertIn('polkitd | policykit-1',dependencies)
