#!/usr/bin/env python3
"""Generate Linux-only fixed sources for the pinned webview_cef 0.2.2.

The pub cache and other platforms are never modified. Fail on source drift.
"""
import hashlib
from pathlib import Path
import shutil
import sys

source, output = map(Path, sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
expected = {
    "webview_cef_plugin.cc": "278ed9ee69226255b00a78e513b329e4d8351786e22cdf56391ab1d2569bf3b9",
    "../common/webview_plugin.cc": "07015082a3d3f014dafae41c84eecf7bd103a62192b416e9a1ba30cc1eb4ecbf",
    "../common/webview_app.cc": "5dae0b4ef6399b9f8f70fc399a7b4719e4a2f0af2a1c33ce99fcef9342bff960",
    "../common/webview_handler.cc": "8ff8b2bc7eb8886062a836f79074c75dad68eca5f62e503a0181e39fa960b88c",
}
texts = {}
for name, digest in expected.items():
    data = (source / name).read_bytes()
    if hashlib.sha256(data).hexdigest() != digest:
        raise SystemExit(f"Unsupported webview_cef source: {name}; review Linux safety overrides")
    texts[name] = data.decode()

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise SystemExit(f"Expected exactly one patch anchor: {old[:70]!r}")
    return text.replace(old, new, 1)

bridge = texts["webview_cef_plugin.cc"]
bridge = replace_once(bridge, "register_ = texture_register;",
                      "register_ = FL_TEXTURE_REGISTRAR(g_object_ref(texture_register));")
bridge = replace_once(bridge, "    register_ = nullptr;", """    g_object_unref(texture);
    g_object_unref(register_);
    register_ = nullptr;""")
start = bridge.index("    texture->width = width;")
end = bridge.index("\n  }", start)
bridge = bridge[:start] + """    if (texture->frames->PublishBgra(buffer, width, height)) {
      fl_texture_registrar_mark_texture_frame_available(register_, FL_TEXTURE(texture));
    }""" + bridge[end:]
# Responding transfers no ownership of FlValue. Release the temporary value.
bridge = replace_once(bridge, """    if (ret > 0){
      fl_method_call_respond_success(method_call, encode_wavlue_to_flvalue(responseArgs), nullptr);
    }
    else if (ret < 0){
      fl_method_call_respond_error(method_call, "error", "error", encode_wavlue_to_flvalue(responseArgs), nullptr);
    }""", """    g_autoptr(FlValue) response = encode_wavlue_to_flvalue(responseArgs);
    if (ret > 0){
      fl_method_call_respond_success(method_call, response, nullptr);
    }
    else if (ret < 0){
      fl_method_call_respond_error(method_call, "error", "error", response, nullptr);
    }""")

common = texts["../common/webview_plugin.cc"]
common = replace_once(common, '#include "webview_plugin.h"',
    '#include "webview_plugin.h"\n#include <glib.h>\n#include <gtk/gtk.h>\n'
    'static bool signagex_loop_running = false;\nstatic bool signagex_shutdown_pending = false;')
# CEF runs the GTK main loop itself (CefRunMessageLoop). Driving it from a
# timer with external_message_pump left Chromium's own GLib work source
# attached to the default context but never run; its prepare step then
# returns a 0 ms timeout forever, so the GTK loop polled ~5000 times a second
# and held one core at 100% even on an idle screen. CefRunMessageLoop
# iterates the same default context, so GTK, Flutter and every CEF callback
# still run on the platform thread.
common = replace_once(common, '\t\tCefInitialize(mainArgs, cefs, app.get(), nullptr);', """#ifdef OS_LINUX
        cefs.external_message_pump = false;
        cefs.multi_threaded_message_loop = false;
#endif
        isCefInitialized = CefInitialize(mainArgs, cefs, app.get(), nullptr);
        if (isCefInitialized && !signagex_loop_running) {
            // Entered from an idle callback so the "init" call returns first;
            // the outer GTK loop waits until CEF's loop quits.
            g_idle_add([](gpointer) -> gboolean {
                signagex_loop_running = true;
                // A desktop window closing must still end the app.
                guint watch = g_timeout_add(500, [](gpointer) -> gboolean {
                    GApplication* application = g_application_get_default();
                    if (application && GTK_IS_APPLICATION(application) &&
                        gtk_application_get_windows(GTK_APPLICATION(application)) == nullptr) {
                        CefQuitMessageLoop();
                    }
                    return G_SOURCE_CONTINUE;
                }, nullptr);
                CefRunMessageLoop();
                g_source_remove(watch);
                signagex_loop_running = false;
                if (signagex_shutdown_pending && isCefInitialized) {
                    CefShutdown();
                    isCefInitialized = false;
                }
                return G_SOURCE_REMOVE;
            }, nullptr);
        }""")
common = replace_once(common, '\t\tCefShutdown();', """        if (signagex_loop_running) {
            // CefShutdown may only run once CefRunMessageLoop has returned.
            signagex_shutdown_pending = true;
            CefQuitMessageLoop();
            return;
        }
        if (isCefInitialized) {
            CefShutdown();
            isCefInitialized = false;
        }""")
common = replace_once(common, '\t\t\t\tm_renderers[browserId].reset();',
                      '\t\t\t\tm_renderers.erase(browserId);')
(output / "webview_cef_plugin.cc").write_text(bridge)
(output / "webview_plugin.cc").write_text(common)
app = texts["../common/webview_app.cc"]
app = replace_once(app, '#include <string>', '#include <string>\n#include <cstdlib>')
app = replace_once(app, '\tif (process_type.empty())\n\t{', '''\tif (process_type.empty())
\t{
        // An unattended kiosk has no interactive login to unlock libsecret.
        // Keep desktop launches on their usual OS keyring. Kiosk browser
        // profile data relies on the player account's filesystem permissions.
        const char* kiosk = std::getenv("SIGNAGEX_KIOSK");
        if (kiosk && std::string(kiosk) == "1") {
            command_line->AppendSwitchWithValue("password-store", "basic");
        }''')
(output / "webview_app.cc").write_text(app)
handler = texts["../common/webview_handler.cc"]
handler = replace_once(handler, '#include "webview_handler.h"',
    '#include "webview_handler.h"\n#include "page_frame_gate.h"\nstatic signagex::PageFrameGate signagex_page_frames;')
handler = replace_once(handler, '    CefBrowserSettings browser_settings ;',
    '    CefBrowserSettings browser_settings ;\n    browser_settings.background_color = 0xFF000000;')
handler = replace_once(handler, '        browser_map_.emplace(browser->GetIdentifier(), browser_info());',
    '        signagex_page_frames.Begin(browser->GetIdentifier());\n        browser_map_.emplace(browser->GetIdentifier(), browser_info());')
handler = replace_once(handler, '    if(onLoadStart){',
    '    if (frame->IsMain()) signagex_page_frames.Begin(browser->GetIdentifier());\n    if(onLoadStart){')
handler = replace_once(handler, 'void WebviewHandler::OnBeforeClose(CefRefPtr<CefBrowser> browser) {',
    'void WebviewHandler::OnBeforeClose(CefRefPtr<CefBrowser> browser) {\n    signagex_page_frames.Close(browser->GetIdentifier());')
handler = replace_once(handler, '    if (!browser->IsPopup() && onPaintCallback != nullptr) {',
    '    if (!browser->IsPopup() && signagex_page_frames.Ready(browser->GetIdentifier()) && onPaintCallback != nullptr) {')

handler = replace_once(handler, '''    // Allow Chrome to show the error page.''', '''    // Forward main-frame failures before Chrome replaces the document with
    // its own error page. No JavaScript bridge or document inspection needed.
    if (frame->IsMain() && errorCode != ERR_ABORTED && onLoadEnd) {
        signagex_page_frames.Loaded(browser->GetIdentifier(), false);
        onLoadEnd(browser->GetIdentifier(),
                  "signagex-load-failed:" + std::to_string(int(errorCode)));
        return; // Keep the last usable texture instead of an HTML error page.
    }

    // Allow Chrome to show the error page.''')
handler = replace_once(handler, '''    if(onLoadEnd){
        onLoadEnd(browser->GetIdentifier(), frame->GetURL());
    }''', '''    // Do not mistake Chrome/data error documents (status 0) or a child
    // frame's successful load for recovery of the main document.
    const std::string url = frame->GetURL().ToString();
    if (onLoadEnd && frame->IsMain() &&
        (httpStatusCode > 0 || url.rfind("file:", 0) == 0 || url.rfind("data:", 0) == 0)) {
        signagex_page_frames.Loaded(browser->GetIdentifier(), httpStatusCode < 400);
        onLoadEnd(browser->GetIdentifier(), httpStatusCode >= 400
            ? "signagex-load-failed:" + std::to_string(httpStatusCode) : url);
    }''')
(output / "webview_handler.cc").write_text(handler)
for name in ("frame_store.h", "webview_cef_texture.h", "page_frame_gate.h"):
    shutil.copyfile(Path(__file__).parent / name, output / name)
print("Prepared CEF-run platform-thread loop and lifetime-safe texture sources")
