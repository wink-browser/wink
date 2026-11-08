import AppKit
import Observation
import SwiftUI

/// The person using Wink. Kept only on this Mac (preferences plus a photo in
/// Wink's private State folder); there is no account. Winky uses the first
/// name to greet them, and it is shared with the AI model only as part of a
/// chat they start.
@MainActor
@Observable
final class Profile {
    static let shared = Profile()

    var name: String {
        didSet { UserDefaults.standard.set(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "profile.name") }
    }
    private(set) var photo: NSImage?

    @ObservationIgnored private var photoURL: URL { WinkPaths.shared.state.appendingPathComponent("profile.jpg") }

    private init() {
        name = UserDefaults.standard.string(forKey: "profile.name") ?? ""
        photo = NSImage(contentsOf: WinkPaths.shared.state.appendingPathComponent("profile.jpg"))
    }

    var firstName: String {
        name.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
    }

    var initials: String {
        name.split(separator: " ").prefix(2).compactMap { $0.first.map { String($0) } }.joined().uppercased()
    }

    /// "Good evening, Remi" — or just "Good evening".
    var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 5 ? "Good evening" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        return firstName.isEmpty ? part : "\(part), \(firstName)"
    }

    /// Asks for a photo, crops it square around the centre and keeps a 256 px copy.
    func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a photo for your Wink profile. It stays on this Mac."
        guard panel.runModal() == .OK, let url = panel.url,
              let source = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let side = min(source.width, source.height)
        guard let square = source.cropping(to: CGRect(x: (source.width - side) / 2, y: (source.height - side) / 2,
                                                      width: side, height: side)) else { return }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.interpolationQuality = .high
        NSGraphicsContext.current?.cgContext.draw(square, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else { return }
        try? data.write(to: photoURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: photoURL.path)
        photo = NSImage(data: data)
    }

    func removePhoto() {
        try? FileManager.default.removeItem(at: photoURL)
        photo = nil
    }
}

/// The user's photo, or their initials on cobalt, or a quiet placeholder.
struct ProfileAvatar: View {
    var size: CGFloat = 28
    var profile = Profile.shared

    var body: some View {
        Group {
            if let photo = profile.photo {
                Image(nsImage: photo).resizable().aspectRatio(contentMode: .fill)
            } else if !profile.initials.isEmpty {
                Text(profile.initials)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Theme.paperNS))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: Theme.cobaltNS))
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.08))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
        .accessibilityLabel(profile.name.isEmpty ? "Your profile" : profile.name)
    }
}

/// Winky: the assistant who lives in Wink's panel.
enum Winky {
    static let name = "Winky"
    static let avatar: NSImage? = Bundle.main.image(forResource: "WinkyAvatar")
    static let portrait: NSImage? = Bundle.main.image(forResource: "Winky")
}

struct WinkyAvatar: View {
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let image = Winky.avatar {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                EyeMark(width: size * 0.8)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
        .accessibilityLabel(Winky.name)
    }
}
