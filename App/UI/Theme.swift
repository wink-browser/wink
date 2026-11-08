import AppKit
import QuartzCore
import SwiftUI

/// Wink's visual language: quiet surfaces, one accent, generous radius.
enum Theme {
    static let sidebarMinWidth: CGFloat = 200
    static let sidebarMaxWidth: CGFloat = 400
    static let agentPanelMinWidth: CGFloat = 320
    static let agentPanelMaxWidth: CGFloat = 560
    static let contentInset: CGFloat = 8
    static let contentRadius: CGFloat = 10
    static let rowHeight: CGFloat = 32
    static let rowRadius: CGFloat = 8
    static let titlebarHeight: CGFloat = 40

    static let accent = Color.accentColor

    /// The agent palette: a Siri-like aurora of lavender, rose, periwinkle,
    /// coral and amber. Used only for agent presence, never for chrome.
    static let auroraNS: [NSColor] = [
        NSColor(srgbRed: 0.737, green: 0.510, blue: 0.953, alpha: 1),  // lavender
        NSColor(srgbRed: 0.961, green: 0.725, blue: 0.918, alpha: 1),  // rose
        NSColor(srgbRed: 0.553, green: 0.624, blue: 1.000, alpha: 1),  // periwinkle
        NSColor(srgbRed: 1.000, green: 0.404, blue: 0.471, alpha: 1),  // coral
        NSColor(srgbRed: 1.000, green: 0.729, blue: 0.443, alpha: 1),  // amber
        NSColor(srgbRed: 0.776, green: 0.525, blue: 1.000, alpha: 1),  // violet
    ]
    static let aurora: [Color] = auroraNS.map { Color(nsColor: $0) }
    /// Wink's cobalt (the logo's iris): the agent cursor's eye.
    static let cobaltNS = NSColor(srgbRed: 0.118, green: 0.353, blue: 0.776, alpha: 1)
    /// The logo's paper, reprinted in coral (#FC9A7C), and the cream it is printed with.
    static let coralNS = NSColor(srgbRed: 0.988, green: 0.604, blue: 0.486, alpha: 1)
    static let paperNS = NSColor(srgbRed: 0.965, green: 0.937, blue: 0.878, alpha: 1)

    /// A quiet aurora hairline for Winky's surfaces on the page.
    static let auroraBorder = AngularGradient(
        colors: (auroraNS + [auroraNS[0]]).map { Color(nsColor: $0).opacity(0.5) }, center: .center)

    static let agentGradient = LinearGradient(
        colors: [aurora[0], aurora[3]], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let agentColor = aurora[0]
    static let agentNSColor = auroraNS[0]

    /// Exponential ease-out: fast start, long gentle settle.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)

    static let rowSelected = Color.primary.opacity(0.09)
    static let rowHover = Color.primary.opacity(0.05)
    static let hairline = Color.primary.opacity(0.08)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

/// Fixed-capacity FIFO used for console/network/agent logs.
struct RingBuffer<Element> {
    private(set) var elements: [Element] = []
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity }

    mutating func append(_ element: Element) {
        elements.append(element)
        if elements.count > capacity { elements.removeFirst(elements.count - capacity) }
    }

    mutating func removeAll() { elements.removeAll() }
}
