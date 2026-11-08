#include "content_blocker.h"

#include <algorithm>
#include <iterator>
#include <cctype>

namespace wink {

namespace {

// Multi-label public suffixes we treat as a single "TLD" when computing the
// registrable domain. A compact approximation of the Public Suffix List that
// covers the vast majority of real-world traffic.
constexpr std::string_view kMultiLabelSuffixes[] = {
    "co.uk", "org.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "ac.uk", "gov.uk",
    "nhs.uk", "sch.uk", "police.uk", "com.au", "net.au", "org.au", "edu.au",
    "gov.au", "asn.au", "id.au", "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz",
    "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp", "ed.jp", "gr.jp", "lg.jp",
    "co.kr", "or.kr", "ne.kr", "go.kr", "ac.kr", "com.br", "net.br", "org.br",
    "gov.br", "edu.br", "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
    "ac.cn", "com.hk", "net.hk", "org.hk", "edu.hk", "gov.hk", "com.tw",
    "net.tw", "org.tw", "edu.tw", "gov.tw", "com.sg", "net.sg", "org.sg",
    "edu.sg", "gov.sg", "com.my", "net.my", "org.my", "gov.my", "co.in",
    "net.in", "org.in", "ac.in", "gov.in", "firm.in", "gen.in", "ind.in",
    "co.za", "org.za", "gov.za", "ac.za", "net.za", "com.mx", "net.mx",
    "org.mx", "gob.mx", "edu.mx", "com.ar", "net.ar", "org.ar", "gob.ar",
    "com.tr", "net.tr", "org.tr", "gov.tr", "edu.tr", "co.il", "org.il",
    "net.il", "ac.il", "gov.il", "com.ua", "net.ua", "org.ua", "co.id", "or.id",
    "ac.id", "go.id", "com.ph", "net.ph", "org.ph", "com.vn", "net.vn",
    "com.pk", "com.eg", "com.sa", "com.qa", "com.kw", "co.th", "in.th",
    "ac.th", "go.th", "com.co", "com.pe", "com.ve", "com.ec", "com.uy",
    "github.io", "gitlab.io", "pages.dev", "vercel.app", "netlify.app",
    "herokuapp.com", "appspot.com", "blogspot.com", "cloudfront.net",
    "azurewebsites.net", "web.app", "firebaseapp.com", "workers.dev",
    "fly.dev", "onrender.com", "ngrok.io", "ngrok-free.app", "myshopify.com",
    "wordpress.com", "tumblr.com", "s3.amazonaws.com", "translate.goog",
    "sharepoint.com", "notion.site", "substack.com", "readthedocs.io",
};

bool IsMultiLabelSuffix(std::string_view s) {
  return std::find(std::begin(kMultiLabelSuffixes), std::end(kMultiLabelSuffixes), s) !=
         std::end(kMultiLabelSuffixes);
}

bool EndsWith(std::string_view s, std::string_view suffix) {
  return s.size() >= suffix.size() &&
         s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

bool IsIPv4(std::string_view host) {
  if (host.empty()) return false;
  int dots = 0;
  for (char c : host) {
    if (c == '.') ++dots;
    else if (c < '0' || c > '9') return false;
  }
  return dots == 3;
}

std::string_view Trim(std::string_view s) {
  while (!s.empty() && std::isspace(static_cast<unsigned char>(s.front()))) s.remove_prefix(1);
  while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) s.remove_suffix(1);
  return s;
}

}  // namespace

ContentBlocker& ContentBlocker::Get() {
  static ContentBlocker* instance = new ContentBlocker();  // intentionally leaked
  return *instance;
}

std::string_view ContentBlocker::SchemeOf(std::string_view url) {
  size_t colon = url.find(':');
  return colon == std::string_view::npos ? std::string_view() : url.substr(0, colon);
}

std::string_view ContentBlocker::HostOf(std::string_view url) {
  size_t start = url.find("://");
  if (start == std::string_view::npos) return {};
  start += 3;
  size_t end = url.find_first_of("/?#", start);
  std::string_view authority = url.substr(start, end == std::string_view::npos ? std::string_view::npos : end - start);
  size_t at = authority.rfind('@');
  if (at != std::string_view::npos) authority.remove_prefix(at + 1);
  if (!authority.empty() && authority.front() == '[') {  // IPv6 literal
    size_t close = authority.find(']');
    return close == std::string_view::npos ? authority : authority.substr(0, close + 1);
  }
  size_t colon = authority.find(':');
  if (colon != std::string_view::npos) authority = authority.substr(0, colon);
  if (!authority.empty() && authority.back() == '.') authority.remove_suffix(1);
  return authority;
}

std::string_view ContentBlocker::RegistrableDomain(std::string_view host) {
  if (host.empty() || IsIPv4(host) || host.front() == '[') return host;
  size_t last = host.rfind('.');
  if (last == std::string_view::npos) return host;
  size_t second = last == 0 ? std::string_view::npos : host.rfind('.', last - 1);
  if (second == std::string_view::npos) return host;  // already "a.tld"
  // host has >= 3 labels; check whether the last two form a public suffix.
  std::string_view last_two = host.substr(second + 1);
  if (IsMultiLabelSuffix(last_two)) {
    size_t third = second == 0 ? std::string_view::npos : host.rfind('.', second - 1);
    return third == std::string_view::npos ? host : host.substr(third + 1);
  }
  return last_two;
}

bool ContentBlocker::IsLocalOrPrivateHost(std::string_view host) {
  if (host.empty()) return true;
  if (host == "localhost" || EndsWith(host, ".localhost") || EndsWith(host, ".local") ||
      EndsWith(host, ".test") || EndsWith(host, ".internal") || EndsWith(host, ".lan") ||
      EndsWith(host, ".home.arpa") || EndsWith(host, ".onion")) {
    return true;
  }
  if (host.front() == '[') return true;  // IPv6 literals: leave as typed
  if (host.find('.') == std::string_view::npos) return true;  // intranet single label
  if (IsIPv4(host)) {
    // Private, loopback, link-local and CGNAT ranges.
    unsigned a = 0, b = 0;
    size_t i = 0;
    while (i < host.size() && host[i] != '.') a = a * 10 + (host[i++] - '0');
    ++i;
    while (i < host.size() && host[i] != '.') b = b * 10 + (host[i++] - '0');
    return a == 10 || a == 127 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) ||
           (a == 169 && b == 254) || (a == 100 && b >= 64 && b <= 127) || a == 0;
  }
  return false;
}

