#!/usr/bin/env python3
"""Forward main-frame CEF load failures without relying on the JS bridge."""
import sys
from pathlib import Path


def patch(path):
    source = path.read_text()
    marker = '// SIGNAGEX_NATIVE_LOAD_EVENTS'
    if marker in source:
        return
    start = source.index('void WebviewHandler::OnLoadError(')
    insert = source.index('    // Allow Chrome to show the error page.', start)
    source = source[:insert] + """    // SIGNAGEX_NATIVE_LOAD_EVENTS
    // Aborted navigations and child-frame failures are not page failures.
    if (frame->IsMain() && errorCode != ERR_ABORTED && onLoadEnd) {
        onLoadEnd(browser->GetIdentifier(),
                  "signagex-load-failed:" + std::to_string(int(errorCode)));
    }

""" + source[insert:]
    old = """    if(onLoadEnd){
        onLoadEnd(browser->GetIdentifier(), frame->GetURL());
    }"""
    start = source.index('void WebviewHandler::OnLoadEnd(')
    end = source.index('void WebviewHandler::CloseAllBrowsers', start)
    block = source[start:end]
    if old not in block:
        raise ValueError('Unsupported CEF OnLoadEnd implementation')
    block = block.replace(old, """    // Error documents have status zero; do not mark them as recovered.
    const std::string url = frame->GetURL().ToString();
    if (onLoadEnd && frame->IsMain() &&
        (httpStatusCode > 0 || url.rfind("file:", 0) == 0)) {
        onLoadEnd(browser->GetIdentifier(), httpStatusCode >= 400
            ? "signagex-load-failed:" + std::to_string(httpStatusCode) : url);
    }""")
    source = source[:start] + block + source[end:]
    path.write_text(source)


if __name__ == '__main__':
    patch(Path(sys.argv[1]))
