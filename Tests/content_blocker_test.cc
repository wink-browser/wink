// Unit tests for the engine's network privacy core (no Chromium needed).
//   cmake --build build --target wink_tests && ./build/wink_tests

#include <cstdio>
#include <string>

#include "content_blocker.h"

using wink::ContentBlocker;

static int failures = 0;
static int checks = 0;

#define EXPECT(cond)                                                    \
  do {                                                                  \
    ++checks;                                                           \
    if (!(cond)) {                                                      \
      ++failures;                                                       \
      std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
    }                                                                   \
  } while (0)

int main() {
  // URL parsing
  EXPECT(ContentBlocker::HostOf("https://user:pw@sub.example.com:8080/path?x#y") == "sub.example.com");
  EXPECT(ContentBlocker::HostOf("http://[::1]:3000/") == "[::1]");
  EXPECT(ContentBlocker::HostOf("https://example.com") == "example.com");
  EXPECT(ContentBlocker::HostOf("https://example.com./") == "example.com");
  EXPECT(ContentBlocker::HostOf("data:text/html,hi").empty());
  EXPECT(ContentBlocker::SchemeOf("wss://x.y/z") == "wss");

  // Registrable domains (eTLD+1 approximation)
  EXPECT(ContentBlocker::RegistrableDomain("news.bbc.co.uk") == "bbc.co.uk");
  EXPECT(ContentBlocker::RegistrableDomain("a.b.example.com") == "example.com");
  EXPECT(ContentBlocker::RegistrableDomain("example.com") == "example.com");
  EXPECT(ContentBlocker::RegistrableDomain("foo.github.io") == "foo.github.io");
  EXPECT(ContentBlocker::RegistrableDomain("x.foo.github.io") == "foo.github.io");
  EXPECT(ContentBlocker::RegistrableDomain("127.0.0.1") == "127.0.0.1");

  // Local / private hosts are never upgraded
  EXPECT(ContentBlocker::IsLocalOrPrivateHost("localhost"));
  EXPECT(ContentBlocker::IsLocalOrPrivateHost("app.localhost"));
  EXPECT(ContentBlocker::IsLocalOrPrivateHost("192.168.1.20"));
  EXPECT(ContentBlocker::IsLocalOrPrivateHost("10.0.0.1"));
  EXPECT(ContentBlocker::IsLocalOrPrivateHost("172.20.1.1"));
  EXPECT(ContentBlocker::IsLocalOrPrivateHost("printer"));
  EXPECT(ContentBlocker::IsLocalOrPrivateHost("mac.local"));
  EXPECT(!ContentBlocker::IsLocalOrPrivateHost("172.32.0.1"));
  EXPECT(!ContentBlocker::IsLocalOrPrivateHost("8.8.8.8"));
  EXPECT(!ContentBlocker::IsLocalOrPrivateHost("example.com"));

  auto& blocker = ContentBlocker::Get();
  size_t loaded = blocker.LoadRules(
      "# comment\n"
      "Tracker.com\n"
      "0.0.0.0 ads.example.net\n"
      "pixel.io$third-party\n"
      "bad/path\n"
      "  spaced.org  \n"
      "tracker.com\n");
  EXPECT(loaded == 4);
  EXPECT(blocker.RuleCount() == 4);

  // Third-party requests to listed domains (and subdomains) are blocked
  EXPECT(blocker.ShouldBlock("https://x.tracker.com/a.js", "https://news.site/", nullptr));
  EXPECT(blocker.ShouldBlock("https://tracker.com/a.js", "https://news.site/", nullptr));
  EXPECT(blocker.ShouldBlock("https://ads.example.net/b", "https://news.site/", nullptr));
  EXPECT(blocker.ShouldBlock("wss://pixel.io/live", "https://news.site/", nullptr));
  std::string matched;
  EXPECT(blocker.ShouldBlock("https://cdn.spaced.org/x", "https://news.site/", &matched) && matched == "cdn.spaced.org");

  // ...but never first-party requests, label-boundary lookalikes, or non-web schemes
  EXPECT(!blocker.ShouldBlock("https://tracker.com/a.js", "https://tracker.com/", nullptr));
  EXPECT(!blocker.ShouldBlock("https://sub.tracker.com/a.js", "https://www.tracker.com/", nullptr));
  EXPECT(!blocker.ShouldBlock("https://notracker.com/a.js", "https://news.site/", nullptr));
  EXPECT(!blocker.ShouldBlock("https://example.net/", "https://news.site/", nullptr));
  EXPECT(!blocker.ShouldBlock("data:image/png;base64,AAAA", "https://news.site/", nullptr));
  EXPECT(!blocker.ShouldBlock("https://com/", "https://news.site/", nullptr));

  // Per-site "shields down"
  blocker.SetAllowlistedSites({"www.news.site"});
  EXPECT(!blocker.ShouldBlock("https://x.tracker.com/a.js", "https://news.site/", nullptr));
  EXPECT(blocker.ShouldBlock("https://x.tracker.com/a.js", "https://other.site/", nullptr));
  blocker.SetAllowlistedSites({});

  // Global switch
  blocker.blocking_enabled = false;
  EXPECT(!blocker.ShouldBlock("https://x.tracker.com/a.js", "https://news.site/", nullptr));
  blocker.blocking_enabled = true;

  // HTTPS upgrades with fallback memory
  EXPECT(blocker.ShouldUpgradeToHttps("example.com"));
  EXPECT(!blocker.ShouldUpgradeToHttps("localhost"));
  EXPECT(!blocker.ShouldUpgradeToHttps("192.168.0.4"));
  blocker.NoteUpgraded("legacy.example");
  EXPECT(blocker.WasUpgraded("legacy.example"));
  blocker.ClearUpgraded("legacy.example");
  EXPECT(!blocker.WasUpgraded("legacy.example"));
  blocker.AllowInsecureHost("legacy.example");
  EXPECT(!blocker.ShouldUpgradeToHttps("legacy.example"));
  blocker.https_upgrades_enabled = false;
  EXPECT(!blocker.ShouldUpgradeToHttps("example.com"));

  std::printf("%d checks, %d failures\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
