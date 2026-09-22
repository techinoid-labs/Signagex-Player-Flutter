#include <webview_cef/webview_cef_plugin.h>
#include "my_application.h"

int main(int argc, char** argv) {
  // CEF runs its renderer and GPU work as child processes, which are this
  // same executable re-launched with different arguments. initCEFProcesses
  // is what recognises that and runs the child's work instead of ours.
  //
  // It returns void here, and does NOT return void in webview_cef 0.5.0 and
  // later, where it hands back an exit code and the caller is expected to
  // return it immediately:
  //
  //   int exit_code = initCEFProcesses(argc, argv);
  //   if (exit_code >= 0) return exit_code;
  //
  // That is what this file used to do, and it stopped compiling when the
  // plugin was pinned back below CEF 149:
  //
  //   error: cannot initialize a variable of type 'int' with an rvalue of
  //          type 'void'
  //
  // In this version the subprocess case is handled inside the call, so
  // there is no exit code to propagate and no early return to make. If the
  // pin is ever lifted back to 0.5.0+, this has to go back to the form
  // above -- otherwise every CEF child process would fall through and try
  // to open its own application window.
  initCEFProcesses(argc, argv);

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
