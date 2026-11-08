import Foundation

/// An action that does something on the user's behalf that other people see
/// or that costs money: sending, posting, buying, deleting, connecting.
struct ConsequentialAction {
    enum Kind: String {
        case send, purchase, delete, connect
    }

    let kind: Kind
    /// The control's label, e.g. "Send without a note".
    let label: String

    init?(_ value: Any?) {
        guard let object = value as? [String: Any], let raw = object["kind"] as? String,
              let kind = Kind(rawValue: raw) else { return nil }
        self.kind = kind
        self.label = object["label"] as? String ?? ""
    }

    var consequence: String {
        switch kind {
        case .send: "This sends or posts something as you."
        case .purchase: "This may spend money."
        case .delete: "This may delete or remove something."
        case .connect: "This connects with or follows someone as you."
        }
    }
}

/// Wink-enforced limits on what agents can do on the user's behalf.
///
/// Prompts in a model's instructions are advice; these are rules. Before an
/// agent clicks something consequential, Wink asks the user (once per site per
/// agent session by default), and after a burst of such actions on one site it
/// pauses for a check-in, so a runaway loop can't spam people or get an
/// account restricted.
@MainActor
enum Guardrails {
    static func check(_ action: ConsequentialAction, session: AgentSession, tab: Tab, verb: String = "click") async throws {
        let settings = WinkSettings.shared
        let host = Site.host(of: tab.url)
        let site = host.isEmpty ? "this page" : Site.registrableDomain(host)
        try await checkBudget(session: session, site: site, tab: tab)

        let alreadyAllowed = settings.agentConfirmMode == .never
            || (settings.agentConfirmMode == .oncePerSite && session.siteGrants.contains(site))
        if !alreadyAllowed {
            let options = settings.agentConfirmMode == .always
                ? ["Don't Allow", "Allow"]
                : ["Don't Allow", "Allow Once", "Allow on \(site)"]
            let title = verb == "press"
                ? "\(session.name) wants to press Enter to send"
                : "\(session.name) wants to \(verb) “\(action.label.prefix(60))”"
            let choice = await AgentHub.shared.prompt(
                symbol: "hand.raised", title: title, message: "\(site) · \(action.consequence)",
                options: options, tab: tab)
            switch choice {
            case 0:
                throw AgentAccessError(message: "The user didn't allow “\(action.label)”. Don't retry it; ask the user how they'd like to proceed.")
            case 2:
                session.siteGrants.insert(site)
            default:
                break
            }
        }
        session.consequential.append((site, Date()))
    }

    /// After `agentHourlyLimit` consequential actions on one site within an
    /// hour, the agent waits for the user before doing more.
    private static func checkBudget(session: AgentSession, site: String, tab: Tab) async throws {
        let limit = WinkSettings.shared.agentHourlyLimit
        guard limit > 0 else { return }
        let hourAgo = Date().addingTimeInterval(-3600)
        session.consequential.removeAll { $0.date < hourAgo }
        let recent = session.consequential.filter { $0.site == site }.count
        let allowance = limit + session.extraAllowance[site, default: 0]
        guard recent >= allowance else { return }
        let choice = await AgentHub.shared.prompt(
            symbol: "gauge.with.needle",
            title: "\(session.name) has sent, bought or changed \(recent) things on \(site) this hour",
            message: "Wink checks in at \(limit) an hour so a runaway task can't spam people or get your account restricted.",
            options: ["Stop Agent", "Allow \(limit) More"], tab: tab, timeout: 300)
        guard choice == 1 else {
            let error = AgentAccessError(message: "Wink's hourly limit for \(site) was reached and the user stopped you. Summarize what you did.")
            AgentHub.shared.stop(session, reason: "Stopped at the hourly limit")
            throw error
        }
        session.extraAllowance[site, default: 0] += limit
    }
}
