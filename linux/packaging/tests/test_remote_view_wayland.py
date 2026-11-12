import importlib.util, json, pathlib, unittest
from unittest.mock import MagicMock, patch

here = pathlib.Path(__file__).parent
spec = importlib.util.spec_from_file_location('remote_view_base', here/'test_remote_view.py')
base = importlib.util.module_from_spec(spec); spec.loader.exec_module(base)
agent = base.agent
# Kept in a dict so unittest discovery does not run the base class again here.
_shared = {"base": base.RemoteProtocolTests}

class WaylandRemoteTests(unittest.TestCase):
    """The same signed protocol, with grim frames and uinput input (cage kiosk)."""
    setUpClass = _shared["base"].__dict__["setUpClass"]
    tearDown = _shared["base"].tearDown
    command = _shared["base"].command
    open = _shared["base"].open

    def setUp(self):
        _shared["base"].setUp(self)
        self.remote.wayland = True
        self.remote.input = MagicMock()

    def result(self): return self.open(self.output[-1]['payload'])['result']

    def test_click_uses_fractions_on_the_virtual_pointer(self):
        with patch.object(self.remote,'geometry',return_value=(1920,1080,'1920x1080:wayland')), \
             patch.object(agent,'run') as run, patch.object(agent.wayland_input,'missing',return_value=None):
            # Joining starts the session (and clears old frames); then a frame, then the click.
            self.remote.receive(self.command())
            self.remote.frames['frame']=(100,'1920x1080:wayland')
            self.remote.receive(self.command(revision=2,command_id='command-2',input={'action':'click','x':0.25,'y':0.75,'frame_id':'frame'}))
            run.assert_not_called()
        self.remote.input.tap.assert_called_once_with(0.25,0.75)
        self.assertEqual(self.result(),'executed')

    def test_text_and_back_go_to_the_virtual_keyboard_and_stay_out_of_receipts(self):
        text='hello "world"'
        with patch.object(self.remote,'geometry',return_value=(1920,1080,'g')), \
             patch.object(agent.wayland_input,'missing',return_value=None):
            self.remote.receive(self.command(input={'action':'send_text','message':text}))
            self.remote.receive(self.command(revision=2,command_id='command-2',input={'action':'press_back'}))
        self.remote.input.type.assert_called_once_with(text)
        self.remote.input.key.assert_called_once_with('alt+Left')
        self.assertIn({'navigate':'back'},self.output)  # the player sends it to a kiosk page
        self.assertNotIn(text,json.dumps(self.output))

    def test_missing_uinput_is_reported_not_faked(self):
        with patch.object(self.remote,'geometry',return_value=(1920,1080,'g')), \
             patch.object(agent.wayland_input,'missing',return_value='no uinput'):
            self.remote.receive(self.command(input={'action':'press_back'}))
        self.assertEqual(self.result(),'unsupported_or_invalid')
        self.remote.input.key.assert_not_called()

    def test_home_is_a_no_op_because_the_player_is_always_in_front(self):
        with patch.object(self.remote,'geometry',return_value=(1920,1080,'g')), patch.object(agent,'run') as run:
            self.remote.receive(self.command(input={'action':'press_home'}))
            run.assert_not_called()
        self.assertEqual(self.result(),'executed')

    def test_rotated_screen_is_sent_turned_and_clicks_are_turned_back(self):
        listing='eDP-1 "Panel"\n  Enabled: yes\n  Transform: 270\n'
        def capture(*arguments):
            if arguments[0] == 'grim':
                image=agent.Image.new('RGB',(1920,1080),(255,255,255))
                image.putpixel((0,0),(255,0,0))  # upright top-left
                image.save(arguments[-1])
            return listing if arguments[0] == 'wlr-randr' else ''
        self.remote.receive(self.command())
        with patch.object(agent,'run',side_effect=capture), patch.object(agent.wayland_input,'missing',return_value=None):
            self.remote.capture()
            frame=self.open(self.output[-1]['payload'])
            self.assertEqual((frame['input_width'],frame['input_height']),(1080,1920))
            self.assertEqual(frame['geometry'],'1080x1920:wayland:270')
            self.remote.receive(self.command(revision=2,command_id='command-2',input={'action':'click','x':1.0,'y':0.0,'frame_id':frame['frame_id']}))
        # CMS 90 (clockwise) is Wayland 270: the upright top-left shows top-right.
        self.remote.input.tap.assert_called_once_with(0.0,0.0)
        self.assertEqual(agent.upright_point(0.25,0.75,'180'),(0.75,0.25))
        self.assertEqual(agent.upright_point(0.0,1.0,'90'),(0.0,0.0))
        self.assertEqual(agent.output_transform('HDMI-A-1 "x"\n  Enabled: no\n  Transform: 90\n'+listing),'270')

    def test_frame_comes_from_grim_with_the_output_size(self):
        self.remote.receive(self.command())
        calls=[]
        def capture(*arguments):
            calls.append(arguments[0])
            if arguments[0] == 'grim': agent.Image.new('RGB',(1920,1080),(1,2,3)).save(arguments[-1])
            return ''
        with patch.object(agent,'run',side_effect=capture), patch.object(agent.wayland_input,'missing',return_value='no uinput'):
            self.remote.capture()
        self.assertEqual(calls,['grim','wlr-randr'])
        frame=self.open(self.output[-1]['payload'])
        self.assertEqual((frame['input_width'],frame['input_height']),(1920,1080))
        self.assertEqual(frame['geometry'],'1920x1080:wayland:normal')
        self.assertTrue(frame['player_foreground'])
        self.assertFalse(frame['can_tap'])

if __name__ == '__main__': unittest.main()
