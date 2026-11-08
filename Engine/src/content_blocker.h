// Network privacy core: tracker/ad domain blocking, HTTPS upgrades, GPC.
//
// Called from Chromium's IO thread for every subresource request, so lookups
// are allocation-free (string_view + transparent hashing) and rule swaps are
// atomic. Pure C++ — no CEF or Objective-C dependencies — so it can be unit
// tested and reused when Wink moves to a full Chromium fork.

#ifndef WINK_ENGINE_CONTENT_BLOCKER_H_
#define WINK_ENGINE_CONTENT_BLOCKER_H_

#include <atomic>
#include <cstddef>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <unordered_set>
#include <vector>

namespace wink {

struct StringViewHash {
  using is_transparent = void;
  size_t operator()(std::string_view s) const noexcept {
    return std::hash<std::string_view>{}(s);
  }
};

using DomainSet = std::unordered_set<std::string, StringViewHash, std::equal_to<>>;

// Compact, immutable rule storage: one text buffer plus sorted views into it
// (~16 bytes per rule instead of a heap node per string). Lookups are a
// binary search — allocation-free and ~1µs for ~100k rules.
struct RuleSet {
  std::string buffer;
  std::vector<std::string_view> domains;

  bool Contains(std::string_view domain) const;
  size_t size() const { return domains.size(); }
  bool empty() const { return domains.empty(); }
};

class ContentBlocker {
 public:
  static ContentBlocker& Get();

  // Parses a newline-separated domain list and atomically installs it.
  // Returns the number of rules loaded.
  size_t LoadRules(std::string_view text);
  size_t RuleCount() const;

  // True if a subresource request to |url| issued from a page whose top-level
  // site is |first_party_url| should be blocked. Never blocks first-party
  // requests. |matched_host| receives the request host when blocked.
  bool ShouldBlock(std::string_view url,
                   std::string_view first_party_url,
                   std::string* matched_host) const;

  // HTTPS upgrade policy for a top-level http:// navigation to |host|.
  bool ShouldUpgradeToHttps(std::string_view host) const;
  void NoteUpgraded(std::string_view host);
  bool WasUpgraded(std::string_view host) const;
  void ClearUpgraded(std::string_view host);
  void AllowInsecureHost(std::string_view host);
  bool IsInsecureHostAllowed(std::string_view host) const;

  void SetAllowlistedSites(const std::vector<std::string>& sites);
  bool IsSiteAllowlisted(std::string_view first_party_host) const;

  std::atomic<bool> blocking_enabled{true};
  std::atomic<bool> https_upgrades_enabled{true};
  std::atomic<bool> gpc_enabled{true};

  // URL helpers (no allocation; views point into the input).
  static std::string_view HostOf(std::string_view url);
  static std::string_view SchemeOf(std::string_view url);
  static std::string_view RegistrableDomain(std::string_view host);
  static bool IsLocalOrPrivateHost(std::string_view host);

 private:
  ContentBlocker() = default;

  std::shared_ptr<const RuleSet> Rules() const;

  mutable std::mutex mutex_;
  std::shared_ptr<const RuleSet> rules_;
  DomainSet allowlist_;
  DomainSet insecure_allowed_;
  DomainSet upgraded_;
};

}  // namespace wink

#endif  // WINK_ENGINE_CONTENT_BLOCKER_H_
