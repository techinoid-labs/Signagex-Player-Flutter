#include <webview_cef/webview_cef_plugin.h>

#include <cstring>

#include "my_application.h"

// Whether this process was launched by CEF as one of its own child
// processes rather than by a user.
//
// CEF runs its renderer, GPU and utility work as child processes, and each
// one is THIS SAME EXECUTABLE re-launched with extra arguments. Every such
// launch carries a --type= switch naming the role; the browser process
// never has one. That switch is the only thing distinguishing the two, and
// checking it is CEF's own documented idiom.
static bool IsCefChildProcess(int argc, char** argv) {
  for (int i = 1; i < argc; i++) {
    if (std::strncmp(argv[i], "--type=", 7) == 0) return true;
  }
  return false;
}

int main(int argc, char** argv) {
  const bool is_cef_child = IsCefChildProcess(argc, argv);

  // Runs CefExecuteProcess. For a child that does the child's entire job
  // and returns when it is finished; for the browser process it returns
  // immediately and startup carries on below.
  initCEFProcesses(argc, argv);

  if (is_cef_child) {
    // A child MUST stop here.
    //
    // webview_cef 0.5.0+ returns CefExecuteProcess's exit code so the
    // caller can return it, and this file was written for that:
    //
    //   int exit_code = initCEFProcesses(argc, argv);
    //   if (exit_code >= 0) return exit_code;
    //
    // Version 0.2.2 -- which this project pins, because 0.5+ bundles a CEF
    // that needs a newer compiler than the build image has -- returns void
    // AND discards the exit code:
    //
    //   void initCEFProcesses(){
    //       app = new WebviewApp();
    //       CefExecuteProcess(mainArgs, app, nullptr);
    //   }
    //
    // So there is nothing to propagate and nothing stopping a child from
    // falling through. Without this return, every renderer and GPU process
    // continues into g_application_run below and tries to start a second
    // copy of the whole application -- which is what "the application has
    // closed unexpectedly" was.
    return 0;
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
