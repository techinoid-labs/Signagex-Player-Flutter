#!/usr/bin/python3
"""Unprivileged X11/Wayland adapter for the existing SignageX signed remote-v2 protocol.

X11: scrot for frames, xdotool for input (unchanged). Wayland (the cage kiosk,
WAYLAND_DISPLAY set): grim for frames and wayland_input.py's uinput devices for
input, since neither X11 tool reaches a Wayland compositor.

Only encrypted frames/receipts and a public identity leave stdout. Commands are
verified against the packaged server key before decryption or OS interaction.
"""
import base64, collections, io, json, math, os, pathlib, queue, subprocess, sys, tempfile, threading, time, uuid
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from PIL import Image

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import wayland_input

SERVER_KEY = 'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAsEJfK9Jr9KvAj7656FpxrwGDC3LckOE/pxML3CXazXslmGRRbf9gHJM0SMRw8NlGTdkTWL/NGGNTIUPkF1XiBW7S8FlVkYHGjQtQuiB5u7pX0aUx5F41liax27RGu/xF3WOmOJXhPgDMzv/J1SEgNEFpqCVYFkS6W17AhNa66brQW+3Kk13Obc7zUxO+Q7iLLgV4/SdDInn32ohWRe15+Cqxmv1sbCpVc4fRoI6Y5ggupq9TgtO+gE0iJLp4iZJuf0GaGc8zirTMH+0wAtvbzE1j41lHTjaA3Esga5LPEtS/D0SF8wQKyJm+gRh/O/c+c4r4eM4znoMdYSXGDmNihQIDAQAB'
OAEP = padding.OAEP(mgf=padding.MGF1(hashes.SHA1()), algorithm=hashes.SHA1(), label=None)
# linux_network_v1 Wi-Fi passwords are encrypted to this device's key by the backend.
NETWORK_OAEP = padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None)

def b64(value): return base64.b64encode(value).decode('ascii')
def un64(value): return base64.b64decode(value, validate=True)
def compact(value): return json.dumps(value, separators=(',', ':')).encode()
def run(*arguments): return subprocess.check_output(arguments, timeout=5, stderr=subprocess.DEVNULL).decode().strip()

