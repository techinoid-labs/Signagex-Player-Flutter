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
    '#include "webview_plugin.h"\n#include <glib.h>\nstatic guint signagex_cef_pump = 0;')
common = replace_once(common, '#ifdef OS_MAC\n\t\t//cef message loop handle by MainApplication on mac',
    '#if defined(OS_MAC) || defined(OS_LINUX)\n\t\t// Linux CEF callbacks must share GTK/Flutter platform-thread ownership.')
common = replace_once(common, '\t\tCefInitialize(mainArgs, cefs, app.get(), nullptr);', """        isCefInitialized = CefInitialize(mainArgs, cefs, app.get(), nullptr);
        if (isCefInitialized && signagex_cef_pump == 0) {
            signagex_cef_pump = g_timeout_add(10, [](gpointer) -> gboolean {
                CefDoMessageLoopWork();
                return G_SOURCE_CONTINUE;
            }, nullptr);
        }""")
common = replace_once(common, '\t\tCefShutdown();', """        if (signagex_cef_pump != 0) {
            g_source_remove(signagex_cef_pump);
            signagex_cef_pump = 0;
        }
        if (isCefInitialized) {
            CefShutdown();
            isCefInitialized = false;
        }""")
common = replace_once(common, '\t\t\t\tm_renderers[browserId].reset();',
                      '\t\t\t\tm_renderers.erase(browserId);')
(output / "webview_cef_plugin.cc").write_text(bridge)
(output / "webview_plugin.cc").write_text(common)
for name in ("frame_store.h", "webview_cef_texture.h"):
    shutil.copyfile(Path(__file__).parent / name, output / name)
print("Prepared thread-owned CEF loop and lifetime-safe texture sources")
