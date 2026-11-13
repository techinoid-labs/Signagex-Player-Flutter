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
                    for name in ('./usr/lib/signagex-player/maintenance-helper', './usr/bin/signagex-maintenance',
                                 f'./opt/{pkg}/kiosk/enable-maintenance.py'):
                        entry = archive.getmember(name)
                        self.assertEqual((entry.uid, entry.gid), (0, 0))
                    self.assertEqual(archive.getmember('./usr/lib/signagex-player/maintenance-helper').mode, 0o755)
                    self.assertEqual(archive.getmember('./usr/bin/signagex-maintenance').mode, 0o755)
                    self.assertIn('./usr/share/polkit-1/rules.d/52-signagex-maintenance.rules', archive.getnames())
                    self.assertIn('./usr/lib/signagex-player/cursor-manager', archive.getnames())
                    self.assertIn('./usr/lib/systemd/user/signagex-cursor.service', archive.getnames())
                    self.assertIn('./usr/lib/systemd/user/signagex-player.service.d/cursor.conf', archive.getnames())
                    self.assertNotIn('./etc/signagex-player/maintenance.json', archive.getnames(), 'No cloned/shared PIN in a package')
                    service=archive.extractfile(f'./opt/{pkg}/kiosk/signagex-player.service').read().decode()
                    self.assertIn('ExecStart=/usr/bin/'+pkg+'\n',service)
                    self.assertIn('WatchdogSec=75',service)
                dependencies=subprocess.check_output(['dpkg-deb','-f',str(output),'Depends'],text=True)
                self.assertIn('polkitd | policykit-1',dependencies)
                self.assertIn('python3-gi', dependencies)
                self.assertIn('gir1.2-gtk-3.0', dependencies)
                self.assertIn('xterm', dependencies)

@unittest.skipUnless(shutil.which('dpkg-deb') and shutil.which('patchelf') and shutil.which('readelf'), 'requires dpkg-deb, patchelf and readelf')
class BundledRunpathTests(unittest.TestCase):
    def test_runpath_without_origin_is_repaired_in_the_package(self):
        # Build v51 shipped libmdk with "$:$/lib" (ORIGIN stripped) and the player exited 127.
        source = pathlib.Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temporary:
            root=pathlib.Path(temporary)
            shutil.copytree(source,root/'linux/packaging')
            bundle=root/'build/linux/x64/release/bundle'; (bundle/'lib').mkdir(parents=True)
            shutil.copy2('/bin/true',bundle/'lib/libcef.so')
            for name, runpath in [('libmdk.so.0','$:$/lib:$/../lib'),('libgood.so','$ORIGIN:$ORIGIN/lib')]:
                shutil.copy2('/bin/true',bundle/'lib'/name)
                subprocess.check_call(['patchelf','--set-rpath',runpath,str(bundle/'lib'/name)])
            binary=bundle/'signagex-player'; binary.write_text('#!/bin/sh\nexit 0\n'); binary.chmod(0o755)
            output=root/'fixture.deb'
            result=subprocess.run(['bash',str(root/'linux/packaging/make_deb.sh'),'runpath-fixture',str(output)],cwd=root,env={**os.environ,'DEB_ARCH':'amd64'},capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            extracted=root/'extracted'; subprocess.check_call(['dpkg-deb','-x',str(output),str(extracted)])
            def runpath(name):
                return subprocess.check_output(['patchelf','--print-rpath',str(extracted/'opt/signagex-player/lib'/name)],text=True).strip()
            self.assertEqual(runpath('libmdk.so.0'),'$ORIGIN')
            self.assertEqual(runpath('libgood.so'),'$ORIGIN:$ORIGIN/lib')