class Remote:
    def __init__(self, code, directory, emit, signing_key=None, clock=time.time, monotonic=time.monotonic):
        self.code, self.directory, self.emit = code, pathlib.Path(directory), emit
        self.clock, self.monotonic = clock, monotonic
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.directory, 0o700)
        identity = self.directory/'identity.pem'
        if identity.exists():
            self.private = serialization.load_pem_private_key(identity.read_bytes(), password=None)
        else:
            self.private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            self.atomic(identity, self.private.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
        self.signing_key = signing_key or serialization.load_der_public_key(un64(SERVER_KEY))
        self.revision_file = self.directory/'revision'
        self.revision = int(self.revision_file.read_text()) if self.revision_file.exists() else 0
        self.enabled = False
        self.active = False
        self.stream, self.key, self.controller = '', None, None
        self.epoch, self.deadline, self.started, self.sequence = 0, 0, 0, 0
        self.high = False
        self.frames, self.results = collections.OrderedDict(), collections.OrderedDict()
        self.upload = self.download = self.dropped = 0
        self.boot = str(uuid.uuid4())
        self.wayland = bool(os.environ.get('WAYLAND_DISPLAY', '').strip())
        self.input = None
        self.last_size = None

    def atomic(self, path, data):
        temporary = path.with_suffix('.tmp')
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, 'wb') as output:
            output.write(data); output.flush(); os.fsync(output.fileno())
        temporary.replace(path)
        directory = os.open(path.parent, os.O_RDONLY)
        try: os.fsync(directory)
        finally: os.close(directory)

    @property
    def public_key(self):
        return b64(self.private.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo))

    def unwrap(self, value):
        key = self.private.decrypt(un64(value), OAEP)
        if len(key) != 32: raise ValueError('Invalid key')
        return key

    def seal(self, value):
        iv = os.urandom(12)
        data = AESGCM(self.key).encrypt(iv, compact(value), self.stream.encode())
        iv, data = b64(iv), b64(data)
        signature = self.private.sign(f'{self.stream}\n{iv}\n{data}'.encode(), padding.PKCS1v15(), hashes.SHA256())
        return {'action':'sealed_v2', 'sender':'linux', 'stream_id':self.stream, 'iv':iv, 'data':data, 'signature':b64(signature)}

    def publish(self, topic, value):
        if self.key is None: return
        box = self.seal(value)
        size = len(compact(box))
        if size > 2*1024*1024: self.dropped += 1; return
        self.emit({'topic':topic, 'payload':box})
        self.upload += size

    def ack(self, command, result):
        self.results[command['command_id']] = result
        while len(self.results) > 32: self.results.popitem(last=False)
        self.publish('events', {'action':'remote_ack', 'protocol':2, 'sender':'linux', 'stream_id':self.stream,
            'session_id':command.get('session_id'), 'command_id':command['command_id'], 'result':result, 'device_time':int(self.clock()*1000)})

    def stop(self, reason):
        if self.active:
            self.publish('events', {'action':'remote_summary','sender':'linux','stream_id':self.stream,
                'upload_bytes':self.upload,'download_bytes':self.download,'duration_ms':int((self.monotonic()-self.started)*1000),
                'reason':reason,'complete':reason=='last_viewer_left'})
        self.active = False
        self.deadline = 0
        self.frames.clear()

    def receive(self, envelope, retained=False):
        if retained or not self.enabled or len(compact(envelope)) > 20000: return False
        try:
            encoded = envelope['data']
            if envelope.get('action') != 'remote_v2' or len(encoded) > 16384: return False
            self.signing_key.verify(un64(envelope['signature']), encoded.encode(), padding.PKCS1v15(), hashes.SHA256())
            box = json.loads(un64(encoded))
            command = json.loads(AESGCM(self.unwrap(box['key'])).decrypt(un64(box['iv']), un64(box['ciphertext']), None))
            now = self.clock()*1000
            if command['protocol'] != 2 or command['player_code'] != self.code: return False
            if not (command['issued_at'] <= now+5000 and now < command['expires_at'] <= now+35000): return False
            if command['revision'] <= self.revision:
                # A duplicate may be acknowledged, but can never execute twice.
                if command.get('stream_id') == self.stream and command.get('command_id') in self.results:
                    self.ack(command, self.results[command['command_id']])
                return False
            # A delayed command may not restore an earlier controller lease.
            if command['stream_id'] == self.stream and command['controller_epoch'] < self.epoch: return False
            next_key = self.unwrap(command['wrapped_key'])
            self.atomic(self.revision_file, str(int(command['revision'])).encode())
            self.revision = command['revision']
            if command['stream_id'] != self.stream:
                self.stop('replaced')
                self.stream = command['stream_id']
                self.started, self.sequence, self.upload, self.download, self.dropped = self.monotonic(), 0, 0, 0, 0
            self.key = next_key
            self.download += len(compact(envelope))
            if command['controller_epoch'] != self.epoch or command.get('controller') != self.controller:
                self.frames.clear()
            self.epoch, self.controller = command['controller_epoch'], command.get('controller')
            self.deadline = self.monotonic()+max(0,min(30,(command['lease_until']-now)/1000))
            self.high = command.get('quality') == 'high'
            if command['viewers'] <= 0 or self.deadline <= self.monotonic(): self.stop('last_viewer_left')
            else: self.active = True
            if command.get('input') is not None: self.execute(command)
            else: self.ack(command, 'accepted')
            return True
        except Exception:
            # Never log the command, encrypted keys, or typed text.
            return False

    def wayland_frame(self, path):
        """One full-output grim frame at path; returns its (width, height).
        PNG (fastest level): some grim builds have no JPEG (Ubuntu 26.04:
        "jpeg support disabled"). Pillow reads it and re-encodes the JPEG."""
        run('grim','-t','png','-l','1',str(path))
        with Image.open(path) as image: size = image.size
        self.last_size = size
        return size

    def geometry(self):
        if self.wayland:
            if self.last_size is None:
                with tempfile.TemporaryDirectory(prefix='signagex-remote-') as directory:
                    self.wayland_frame(pathlib.Path(directory)/'size.jpg')
            width, height = self.last_size
            if not (0 < width <= 16384 and 0 < height <= 16384): raise ValueError('Invalid display')
            return width, height, f'{width}x{height}:wayland'
        width, height = map(int, run('xdotool','getdisplaygeometry').split())
        if not (0 < width <= 16384 and 0 < height <= 16384): raise ValueError('Invalid display')
        # Include rotation so a square or identically-sized output is fenced too.
        rotation = run('xrandr','--current')
        connected = '\n'.join(line for line in rotation.splitlines() if ' connected' in line)
        return width, height, f'{width}x{height}:{connected}'

    def execute(self, command):
        item = command['input']
        if not (self.active and self.monotonic() < self.deadline and command['expires_at'] > self.clock()*1000
                and command['controller_epoch'] == self.epoch and command.get('session_id') == self.controller
                and command['stream_id'] == self.stream):
            self.ack(command,'expired'); return
        try:
            width, height, geometry = self.geometry()
            action = item['action']
            if action in ('click','scroll','long_press'):
                frame = self.frames.get(item.get('frame_id'))
                if not frame or self.monotonic()-frame[0] > 5 or frame[1] != geometry:
                    self.ack(command,'stale_frame'); return
            def point(value):
                x,y = value['x'],value['y']
                if any(isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) or not 0 <= v <= 1 for v in (x,y)):
                    raise ValueError('Invalid coordinates')
                return str(min(width-1,int(x*width))),str(min(height-1,int(y*height)))
            # The player also gets Back, so a kiosk page (no browser history) goes
            # one screen back; the key below still covers everything else.
            if action == 'press_back': self.emit({'navigate':'back'})
            if self.wayland:
                self.ack(command,self.execute_wayland(action, item)); return
            if action == 'click': run('xdotool','mousemove','--sync',*point(item),'click','1')
            elif action in ('scroll','long_press'):
                start,end = (point(item['hold']),point(item['release'])) if action == 'scroll' else (point(item),point(item))
                run('xdotool','mousemove','--sync',*start,'mousedown','1')
                try:
                    time.sleep(0.7 if action == 'long_press' else 0.15)
                    run('xdotool','mousemove','--sync',*end)
                finally: run('xdotool','mouseup','1')
            elif action == 'send_text':
                text = item['message']
                if not isinstance(text,str) or len(text)>512 or '\0' in text: raise ValueError('Invalid text')
                run('xdotool','type','--clearmodifiers','--delay','1','--',text)
            elif action == 'press_back': run('xdotool','key','--clearmodifiers','alt+Left')
            elif action in ('press_home','resume_player'):
                window = run('xdotool','search','--onlyvisible','--name','SignageX Player').splitlines()[-1]
                run('xdotool','windowactivate','--sync',window)
            elif action == 'restart_player' and item.get('confirmed') is True:
                run('systemd-run','--user','--unit=signagex-remote-restart','--collect','--on-active=1s',
                    '/usr/bin/systemctl','--user','restart','signagex-player.service')
            elif action == 'reboot_device':
                self.ack(command,'permission_required'); return
            else:
                self.ack(command,'unsupported_or_invalid'); return
            self.ack(command,'executed')
        except subprocess.TimeoutExpired: self.ack(command,'timeout')
        except Exception: self.ack(command,'unsupported_or_invalid')

    def execute_wayland(self, action, item):
        """Wayland input; returns the receipt result."""
        def fraction(value):
            x,y = value['x'],value['y']
            if any(isinstance(v,bool) or not isinstance(v,(int,float)) or not math.isfinite(v) or not 0 <= v <= 1 for v in (x,y)):
                raise ValueError('Invalid coordinates')
            return x,y
        if action in ('click','scroll','long_press','send_text','press_back'):
            if wayland_input.missing(): return 'unsupported_or_invalid'
            if self.input is None: self.input = wayland_input.WaylandInput()
        if action == 'click': self.input.tap(*fraction(item))
        elif action == 'scroll': self.input.drag(*fraction(item['hold']), *fraction(item['release']), 150)
        elif action == 'long_press':
            x,y = fraction(item); self.input.drag(x,y,x,y,700)
        elif action == 'send_text':
            text = item['message']
            if not isinstance(text,str) or len(text)>512 or '\0' in text: raise ValueError('Invalid text')
            self.input.type(text)
        elif action == 'press_back': self.input.key('alt+Left')
        elif action in ('press_home','resume_player'):
            pass  # The cage kiosk shows only the player; it is always in front.
        elif action == 'restart_player' and item.get('confirmed') is True:
            # The kiosk session restarts the player when it exits (session wrapper loop).
            subprocess.Popen(['/bin/sh','-c',f'sleep 1; kill -TERM {os.getppid()}'],
                             start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif action == 'reboot_device': return 'permission_required'
        else: return 'unsupported_or_invalid'
        return 'executed'

    def sign_ota(self, data):
        """Sign a CMS report (update or network status) with the persistent device key."""
        if not isinstance(data, str) or len(data) > 8192: return None
        signature = self.private.sign(data.encode(), padding.PKCS1v15(), hashes.SHA256())
        return {'data':data, 'key':self.public_key, 'signature':b64(signature)}

    def verify_ota(self, envelope):
        """Check a CMS 'update now' command; returns (job, None) or (None, reason).
        Verification only -- the player runs the root updater, which still trusts
        nothing but its packaged release channel."""
        try:
            data = envelope['data']
            if not isinstance(data, str) or len(data) > 4096: return None, 'invalid'
            self.signing_key.verify(un64(envelope['signature']), data.encode(), padding.PKCS1v15(), hashes.SHA256())
            command = json.loads(data)
        except Exception: return None, 'bad_signature'
        if command.get('protocol') != 'linux_ota_v1' or command.get('player') != self.code: return None, 'wrong_player'
        if command.get('key') != self.public_key: return None, 'wrong_key'
        issued, now = command.get('issued'), self.clock()*1000
        if type(issued) is not int or not (now-60000 <= issued <= now+5000): return None, 'stale'
        fence = self.directory/'ota-issued'
        try: last = int(fence.read_text())
        except (OSError, ValueError): last = 0
        if issued <= last: return None, 'replayed'
        self.atomic(fence, str(issued).encode())
        return {name: command.get(name) for name in ('job','version','platform','sha256','issued')}, None

    def verify_network(self, envelope):
        """Check a CMS Wi-Fi command; returns (job, None) or (None, reason). The
        password arrives encrypted to this device's key and is only decrypted here,
        after the server signature, player, key and freshness checks pass."""
        try:
            data = envelope['data']
            if not isinstance(data, str) or len(data) > 4096: return None, 'invalid'
            self.signing_key.verify(un64(envelope['signature']), data.encode(), padding.PKCS1v15(), hashes.SHA256())
            command = json.loads(data)
        except Exception: return None, 'bad_signature'
        if command.get('protocol') != 'linux_network_v1' or command.get('player') != self.code: return None, 'wrong_player'
        if command.get('key') != self.public_key: return None, 'wrong_key'
        issued, now = command.get('issued'), self.clock()*1000
        if type(issued) is not int or not (now-60000 <= issued <= now+5000): return None, 'stale'
        op, ssid, job = command.get('op'), command.get('ssid'), command.get('job')
        if op not in ('wifi_add','wifi_remove') or not isinstance(ssid, str) or not isinstance(job, str) \
                or not 0 < len(ssid.encode()) <= 32 or not 0 < len(job) <= 64:
            return None, 'invalid'
        password = ''
        if op == 'wifi_add' and command.get('secret') is not None:
            try: password = self.private.decrypt(un64(command['secret']), NETWORK_OAEP).decode()
            except Exception: return None, 'bad_secret'
        fence = self.directory/'network-issued'
        try: last = int(fence.read_text())
        except (OSError, ValueError): last = 0
        if issued <= last: return None, 'replayed'
        self.atomic(fence, str(issued).encode())
        return {'job':job, 'op':op, 'ssid':ssid, 'password':password, 'issued':issued,
                'hidden':command.get('hidden') is True, 'connect':command.get('connect') is True}, None

    def capture(self):
        if not self.enabled or not self.active: return
        if self.monotonic() >= self.deadline: self.stop('expired'); return
        captured = int(self.clock()*1000)
        if not self.wayland: width,height,geometry = self.geometry()
        with tempfile.TemporaryDirectory(prefix='signagex-remote-') as directory:
            path = pathlib.Path(directory)/'frame.jpg'
            if self.wayland:
                width,height = self.wayland_frame(path)
                geometry = f'{width}x{height}:wayland'
            else: run('scrot','-z','-q','75',str(path))
            with Image.open(path) as image:
                image.thumbnail((1280,1280) if self.high else (800,800))
                output = io.BytesIO(); image.convert('RGB').save(output,format='JPEG',quality=78 if self.high else 60)
        if not self.active or self.monotonic() >= self.deadline: return
        if self.wayland: foreground = True  # the only client of the kiosk compositor
        else:
            try: foreground = 'signagex' in run('xdotool','getactivewindow','getwindowname').lower()
            except Exception: foreground = False
        can_input = not self.wayland or wayland_input.missing() is None
        self.sequence += 1
        frame_id = f'{self.boot}:{self.sequence}'
        self.frames[frame_id] = self.monotonic(),geometry
        while len(self.frames)>10: self.frames.popitem(last=False)
        self.publish('frame', {'action':'image','sender':'linux','protocol':2,'img_url':b64(output.getvalue()),
            'stream_id':self.stream,'sequence':self.sequence,'frame_id':frame_id,'captured_at':captured,
            'capture_to_send_ms':int(self.clock()*1000)-captured,'input_width':width,'input_height':height,
            'can_tap':can_input,'can_text':can_input,'text_mode':'type','can_navigate':can_input,'can_resume':True,
            'can_restart':True,'can_reboot':False,'player_foreground':foreground,'process_id':self.boot,
            'geometry':geometry,'quality':'high' if self.high else 'low','upload_bytes':self.upload,
            'download_bytes':self.download,'upload_bps':int(self.upload/max(1,self.monotonic()-self.started)),
            'download_bps':int(self.download/max(1,self.monotonic()-self.started)),
            'duration_ms':int((self.monotonic()-self.started)*1000),'dropped_frames':self.dropped})

def ota_reply(remote, message):
    """Answer one CMS-update request; replies echo the caller's id so the player
    can match them to the request that asked."""
    request = message.get('id')
    if type(request) is not int: request = None
    if 'ota_sign' in message:
        signed = remote.sign_ota(message['ota_sign'])
        reply = {'ota_signed':signed} if signed else {'ota_rejected':'invalid'}
    elif 'network_command' in message:
        job, reason = remote.verify_network(message['network_command'])
        reply = {'network_verified':job} if job else {'ota_rejected':reason}
    else:
        job, reason = remote.verify_ota(message['ota_command'])
        reply = {'ota_verified':job} if job else {'ota_rejected':reason}
    reply['id'] = request
    return reply

def main():
    if len(sys.argv)!=2 or not sys.argv[1].isalnum(): raise ValueError('Player code required')
    def emit(value): print(json.dumps(value,separators=(',',':')),flush=True)
    remote = Remote(sys.argv[1], pathlib.Path.home()/'.local/share/signagex-player/remote-v2',emit)
    emit({'ready':True,'device_key':remote.public_key})
    incoming = queue.Queue(maxsize=8)
    def reader():
        while True:
            line=sys.stdin.buffer.readline(24000)
            if not line: os._exit(0)
            if not line.endswith(b'\n'): os._exit(1)
            try: incoming.put_nowait(json.loads(line))
            except (ValueError,queue.Full): pass
    threading.Thread(target=reader,daemon=True).start()
    next_capture = 0
    while True:
        try:
            message=incoming.get(timeout=0.1)
            if 'enabled' in message:
                remote.enabled=message['enabled'] is True
                if not remote.enabled: remote.stop('unavailable')
            elif 'envelope' in message: remote.receive(message['envelope'],message.get('retained') is True)
            # CMS app updates use the device identity whether or not remote view is enabled.
            elif 'ota_sign' in message or 'ota_command' in message or 'network_command' in message:
                emit(ota_reply(remote,message))
        except queue.Empty: pass
        if time.monotonic() >= next_capture:
            next_capture=time.monotonic()+1
            try: remote.capture()
            except Exception: remote.dropped+=1

if __name__=='__main__': main()
