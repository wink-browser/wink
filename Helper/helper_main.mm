// Wink Helper — entry point for every Chromium child process (renderer, GPU,
// network, utility, ...). Runs inside the macOS sandbox.

#include <cstring>

#include "include/cef_app.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_v8.h"
#include "include/wrapper/cef_library_loader.h"

#if defined(CEF_USE_SANDBOX)
#include "include/cef_sandbox_mac.h"
#endif

namespace {

// Renderer-side hooks. Kept deliberately tiny: anything injected here runs in
// every frame of every page.
class WinkRendererApp : public CefApp, public CefRenderProcessHandler {
 public:
  explicit WinkRendererApp(bool gpc) : gpc_(gpc) {}

  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    if (!gpc_) return;
    // Global Privacy Control (https://globalprivacycontrol.org): the
    // matching `Sec-GPC: 1` header is added by the browser process.
    CefRefPtr<CefV8Value> retval;
    CefRefPtr<CefV8Exception> exception;
    context->Eval(
        "Object.defineProperty(Navigator.prototype,'globalPrivacyControl',"
        "{get(){return true},configurable:true,enumerable:true});",
        CefString(), 0, retval, exception);
  }

 private:
  const bool gpc_;
  IMPLEMENT_REFCOUNTING(WinkRendererApp);
};

bool HasSwitch(int argc, char* argv[], const char* name) {
  for (int i = 1; i < argc; ++i) {
    if (std::strcmp(argv[i], name) == 0) return true;
  }
  return false;
}

}  // namespace

int main(int argc, char* argv[]) {
#if defined(CEF_USE_SANDBOX)
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) return 1;
#endif

  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) return 1;

  CefMainArgs main_args(argc, argv);
  CefRefPtr<CefApp> app = new WinkRendererApp(HasSwitch(argc, argv, "--wink-gpc"));
  return CefExecuteProcess(main_args, app, nullptr);
}
