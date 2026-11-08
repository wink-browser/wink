#import <WinkEngine/WinkApplication.h>

#include "include/cef_application_mac.h"

@interface WinkApplication () <CefAppProtocol>
@end

@implementation WinkApplication {
  BOOL _handlingSendEvent;
}

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  [super sendEvent:event];
}

// ⌘Q, Dock "Quit" and logout all arrive here. Browsers must close before the
// engine shuts down, so never call [super terminate:] — the termination
// handler closes everything and then quits the message loop.
- (void)terminate:(id)sender {
  if (self.terminationHandler) {
    self.terminationHandler();
  } else {
    [super terminate:sender];
  }
}

@end
