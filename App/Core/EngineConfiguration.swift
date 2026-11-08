import Foundation
import WinkEngine

/// Builds the Chromium configuration: privacy-hardened, performance-tuned.
enum EngineConfiguration {
    static func make(paths: WinkPaths) -> WinkRuntimeConfiguration {
        let config = WinkRuntimeConfiguration()
        config.userDataPath = paths.userData.path
        config.defaultProfilePath = paths.defaultProfile.path
        config.logFilePath = paths.logs.appendingPathComponent("engine.log").path
        config.verboseLogging = ProcessInfo.processInfo.environment["WINK_VERBOSE"] != nil

        let languages = Locale.preferredLanguages.prefix(4)
        config.locale = languages.first ?? "en-US"
        config.acceptLanguageList = languages.joined(separator: ",")

        // Features that phone home, profile users for ads, or broadcast on the
        // local network. Unknown names are ignored by Chromium.
        config.disabledFeatures = [
            // Privacy Sandbox ad APIs (Topics, Protected Audience, attribution).
            "BrowsingTopics", "BrowsingTopicsDocumentAPI", "BrowsingTopicsXHR",
            "InterestGroupStorage", "AdInterestGroupAPI", "Fledge",
            "FledgeBiddingAndAuctionServer", "PrivacySandboxAdsAPIsOverride",
            "PrivateAggregationApi", "SharedStorageAPI", "AttributionReportingCrossAppWeb",
            "CookieDeprecationFacilitatedTesting",
            // Google service calls.
            "OptimizationHints", "OptimizationHintsFetching", "OptimizationGuideModelDownloading",
            "OptimizationGuideOnDeviceModel", "AutofillServerCommunication",
            "NetworkTimeServiceQuerying", "InterestFeedContentSuggestions",
            // Cast / local-network discovery chatter.
            "MediaRouter", "DialMediaRouteProvider", "CastMediaRouteProvider",
            // Network error reporting to third parties.
            "NetworkErrorLogging", "Reporting",
        ]
        config.enabledFeatures = [
            "ReduceAcceptLanguage",
        ]

        // Per-profile Chromium preferences, applied when each profile starts.
        let settings = WinkSettings.shared
        config.profilePreferences = PrivacyPreferences.chromiumPreferences(for: settings)
        return config
    }
}

/// Maps Wink's privacy settings onto Chromium preference names.
enum PrivacyPreferences {
    static func chromiumPreferences(for settings: WinkSettings) -> [String: Any] {
        [
            // 0 = allow all, 1 = block third-party, 2 = block third-party in incognito
            "profile.cookie_controls_mode": settings.blockThirdPartyCookies ? 1 : 0,
            // Never leak local IP addresses over WebRTC.
            "webrtc.ip_handling_policy": "default_public_interface_only",
            "enable_a_ping": false,
            "search.suggest_enabled": false,
            "https_only_mode_enabled": false,  // Wink upgrades itself, with fallback
            "privacy_sandbox.m1.topics_enabled": false,
            "privacy_sandbox.m1.fledge_enabled": false,
            "privacy_sandbox.m1.ad_measurement_enabled": false,
        ]
    }
}
