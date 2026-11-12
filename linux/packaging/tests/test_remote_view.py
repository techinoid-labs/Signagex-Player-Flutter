import base64, importlib.util, json, os, pathlib, tempfile, unittest
from unittest.mock import patch
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

path=pathlib.Path(__file__).parents[1]/'kiosk/remote_view_agent.py'
spec=importlib.util.spec_from_file_location('remote_agent',path)
agent=importlib.util.module_from_spec(spec); spec.loader.exec_module(agent)

class RemoteProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls): cls.signer=rsa.generate_private_key(public_exponent=65537,key_size=2048)
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory(); self.output=[]
        self.remote=agent.Remote('0607c6',self.temporary.name,self.output.append,self.signer.public_key(),clock=lambda:1000,monotonic=lambda:100)
        self.remote.enabled=True
        self.remote.wayland=False  # X11 path; Wayland is covered in test_remote_view_wayland.py
        self.key=os.urandom(32)
    def tearDown(self): self.temporary.cleanup()
    def command(self,**changes):
        value={'protocol':2,'player_code':'0607c6','stream_id':'stream','revision':1,'controller_epoch':1,
            'controller':'viewer','session_id':'viewer','viewers':1,'quality':'low','issued_at':1000000,
            'expires_at':1005000,'lease_until':1030000,'command_id':'command-1','input':None,
            'wrapped_key':agent.b64(self.remote.private.public_key().encrypt(self.key,agent.OAEP))}
        value.update(changes)
        key,iv=os.urandom(32),os.urandom(12)
        box={'key':agent.b64(self.remote.private.public_key().encrypt(key,agent.OAEP)), 'iv':agent.b64(iv),
            'ciphertext':agent.b64(AESGCM(key).encrypt(iv,agent.compact(value),None))}
        data=agent.b64(agent.compact(box))
        return {'action':'remote_v2','data':data,'signature':agent.b64(self.signer.sign(data.encode(),padding.PKCS1v15(),hashes.SHA256()))}
    def open(self,box):
        self.remote.private.public_key().verify(agent.un64(box['signature']),f"{box['stream_id']}\n{box['iv']}\n{box['data']}".encode(),padding.PKCS1v15(),hashes.SHA256())
        return json.loads(AESGCM(self.key).decrypt(agent.un64(box['iv']),agent.un64(box['data']),box['stream_id'].encode()))
    def test_signed_join_produces_encrypted_signed_receipt(self):
        self.assertTrue(self.remote.receive(self.command()))
        self.assertTrue(self.remote.active)
        self.assertEqual(self.open(self.output[-1]['payload'])['result'],'accepted')
        self.assertNotIn('frame_key',json.dumps(self.output))
    def test_unsigned_tampered_retained_wrong_player_and_expired_are_rejected(self):
        invalid=[self.command(player_code='other'),self.command(expires_at=999999),self.command(issued_at=1010000)]
        envelope=self.command(); envelope['signature']=agent.b64(b'bad'); invalid.append(envelope)
        for item in invalid: self.assertFalse(self.remote.receive(item))
        self.assertFalse(self.remote.receive(self.command(),retained=True))
        self.assertEqual(self.output,[])
    def test_persisted_revision_fences_replay_after_restart(self):
        self.assertTrue(self.remote.receive(self.command()))
        previous=self.remote.private.private_numbers()
        restarted=agent.Remote('0607c6',self.temporary.name,self.output.append,self.signer.public_key(),clock=lambda:1000,monotonic=lambda:100)
        restarted.enabled=True
        self.assertEqual(restarted.private.private_numbers(),previous)
        self.assertFalse(restarted.receive(self.command()))
    def network(self, signer=None, password='secret123', **changes):
        value={'protocol':'linux_network_v1','player':'0607c6','key':self.remote.public_key,'issued':1000000,
            'job':'job-1','op':'wifi_add','ssid':'Office','hidden':False,'connect':True}
        if password is not None:
            value['secret']=agent.b64(self.remote.private.public_key().encrypt(password.encode(),agent.NETWORK_OAEP))
        value.update(changes); data=json.dumps(value)
        return {'data':data,'signature':agent.b64((signer or self.signer).sign(data.encode(),padding.PKCS1v15(),hashes.SHA256()))}
    def test_signed_wifi_command_decrypts_password_once(self):
        job,reason=self.remote.verify_network(self.network())
        self.assertIsNone(reason)
        self.assertEqual(job,{'job':'job-1','op':'wifi_add','ssid':'Office','password':'secret123','issued':1000000,'hidden':False,'connect':True})
        self.assertEqual(self.remote.verify_network(self.network()),(None,'replayed'))
        self.assertEqual(self.remote.verify_network(self.network(issued=1000001,password=None))[0]['password'],'')
    def test_wifi_command_rejections(self):
        other=agent.rsa.generate_private_key(public_exponent=65537,key_size=2048)
        cases={'bad_signature':self.network(signer=other),'wrong_player':self.network(player='other'),
            'wrong_key':self.network(key='AAAA'),'stale':self.network(issued=900000),
            'invalid':self.network(op='shell'),'bad_secret':self.network(secret=agent.b64(b'x'*256))}
        for reason,envelope in cases.items():
            self.assertEqual(self.remote.verify_network(envelope),(None,reason),reason)
        self.assertEqual(self.remote.verify_network(self.network(ssid='x'*33)),(None,'invalid'))
        # Rejections never consume the replay fence.
        self.assertIsNone(self.remote.verify_network(self.network())[1])
    def test_wifi_reply_uses_request_id(self):
        reply=agent.ota_reply(self.remote,{'id':7,'network_command':self.network()})
        self.assertEqual(reply['id'],7); self.assertEqual(reply['network_verified']['ssid'],'Office')
        self.assertEqual(agent.ota_reply(self.remote,{'id':8,'network_command':self.network()}),{'ota_rejected':'replayed','id':8})
    def ota(self, signer=None, **changes):
        value={'protocol':'linux_ota_v1','player':'0607c6','key':self.remote.public_key,'issued':1000000,
            'job':'job-1','version':'51','platform':'linux','sha256':'a'*64}
        value.update(changes); data=json.dumps(value)
        return {'data':data,'signature':agent.b64((signer or self.signer).sign(data.encode(),padding.PKCS1v15(),hashes.SHA256()))}
    def test_signed_update_command_is_verified_once(self):
        job,reason=self.remote.verify_ota(self.ota())
        self.assertIsNone(reason)
        self.assertEqual(job,{'job':'job-1','version':'51','platform':'linux','sha256':'a'*64,'issued':1000000})
        # The same command, or an older one, never runs again -- also after a restart.
        self.assertEqual(self.remote.verify_ota(self.ota())[1],'replayed')
        restarted=agent.Remote('0607c6',self.temporary.name,self.output.append,self.signer.public_key(),clock=lambda:1000,monotonic=lambda:100)
        self.assertEqual(restarted.verify_ota(self.ota(issued=999999))[1],'replayed')
        self.assertIsNone(restarted.verify_ota(self.ota(issued=1000001))[1])
    def test_forged_misaddressed_and_stale_update_commands_are_rejected(self):
        other=rsa.generate_private_key(public_exponent=65537,key_size=2048)
        tampered=self.ota(); tampered['data']=tampered['data'].replace('"51"','"99"')
        cases=[(self.ota(signer=other),'bad_signature'),(tampered,'bad_signature'),({'data':'x'},'bad_signature'),
               (self.ota(player='other'),'wrong_player'),(self.ota(protocol='android_ota_v1'),'wrong_player'),
               (self.ota(key='someone-else'),'wrong_key'),(self.ota(issued=939999),'stale'),(self.ota(issued=1005001),'stale'),
               (self.ota(issued='1000000'),'stale')]
        for envelope,reason in cases:
            with self.subTest(reason=reason): self.assertEqual(self.remote.verify_ota(envelope),(None,reason))
        self.assertIsNone(self.remote.verify_ota(self.ota())[1])
    def test_update_reports_are_signed_by_the_device_identity(self):
        signed=self.remote.sign_ota('{"phase":"installing"}')
        self.assertEqual(signed['key'],self.remote.public_key)
        self.remote.private.public_key().verify(agent.un64(signed['signature']),signed['data'].encode(),padding.PKCS1v15(),hashes.SHA256())
        self.assertIsNone(self.remote.sign_ota('x'*8193))
    def test_update_replies_echo_the_request_id_and_say_why_they_failed(self):
        self.assertEqual(agent.ota_reply(self.remote,{'id':7,'ota_command':self.ota()})['id'],7)
        self.assertEqual(agent.ota_reply(self.remote,{'id':8,'ota_command':self.ota()}),{'ota_rejected':'replayed','id':8})
        self.assertEqual(agent.ota_reply(self.remote,{'id':9,'ota_command':self.ota(issued=1,job='old')}),{'ota_rejected':'stale','id':9})
        signed=agent.ota_reply(self.remote,{'id':10,'ota_sign':'{}'})
        self.assertEqual((signed['id'],signed['ota_signed']['data']),(10,'{}'))
        self.assertEqual(agent.ota_reply(self.remote,{'id':'x','ota_sign':'x'*9000}),{'ota_rejected':'invalid','id':None})
    def test_x11_rotation_is_read_from_xrandr(self):
        line='HDMI-1 connected primary 1920x1080+0+0 inverted (normal left inverted right x axis y axis) 1600mm x 900mm'
        self.assertEqual(agent.x11_transform(line),'180')
        self.assertEqual(agent.x11_transform(line.replace(' inverted (',' left (')),'90')
        self.assertEqual(agent.x11_transform(line.replace(' inverted (',' right (')),'270')
        self.assertEqual(agent.x11_transform(line.replace(' inverted (',' (')),'normal')
        self.assertEqual(agent.x11_transform('DP-1 connected 1920x1080+1920+0 left (n)\n'+line),'180')  # primary wins
    def test_x11_click_on_a_rotated_screen_lands_on_the_upright_spot(self):
        def geometry():
            self.remote.transform='180'
            return (1920,1080,'geometry')
        with patch.object(self.remote,'geometry',side_effect=geometry),patch.object(agent,'run') as run:
            self.remote.frames['frame']=(100,'geometry')
            self.remote.receive(self.command(input={'action':'click','x':0.25,'y':0.25,'frame_id':'frame'}))
            run.assert_called_once_with('xdotool','mousemove','--sync','1440','810','click','1')
    def test_input_requires_controller_and_recent_frame_geometry(self):
        with patch.object(self.remote,'geometry',return_value=(1024,600,'geometry')),patch.object(agent,'run') as run:
            self.remote.receive(self.command(input={'action':'click','x':0.5,'y':0.5,'frame_id':'missing'}))
            self.assertEqual(self.open(self.output[-1]['payload'])['result'],'stale_frame')
            run.assert_not_called()
            self.remote.frames['frame']=(100,'geometry')
            self.remote.receive(self.command(revision=2,command_id='command-2',input={'action':'click','x':0.5,'y':0.5,'frame_id':'frame'}))
            run.assert_called_once_with('xdotool','mousemove','--sync','512','300','click','1')
            self.assertEqual(self.open(self.output[-1]['payload'])['result'],'executed')
            self.remote.receive(self.command(revision=3,session_id='observer',input={'action':'send_text','message':'secret'}))
            self.assertEqual(self.open(self.output[-1]['payload'])['result'],'expired')
            self.assertEqual(run.call_count,1)
    def test_duplicate_input_does_not_execute_twice(self):
        envelope=self.command(input={'action':'press_back'})
        with patch.object(self.remote,'geometry',return_value=(1024,600,'g')),patch.object(agent,'run') as run:
            self.remote.receive(envelope); self.remote.receive(envelope)
            self.assertEqual(run.call_count,1)
    def test_literal_text_uses_arguments_and_is_never_in_receipts(self):
        text='$(touch /tmp/no) `id` "hello"'
        with patch.object(self.remote,'geometry',return_value=(1024,600,'g')),patch.object(agent,'run') as run:
            self.remote.receive(self.command(input={'action':'send_text','message':text}))
            self.assertEqual(run.call_args.args[-1],text)
            self.assertNotIn(text,json.dumps(self.output))
    def test_disabled_player_and_expired_lease_cannot_capture(self):
        self.remote.enabled=False
        self.assertFalse(self.remote.receive(self.command()))
        self.remote.enabled=True; self.remote.receive(self.command())
        self.remote.monotonic=lambda:131
        with patch.object(self.remote,'geometry') as geometry:
            self.remote.capture(); geometry.assert_not_called()
        self.assertFalse(self.remote.active)
    def test_frame_is_encrypted_and_keeps_native_input_geometry(self):
        self.remote.receive(self.command())
        def capture(*arguments):
            if arguments[0] == 'scrot': agent.Image.new('RGB',(1024,600),(25,80,130)).save(arguments[-1])
            return 'SignageX Player'
        with patch.object(self.remote,'geometry',return_value=(1024,600,'geometry')),patch.object(agent,'run',side_effect=capture):
            self.remote.capture()
        self.assertEqual(self.output[-1]['topic'],'frame')
        frame=self.open(self.output[-1]['payload'])
        self.assertEqual((frame['input_width'],frame['input_height']),(1024,600))
        self.assertTrue(frame['player_foreground'])
        self.assertFalse(frame['can_reboot'])
        with agent.Image.open(agent.io.BytesIO(agent.un64(frame['img_url']))) as image:
            self.assertEqual(image.width,800)
        self.assertIn(frame['frame_id'],self.remote.frames)

    def test_key_and_revision_files_are_private(self):
        self.remote.receive(self.command())
        for name in ('identity.pem','revision'):
            self.assertEqual((pathlib.Path(self.temporary.name)/name).stat().st_mode & 0o777,0o600)
    def test_viewer_handover_fences_old_controller_and_old_frame(self):
        self.remote.receive(self.command())
        self.remote.frames['before-handover']=(100,'g')
        self.assertTrue(self.remote.receive(self.command(revision=2,controller_epoch=2,controller='second',session_id='second',command_id='handover')))
        self.assertEqual(self.remote.frames,{})
        self.assertFalse(self.remote.receive(self.command(revision=3,controller_epoch=1,command_id='old-owner',input={'action':'press_back'})))
        with patch.object(self.remote,'geometry',return_value=(1024,600,'g')),patch.object(agent,'run') as run:
            self.remote.receive(self.command(revision=4,controller_epoch=2,controller='second',session_id='viewer',command_id='observer',input={'action':'press_back'}))
            run.assert_not_called()
            self.remote.receive(self.command(revision=5,controller_epoch=2,controller='second',session_id='second',command_id='owner',input={'action':'press_back'}))
            run.assert_called_once_with('xdotool','key','--clearmodifiers','alt+Left')
    def test_last_viewer_leaving_stops_frames_and_reconnect_gets_new_stream(self):
        self.remote.receive(self.command(viewers=2))
        self.remote.frames['old']=(100,'g')
        self.remote.receive(self.command(revision=2,viewers=0,command_id='leave'))
        self.assertFalse(self.remote.active)
        self.assertEqual(self.remote.frames,{})
        self.assertTrue(self.remote.receive(self.command(revision=3,stream_id='reconnected',command_id='reconnect')))
        self.assertTrue(self.remote.active)
        self.assertEqual(self.remote.stream,'reconnected')
    def test_rotation_invalidates_coordinates_and_normalized_edges_are_bounded(self):
        self.remote.receive(self.command())
        self.remote.frames['frame']=(100,'old-geometry')
        with patch.object(self.remote,'geometry',return_value=(600,1024,'rotated')),patch.object(agent,'run') as run:
            self.remote.receive(self.command(revision=2,command_id='rotated',input={'action':'click','x':1,'y':1,'frame_id':'frame'}))
            run.assert_not_called()
            self.assertEqual(self.open(self.output[-1]['payload'])['result'],'stale_frame')
            self.remote.frames['new']=(100,'rotated')
            self.remote.receive(self.command(revision=3,command_id='edges',input={'action':'click','x':1,'y':1,'frame_id':'new'}))
            run.assert_called_once_with('xdotool','mousemove','--sync','599','1023','click','1')
    def test_drag_and_long_press_release_the_mouse(self):
        self.remote.receive(self.command())
        self.remote.frames['frame']=(100,'g')
        with patch.object(self.remote,'geometry',return_value=(1024,600,'g')),patch.object(agent,'run') as run,patch.object(agent.time,'sleep'):
            self.remote.receive(self.command(revision=2,command_id='drag',input={'action':'scroll','hold':{'x':0,'y':0},'release':{'x':1,'y':1},'frame_id':'frame'}))
            self.assertEqual(run.call_args.args,('xdotool','mouseup','1'))
            self.assertEqual(self.open(self.output[-1]['payload'])['result'],'executed')
            self.remote.receive(self.command(revision=3,command_id='hold',input={'action':'long_press','x':0.5,'y':0.5,'frame_id':'frame'}))
            self.assertEqual(run.call_args.args,('xdotool','mouseup','1'))
    def test_restart_requires_confirmation_and_home_uses_existing_window(self):
        self.remote.receive(self.command())
        with patch.object(self.remote,'geometry',return_value=(1024,600,'g')),patch.object(agent,'run',return_value='123') as run:
            self.remote.receive(self.command(revision=2,command_id='no-confirm',input={'action':'restart_player'}))
            run.assert_not_called()
            self.remote.receive(self.command(revision=3,command_id='home',input={'action':'press_home'}))
            self.assertEqual(run.call_args.args,('xdotool','windowactivate','--sync','123'))
            self.remote.receive(self.command(revision=4,command_id='restart',input={'action':'restart_player','confirmed':True}))
            self.assertIn('--on-active=1s',run.call_args.args)

    def test_reboot_is_honestly_reported_as_permission_required(self):
        with patch.object(self.remote,'geometry',return_value=(1024,600,'g')),patch.object(agent,'run') as run:
            self.remote.receive(self.command(input={'action':'reboot_device','confirmed':True}))
            run.assert_not_called()
            self.assertEqual(self.open(self.output[-1]['payload'])['result'],'permission_required')

if __name__=='__main__': unittest.main()
