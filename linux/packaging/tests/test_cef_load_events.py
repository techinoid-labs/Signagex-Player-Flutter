import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('cef_patch', Path(__file__).parents[1] / 'patch_cef_load_events.py')
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)

# Pinned upstream handler boundaries. The build also applies this patch to the
# full dependency and compiles it, so upstream drift fails the release build.
SOURCE = '''void WebviewHandler::OnLoadError() {
    // Allow Chrome to show the error page.
    if (IsChromeRuntimeEnabled()) return;
}
void WebviewHandler::OnLoadEnd() {
    if(onLoadEnd){
        onLoadEnd(browser->GetIdentifier(), frame->GetURL());
    }
}
void WebviewHandler::CloseAllBrowsers() {}
'''

class LoadEventsTest(unittest.TestCase):
    def test_main_frame_failures_precede_chrome_error_document(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'handler.cc'
            path.write_text(SOURCE)
            patcher.patch(path)
            result = path.read_text()
            self.assertLess(result.index('errorCode != ERR_ABORTED'), result.index('IsChromeRuntimeEnabled'))
            self.assertIn('frame->IsMain()', result)
            self.assertIn('httpStatusCode >= 400', result)
            self.assertIn('httpStatusCode > 0 || url.rfind("file:", 0) == 0', result)
            self.assertIn('signagex-load-failed:', result)
            patcher.patch(path)
            self.assertEqual(path.read_text(), result)

    def test_unknown_upstream_fails_without_modifying_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'handler.cc'
            changed = SOURCE.replace('if(onLoadEnd)', 'if (different)')
            path.write_text(changed)
            with self.assertRaises(ValueError):
                patcher.patch(path)
            self.assertEqual(path.read_text(), changed)