bool RuleSet::Contains(std::string_view domain) const {
  return std::binary_search(domains.begin(), domains.end(), domain);
}

size_t ContentBlocker::LoadRules(std::string_view text) {
  auto rules = std::make_shared<RuleSet>();
  rules->buffer.assign(text);
  std::transform(rules->buffer.begin(), rules->buffer.end(), rules->buffer.begin(),
                 [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
  const std::string_view all(rules->buffer);
  rules->domains.reserve(all.size() / 18);
  size_t pos = 0;
  while (pos < all.size()) {
    size_t nl = all.find('\n', pos);
    std::string_view line = all.substr(pos, nl == std::string_view::npos ? std::string_view::npos : nl - pos);
    pos = nl == std::string_view::npos ? all.size() : nl + 1;
    line = Trim(line);
    if (line.empty() || line.front() == '#' || line.front() == '!') continue;
    // Accept "0.0.0.0 domain" hosts-file lines too.
    size_t space = line.find_first_of(" \t");
    if (space != std::string_view::npos) {
      std::string_view first = line.substr(0, space);
      if (first == "0.0.0.0" || first == "127.0.0.1") line = Trim(line.substr(space + 1));
      else line = line.substr(0, space);
    }
    size_t dollar = line.find('$');  // "$third-party" (we never block first-party anyway)
    if (dollar != std::string_view::npos) line = line.substr(0, dollar);
    if (line.empty() || line.find('/') != std::string_view::npos) continue;
    rules->domains.push_back(line);
  }
  std::sort(rules->domains.begin(), rules->domains.end());
  rules->domains.erase(std::unique(rules->domains.begin(), rules->domains.end()), rules->domains.end());
  rules->domains.shrink_to_fit();
  size_t count = rules->domains.size();
  std::lock_guard<std::mutex> lock(mutex_);
  rules_ = std::move(rules);
  return count;
}

std::shared_ptr<const RuleSet> ContentBlocker::Rules() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return rules_;
}

size_t ContentBlocker::RuleCount() const {
  auto rules = Rules();
  return rules ? rules->size() : 0;
}

bool ContentBlocker::ShouldBlock(std::string_view url,
                                 std::string_view first_party_url,
                                 std::string* matched_host) const {
  if (!blocking_enabled.load(std::memory_order_relaxed)) return false;
  std::string_view scheme = SchemeOf(url);
  if (scheme != "https" && scheme != "http" && scheme != "wss" && scheme != "ws") return false;
  std::string_view host = HostOf(url);
  if (host.empty()) return false;

  std::string_view fp_host = HostOf(first_party_url);
  if (!fp_host.empty()) {
    std::string_view fp_site = RegistrableDomain(fp_host);
    if (RegistrableDomain(host) == fp_site) return false;  // first-party
    if (IsSiteAllowlisted(fp_site)) return false;
  }

  auto rules = Rules();
  if (!rules || rules->empty()) return false;
  std::string_view candidate = host;
  while (true) {
    if (rules->Contains(candidate)) {
      if (matched_host) matched_host->assign(host);
      return true;
    }
    size_t dot = candidate.find('.');
    if (dot == std::string_view::npos) break;
    candidate.remove_prefix(dot + 1);
    if (candidate.find('.') == std::string_view::npos) break;  // don't match bare TLDs
  }
  return false;
}

bool ContentBlocker::ShouldUpgradeToHttps(std::string_view host) const {
  if (!https_upgrades_enabled.load(std::memory_order_relaxed)) return false;
  if (IsLocalOrPrivateHost(host)) return false;
  return !IsInsecureHostAllowed(host);
}

void ContentBlocker::NoteUpgraded(std::string_view host) {
  std::lock_guard<std::mutex> lock(mutex_);
  upgraded_.emplace(host);
}

bool ContentBlocker::WasUpgraded(std::string_view host) const {
  std::lock_guard<std::mutex> lock(mutex_);
  return upgraded_.find(host) != upgraded_.end();
}

void ContentBlocker::ClearUpgraded(std::string_view host) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = upgraded_.find(host);
  if (it != upgraded_.end()) upgraded_.erase(it);
}

void ContentBlocker::AllowInsecureHost(std::string_view host) {
  std::lock_guard<std::mutex> lock(mutex_);
  insecure_allowed_.emplace(host);
}

bool ContentBlocker::IsInsecureHostAllowed(std::string_view host) const {
  std::lock_guard<std::mutex> lock(mutex_);
  return insecure_allowed_.find(host) != insecure_allowed_.end();
}

void ContentBlocker::SetAllowlistedSites(const std::vector<std::string>& sites) {
  DomainSet next;
  for (const auto& s : sites) next.emplace(RegistrableDomain(s));
  std::lock_guard<std::mutex> lock(mutex_);
  allowlist_ = std::move(next);
}

bool ContentBlocker::IsSiteAllowlisted(std::string_view first_party_site) const {
  std::lock_guard<std::mutex> lock(mutex_);
  return !allowlist_.empty() && allowlist_.find(first_party_site) != allowlist_.end();
}

}  // namespace wink
