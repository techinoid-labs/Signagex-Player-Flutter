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
    def test_reboot_is_honestly_reported_as_permission_required(self):
        with patch.object(self.remote,'geometry',return_value=(1024,600,'g')),patch.object(agent,'run') as run:
            self.remote.receive(self.command(input={'action':'reboot_device','confirmed':True}))
            run.assert_not_called()
            self.assertEqual(self.open(self.output[-1]['payload'])['result'],'permission_required')

if __name__=='__main__': unittest.main()
