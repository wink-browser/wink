import AppKit
import ImageIO
import QuartzCore
import SwiftUI

/// Views that can paint themselves for the development snapshot path, which
/// renders layer trees offscreen (CALayer.render(in:) ignores masks).
@MainActor
protocol SnapshotDrawing: AnyObject {
    func drawSnapshot(in context: CGContext)
}

// MARK: - Aurora glow

/// The Siri-like aurora around the content card while an agent works.
///
/// `.inner` sits inside the card: a crisp rim plus a bloom that fades inward
/// over the page. `.outer` sits behind the card and lets the light spill onto
/// the window around it. Both are rotating conic gradients under a static
/// mask, so the effect is a handful of GPU composites and no main-thread work.
@MainActor
final class AuroraGlowView: NSView, SnapshotDrawing {
    enum Placement { case inner, outer }

    /// Shared start time keeps the inner and outer light in phase.
    /// Lit, the aurora rests below full strength: present, easy on the eyes.
    static let restingOpacity: Float = 0.82
    private static let epoch = CACurrentMediaTime()

    let placement: Placement
    /// Margin between this view's bounds and the card edge (outer only).
    let spill: CGFloat
    var cornerRadius: CGFloat = Theme.contentRadius {
        didSet { if cornerRadius != oldValue { needsLayout = true } }
    }

    private let field = CALayer()        // fades in/out; carries the mask
    private let breath = CALayer()       // slow intensity drift
    private let falloff = CALayer()      // mask: soft bloom
    private let rim = CAShapeLayer()     // mask: crisp 1.5 pt edge (inner)
    private let spinA = CAGradientLayer()
    private let spinB = CAGradientLayer()
    private var maskKey = ""
    private var maskBytes: (width: Int, height: Int, alpha: [UInt8])?
    private var maskTask: DispatchWorkItem?
    private(set) var isLit = false
    private var isDimmed = false

    init(placement: Placement) {
        self.placement = placement
        self.spill = placement == .outer ? 22 : 0
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        isHidden = true

        field.opacity = 0
        field.mask = falloff
        falloff.contentsGravity = .resize
        if placement == .inner {
            rim.fillColor = nil
            rim.strokeColor = NSColor.white.withAlphaComponent(0.7).cgColor  // a fine line, not a neon tube
            rim.lineWidth = 3  // half of it is clipped by the card's continuous corners
            falloff.addSublayer(rim)
        }
        let colors = Theme.auroraNS + [Theme.auroraNS[0]]
        for (gradient, palette) in [(spinA, colors), (spinB, Array(colors.reversed()))] {
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.colors = palette.map(\.cgColor)
            gradient.contentsScale = 0.5  // smooth color field: low resolution is invisible
            breath.addSublayer(gradient)
        }
        spinB.opacity = 0.4
        spinB.compositingFilter = "screenBlendMode"
        field.addSublayer(breath)
        layer?.addSublayer(field)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        field.frame = bounds
        breath.frame = bounds
        falloff.frame = bounds
        let side = hypot(bounds.width, bounds.height) + 8
        for gradient in [spinA, spinB] {
            gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        if placement == .inner {
            rim.frame = bounds
            rim.path = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        }
        CATransaction.commit()
        scheduleMask()
    }

    // MARK: Light

    /// Turns the aurora on or off with an exponential bloom / soft fade.
    func setLit(_ lit: Bool, dimmed: Bool = false) {
        if lit == isLit {
            if lit && dimmed != isDimmed { setDimmed(dimmed) }
            return
        }
        isLit = lit
        if lit {
            isHidden = false
            scheduleMask()
            startMotion()
            isDimmed = dimmed
            fade(to: dimmed ? 0.3 : Self.restingOpacity, duration: 0.7, timing: Theme.easeOut)
            if placement == .inner {
                // One authored moment: the light arrives from just beyond the edge.
                let bloom = CABasicAnimation(keyPath: "transform.scale")
                bloom.fromValue = 1.035
                bloom.toValue = 1
                bloom.duration = 0.8
                bloom.timingFunction = Theme.easeOut
                falloff.add(bloom, forKey: "bloom")
            }
        } else {
            fade(to: 0, duration: 0.5, timing: CAMediaTimingFunction(name: .easeIn)) { [weak self] in
                guard let self, !self.isLit else { return }
                self.isHidden = true
                self.stopMotion()
            }
        }
    }

    private func setDimmed(_ dimmed: Bool) {
        isDimmed = dimmed
        fade(to: dimmed ? 0.3 : Self.restingOpacity, duration: 0.4, timing: Theme.easeOut)
        for gradient in [spinA, spinB] {
            if dimmed { pause(gradient) } else { resume(gradient) }
        }
    }

    /// A brief swell of light (screenshots, confirmations).
    func swell() {
        guard isLit else { return }
        let swell = CAKeyframeAnimation(keyPath: "opacity")
        swell.values = [1, 1.25, 1]
        swell.keyTimes = [0, 0.25, 1]
        swell.duration = 0.6
        breath.add(swell, forKey: "swell")
    }

    private func fade(to opacity: Float, duration: CFTimeInterval, timing: CAMediaTimingFunction,
                      completion: (() -> Void)? = nil) {
        let from = field.presentation()?.opacity ?? field.opacity
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = opacity
        animation.duration = duration
        animation.timingFunction = timing
        field.opacity = opacity
        field.add(animation, forKey: "fade")
        CATransaction.commit()
    }

    private func startMotion() {
        guard spinA.animation(forKey: "spin") == nil else { return }
        for (gradient, period, direction) in [(spinA, 9.0, 1.0), (spinB, 13.0, -1.0)] {
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = direction * 2 * Double.pi
            spin.duration = period
            spin.repeatCount = .infinity
            spin.beginTime = Self.epoch
            gradient.add(spin, forKey: "spin")
        }
        let drift = CABasicAnimation(keyPath: "opacity")
        drift.fromValue = 0.88
        drift.toValue = 1
        drift.duration = 3.8
        drift.autoreverses = true
        drift.repeatCount = .infinity
        drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breath.add(drift, forKey: "breath")
    }

    private func stopMotion() {
        for gradient in [spinA, spinB] { gradient.removeAllAnimations(); gradient.speed = 1; gradient.timeOffset = 0 }
        breath.removeAllAnimations()
    }

    private func pause(_ layer: CALayer) {
        guard layer.speed != 0 else { return }
        let time = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = time
    }

    private func resume(_ layer: CALayer) {
        guard layer.speed == 0 else { return }
        let paused = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
    }

    // MARK: Mask

    /// The bloom is a signed-distance falloff from the card edge, computed off
    /// the main thread whenever the size settles.
    private func scheduleMask() {
        guard isLit, bounds.width > 4, bounds.height > 4 else { return }
        let key = "\(Int(bounds.width))x\(Int(bounds.height))r\(Int(cornerRadius))"
        guard key != maskKey else { return }
        maskKey = key
        maskTask?.cancel()
        let size = bounds.size, radius = cornerRadius, placement = placement, spill = spill
        let task = DispatchWorkItem { [weak self] in
            let bytes = Self.falloff(size: size, radius: radius, placement: placement, spill: spill)
            let image = Self.image(from: bytes, premultipliedWhite: true)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.maskKey == key else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.falloff.contents = image
                    CATransaction.commit()
                    self.maskBytes = bytes
                }
            }
        }
        maskTask = task
        // Debounced so a live window resize only computes the final size.
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (falloff.contents == nil ? 0 : 0.12), execute: task)
    }

    nonisolated private static func falloff(size: CGSize, radius: CGFloat, placement: Placement,
                                            spill: CGFloat) -> (width: Int, height: Int, alpha: [UInt8]) {
        let width = max(1, Int(size.width.rounded(.up)))
        let height = max(1, Int(size.height.rounded(.up)))
        var alpha = [UInt8](repeating: 0, count: width * height)
        let cx = Float(size.width) / 2, cy = Float(size.height) / 2
        let r = Float(radius)
        let bx = Float(size.width) / 2 - Float(spill) - r
        let by = Float(size.height) / 2 - Float(spill) - r
        let inner = placement == .inner
        alpha.withUnsafeMutableBufferPointer { buffer in
            for y in 0..<height {
                let qy = abs(Float(y) + 0.5 - cy) - by
                for x in 0..<width {
                    let qx = abs(Float(x) + 0.5 - cx) - bx
                    let ox = max(qx, 0), oy = max(qy, 0)
                    // Signed distance to the rounded card edge: < 0 inside.
                    let d = (ox * ox + oy * oy).squareRoot() + min(max(qx, qy), 0) - r
                    var a: Float
                    if inner {
                        let t = max(-d, 0)
                        a = t > 120 ? 0 : 0.3 * expf(-t / 7) + 0.07 * expf(-t / 26)
                    } else {
                        let t = max(d, 0)
                        a = 0.2 * expf(-t / 5) + 0.05 * expf(-t / 12)
                    }
                    buffer[y * width + x] = UInt8(min(255, a * 255))
                }
            }
        }
        return (width, height, alpha)
    }

    /// RGBA (premultiplied white) for a CALayer mask, or plain gray for a
    /// CoreGraphics clip mask.
    nonisolated private static func image(from bytes: (width: Int, height: Int, alpha: [UInt8]),
                                          premultipliedWhite: Bool) -> CGImage? {
        let (width, height, alpha) = bytes
        if premultipliedWhite {
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            for i in 0..<(width * height) {
                let v = alpha[i]
                rgba[i * 4] = v; rgba[i * 4 + 1] = v; rgba[i * 4 + 2] = v; rgba[i * 4 + 3] = v
            }
            guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                           bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        }
        guard let provider = CGDataProvider(data: Data(alpha) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Snapshot

    func drawSnapshot(in context: CGContext) {
        guard isLit, let bytes = maskBytes, let mask = Self.image(from: bytes, premultipliedWhite: false) else { return }
        let colors = (Theme.auroraNS + [Theme.auroraNS[0]]).map(\.cgColor) as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) else { return }
        let rect = CGRect(origin: .zero, size: CGSize(width: bytes.width, height: bytes.height))
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        context.saveGState()
        context.setAlpha(CGFloat(isDimmed ? 0.3 : Self.restingOpacity))
        context.clip(to: rect, mask: mask)
        CGContextDrawConicGradient(context, gradient, center, 0)
        context.restoreGState()
        if placement == .inner {
            context.saveGState()
            context.addPath(CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
            context.setLineWidth(3)
            context.replacePathWithStrokedPath()
            context.clip()
            CGContextDrawConicGradient(context, gradient, center, 0)
            context.restoreGState()
        }
    }
}

// MARK: - The eye (agent presence)

/// Wink's eye, cut from the logo artwork (`make icon` writes WinkEye.png).
/// It marks every agent surface — cursor, pill, prompts, panel — and blinks.
enum Brand {
    static let eye: CGImage? = {
        guard let url = Bundle.main.url(forResource: "WinkEye", withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }()

    static let eyeImage: NSImage? = eye.map { NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width) / 2, height: CGFloat($0.height) / 2)) }

    /// Width ÷ height of the eye artwork.
    static let eyeAspect: CGFloat = eye.map { CGFloat($0.width) / CGFloat($0.height) } ?? 1.7

    /// A slow, natural blink every few seconds: "working".
    static func idleBlink() -> CAKeyframeAnimation {
        let blink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        blink.values = [1, 1, 0.06, 1]
        blink.keyTimes = [0, 0.92, 0.95, 1]
        blink.duration = 4.4
        blink.repeatCount = .infinity
        return blink
    }

    /// One quick blink: the agent's click.
    static func wink() -> CAKeyframeAnimation {
        let wink = CAKeyframeAnimation(keyPath: "transform.scale.y")
        wink.values = [1, 0.06, 1]
        wink.keyTimes = [0, 0.4, 1]
        wink.duration = 0.26
        wink.timingFunctions = [CAMediaTimingFunction(name: .easeIn), Theme.easeOut]
        return wink
    }
}

/// The eye with a soft aurora halo, as one layer (used by the page cursor).
final class EyeLayer: CALayer {
    private let halo = CALayer()
    private let eye = CALayer()
    let width: CGFloat

    init(width: CGFloat, halo showHalo: Bool) {
        self.width = width
        super.init()
        let height = width / Brand.eyeAspect
        bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if showHalo {
            halo.frame = bounds
            halo.shadowPath = CGPath(ellipseIn: bounds.insetBy(dx: width * 0.06, dy: height * 0.08), transform: nil)
            halo.shadowColor = Theme.auroraNS[0].cgColor
            halo.shadowOpacity = 0.45
            halo.shadowRadius = width * 0.18
            halo.shadowOffset = .zero
            addSublayer(halo)
        }
        eye.frame = bounds
        eye.contents = Brand.eye
        eye.contentsGravity = .resizeAspect
        eye.minificationFilter = .trilinear
        addSublayer(eye)
    }

    override init(layer: Any) {
        width = (layer as? EyeLayer)?.width ?? 24
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var contentsScale: CGFloat {
        didSet { halo.contentsScale = contentsScale; eye.contentsScale = contentsScale }
    }

    func setBlinking(_ blinking: Bool) {
        if blinking {
            if eye.animation(forKey: "blink") == nil { eye.add(Brand.idleBlink(), forKey: "blink") }
        } else {
            eye.removeAnimation(forKey: "blink")
        }
    }

    func wink() {
        eye.add(Brand.wink(), forKey: "wink")
    }
}

/// SwiftUI wrapper: Wink's eye, blinking now and then while an agent works.
struct EyeMark: NSViewRepresentable {
    var width: CGFloat = 22
    var blinking = false
    var halo = false

    func makeNSView(context: Context) -> EyeHostView {
        EyeHostView(width: width, halo: halo)
    }

    func updateNSView(_ view: EyeHostView, context: Context) {
        view.eye.setBlinking(blinking)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: EyeHostView, context: Context) -> CGSize? {
        CGSize(width: width, height: (width / Brand.eyeAspect).rounded(.up))
    }

    final class EyeHostView: NSView {
        let eye: EyeLayer

        init(width: CGFloat, halo: Bool) {
            eye = EyeLayer(width: width, halo: halo)
            super.init(frame: NSRect(x: 0, y: 0, width: width, height: width / Brand.eyeAspect))
            wantsLayer = true
            layer?.masksToBounds = false
            layer?.addSublayer(eye)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            eye.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            eye.contentsScale = window?.backingScaleFactor ?? 2
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

// MARK: - Cursor, highlights and page effects

/// Draws what the agent is doing on top of the page: Wink's eye gliding to
/// its target, a hairline around the element, a wink and a ripple on click, a
/// caption while typing, a sweep while reading, a viewfinder on screenshots.
/// Coordinates are this view's points (CSS pixels × page zoom).
@MainActor
final class AgentOverlayView: NSView, SnapshotDrawing {
    private let orb = EyeLayer(width: 28, halo: true)
    private let highlight = CAShapeLayer()
    private let captionPlate = CALayer()
    private let caption = CATextLayer()
    private var orbShown = false
    private var fadeWork: DispatchWorkItem?
    private var highlightWork: DispatchWorkItem?
    private var captionWork: DispatchWorkItem?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true

        highlight.fillColor = Theme.auroraNS[0].withAlphaComponent(0.05).cgColor
        highlight.strokeColor = Theme.auroraNS[0].withAlphaComponent(0.75).cgColor
        highlight.lineWidth = 1.5
        highlight.shadowColor = Theme.auroraNS[0].cgColor
        highlight.shadowOpacity = 0.22
        highlight.shadowRadius = 6
        highlight.shadowOffset = .zero
        highlight.opacity = 0
        layer?.addSublayer(highlight)

        captionPlate.backgroundColor = NSColor(white: 0.08, alpha: 0.78).cgColor
        captionPlate.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        captionPlate.borderWidth = 0.5
        captionPlate.cornerRadius = 9
        captionPlate.cornerCurve = .continuous
        captionPlate.opacity = 0
        caption.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        caption.fontSize = 11
        caption.foregroundColor = NSColor.white.cgColor
        caption.alignmentMode = .center
        caption.truncationMode = .end
        captionPlate.addSublayer(caption)
        layer?.addSublayer(captionPlate)

        orb.opacity = 0
        layer?.addSublayer(orb)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        orb.contentsScale = scale
        caption.contentsScale = scale
        highlight.contentsScale = scale
    }

    /// Glides the orb to `point` and outlines `rect`. Returns the glide time.
    /// The eye sits just below-right of the point it acts on, like a cursor's
    /// hotspot, so it never hides the label the agent is clicking.
    private static let hotspot = CGPoint(x: 16, y: 13)

    @discardableResult
    func moveCursor(to point: CGPoint, highlight rect: CGRect?, radius: CGFloat = 6) -> TimeInterval {
        let target = clamp(CGPoint(x: point.x + Self.hotspot.x, y: point.y + Self.hotspot.y))
        let from: CGPoint
        if orbShown, let presented = orb.presentation()?.position {
            from = presented
        } else {
            // The first move launches from the activity pill at the bottom.
            from = CGPoint(x: bounds.midX, y: bounds.maxY - 34)
        }
        let distance = hypot(target.x - from.x, target.y - from.y)
        let duration = min(0.3, 0.12 + Double(distance) / 3600)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        orb.position = target
        CATransaction.commit()
        let glide = CABasicAnimation(keyPath: "position")
        glide.fromValue = NSValue(point: from)
        glide.toValue = NSValue(point: target)
        glide.duration = duration
        glide.timingFunction = Theme.easeOut
        orb.add(glide, forKey: "glide")
        showOrb()
        if let rect { outline(rect, radius: radius, after: duration * 0.5) }
        scheduleFade()
        return duration
    }

    func press(at point: CGPoint) {
        orb.wink()

        let ripple = CAShapeLayer()
        let radius: CGFloat = 16
        ripple.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
        ripple.position = clamp(point)
        ripple.path = CGPath(ellipseIn: ripple.bounds, transform: nil)
        ripple.fillColor = nil
        ripple.strokeColor = NSColor.white.withAlphaComponent(0.92).cgColor
        ripple.lineWidth = 1.5
        ripple.shadowColor = Theme.auroraNS[3].cgColor
        ripple.shadowOpacity = 0.35
        ripple.shadowRadius = 4
        ripple.shadowOffset = .zero
        ripple.opacity = 0
        layer?.insertSublayer(ripple, below: orb)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ripple.removeFromSuperlayer() }
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.3
        grow.toValue = 1.9
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        fade.keyTimes = [0, 0.15, 1]
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.6
        group.timingFunction = Theme.easeOut
        ripple.add(group, forKey: "ripple")
        CATransaction.commit()
        scheduleFade()
    }

    /// A quiet caption above the field being typed into.
    func showTyping(in rect: CGRect?, text: String?) {
        let shown = text.map { "“\($0.count > 42 ? String($0.prefix(41)) + "…" : $0)”" } ?? "••••••••"
        caption.string = shown
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let width = min(bounds.width - 24, (shown as NSString).size(withAttributes: [.font: font]).width + 22)
        let height: CGFloat = 22
        let anchor = rect ?? CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
        var y = anchor.minY - height - 8
        if y < 8 { y = anchor.maxY + 8 }
        let x = min(max(8, anchor.minX), bounds.width - width - 8)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        captionPlate.frame = CGRect(x: x, y: y, width: width, height: height)
        caption.frame = CGRect(x: 8, y: 4, width: width - 16, height: 15)
        CATransaction.commit()
        animateOpacity(captionPlate, to: 1, duration: 0.2)
        captionWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.animateOpacity(self.captionPlate, to: 0, duration: 0.35)
        }
        captionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }

    /// A faint band of aurora light sweeping down the page: "reading".
    func scan() {
        let band = CAGradientLayer()
        let height: CGFloat = min(220, bounds.height * 0.3)
        band.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: height)
        band.colors = [NSColor.clear, Theme.auroraNS[2].withAlphaComponent(0.06), Theme.auroraNS[1].withAlphaComponent(0.07),
                       NSColor.clear].map(\.cgColor)
        band.locations = [0, 0.45, 0.6, 1]
        band.position = CGPoint(x: bounds.midX, y: -height / 2)
        band.opacity = 0.9
        layer?.insertSublayer(band, at: 0)
        CATransaction.begin()
        CATransaction.setCompletionBlock { band.removeFromSuperlayer() }
        let sweep = CABasicAnimation(keyPath: "position.y")
        sweep.fromValue = -height / 2
        sweep.toValue = bounds.height + height / 2
        sweep.duration = 0.85
        sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
        band.add(sweep, forKey: "sweep")
        band.position.y = bounds.height + height / 2
        CATransaction.commit()
    }

    /// Viewfinder corners closing in: "taking a screenshot".
    func shutter() {
        let frame = CAShapeLayer()
        frame.frame = bounds
        let inset: CGFloat = 16, arm: CGFloat = 22
        let r = bounds.insetBy(dx: inset, dy: inset)
        let path = CGMutablePath()
        for (corner, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                 (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
            path.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
            path.addLine(to: corner)
            path.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
        }
        frame.path = path
        frame.fillColor = nil
        frame.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        frame.lineWidth = 2
        frame.lineCap = .round
        frame.lineJoin = .round
        frame.shadowColor = NSColor.black.cgColor
        frame.shadowOpacity = 0.25
        frame.shadowRadius = 3
        frame.shadowOffset = CGSize(width: 0, height: 1)
        frame.opacity = 0
        layer?.addSublayer(frame)
        CATransaction.begin()
        CATransaction.setCompletionBlock { frame.removeFromSuperlayer() }
        let close = CABasicAnimation(keyPath: "transform.scale")
        close.fromValue = 1.05
        close.toValue = 1
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.2, 0.6, 1]
        let group = CAAnimationGroup()
        group.animations = [close, fade]
        group.duration = 0.55
        group.timingFunction = Theme.easeOut
        frame.add(group, forKey: "shutter")
        CATransaction.commit()
    }

    func scrollHint(at point: CGPoint, deltaY: CGFloat) {
        moveCursor(to: point, highlight: nil)
        let nudge = CAKeyframeAnimation(keyPath: "transform.translation.y")
        let d: CGFloat = deltaY >= 0 ? 10 : -10
        nudge.values = [0, d, 0]
        nudge.duration = 0.4
        nudge.timingFunction = Theme.easeOut
        orb.add(nudge, forKey: "nudge")
    }

    func hideAll() {
        fadeWork?.cancel()
        animateOpacity(orb, to: 0, duration: 0.25)
        animateOpacity(highlight, to: 0, duration: 0.2)
        animateOpacity(captionPlate, to: 0, duration: 0.2)
        orbShown = false
    }

    // MARK: Internals

    private func outline(_ rect: CGRect, radius elementRadius: CGFloat, after delay: TimeInterval) {
        let gap: CGFloat = 4
        let padded = rect.insetBy(dx: -gap, dy: -gap).intersection(bounds.insetBy(dx: 2, dy: 2))
        guard !padded.isNull, padded.width > 2, padded.height > 2 else { return }
        // Concentric with the element: its radius plus the gap.
        let radius = min(padded.height / 2, padded.width / 2, elementRadius + gap)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = padded
        highlight.path = CGPath(roundedRect: CGRect(origin: .zero, size: padded.size), cornerWidth: radius,
                                cornerHeight: radius, transform: nil)
        highlight.shadowPath = highlight.path
        CATransaction.commit()
        let appear = CABasicAnimation(keyPath: "transform.scale")
        appear.fromValue = 1.06
        appear.toValue = 1
        appear.duration = 0.32
        appear.beginTime = CACurrentMediaTime() + delay
        appear.timingFunction = Theme.easeOut
        appear.fillMode = .backwards
        highlight.add(appear, forKey: "appear")
        animateOpacity(highlight, to: 1, duration: 0.2, delay: delay)
        releaseHighlight(after: 8)  // safety net; the action releases it sooner
    }

    /// Fades the target outline once the action is done.
    func releaseHighlight(after delay: TimeInterval) {
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.animateOpacity(self.highlight, to: 0, duration: 0.45)
        }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func showOrb() {
        orb.setBlinking(true)
        if !orbShown {
            orbShown = true
            let pop = CABasicAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.4
            pop.toValue = 1
            pop.duration = 0.4
            pop.timingFunction = Theme.easeOut
            orb.add(pop, forKey: "pop")
        }
        animateOpacity(orb, to: 1, duration: 0.18)
    }

    private func scheduleFade() {
        fadeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.animateOpacity(self.orb, to: 0, duration: 0.6)
            self.orbShown = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                if self?.orbShown == false { self?.orb.setBlinking(false) }
            }
        }
        fadeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    private func animateOpacity(_ layer: CALayer, to value: Float, duration: CFTimeInterval, delay: CFTimeInterval = 0) {
        let from = layer.presentation()?.opacity ?? layer.opacity
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = from
        animation.toValue = value
        animation.duration = duration
        animation.beginTime = delay > 0 ? CACurrentMediaTime() + delay : 0
        animation.fillMode = .backwards
        animation.timingFunction = Theme.easeOut
        layer.opacity = value
        layer.add(animation, forKey: "opacity")
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 2), bounds.width - 2), y: min(max(point.y, 2), bounds.height - 2))
    }

    func drawSnapshot(in context: CGContext) {
        // The model layers hold final positions; render them as-is.
        layer?.render(in: context)
    }
}

// MARK: - Entry points for the agent tools

/// What the agent is doing, drawn on the page the user is looking at. Calls
/// are no-ops for tabs that aren't visible, so background work stays fast.
@MainActor
enum AgentVisuals {
    private static func surface(for tab: Tab) -> (overlay: AgentOverlayView, zoom: CGFloat)? {
        guard WinkSettings.shared.agentShowCursor,
              let controller = AppDelegate.shared?.window(containing: tab),
              controller.state.activeTabID == tab.id,
              let window = controller.window, window.isVisible, !window.isMiniaturized,
              let webView = tab.webView else { return nil }
        return (controller.root.content.agentOverlay, CGFloat(pow(1.2, webView.zoomLevel)))
    }

    private static func scaled(_ point: CGPoint, _ zoom: CGFloat) -> CGPoint {
        CGPoint(x: point.x * zoom, y: point.y * zoom)
    }

    private static func scaled(_ rect: CGRect, _ zoom: CGFloat) -> CGRect {
        CGRect(x: rect.minX * zoom, y: rect.minY * zoom, width: rect.width * zoom, height: rect.height * zoom)
    }

    /// Moves the cursor to the target (CSS pixels) and waits until it is
    /// nearly there, so the click lands as the orb arrives.
    static func approach(_ tab: Tab, point: CGPoint, highlight: CGRect?, radius: CGFloat = 2) async {
        guard let surface = surface(for: tab) else { return }
        let duration = surface.overlay.moveCursor(to: scaled(point, surface.zoom),
                                                  highlight: highlight.map { scaled($0, surface.zoom) },
                                                  radius: radius * surface.zoom)
        try? await Task.sleep(nanoseconds: UInt64(duration * 0.55 * 1_000_000_000))
    }

    /// The action finished: let the target outline linger briefly, then fade.
    static func done(_ tab: Tab) {
        surface(for: tab)?.overlay.releaseHighlight(after: 0.5)
    }

    static func press(_ tab: Tab, at point: CGPoint) {
        guard let surface = surface(for: tab) else { return }
        surface.overlay.press(at: scaled(point, surface.zoom))
    }

    static func typing(_ tab: Tab, in rect: CGRect?, text: String?) {
        guard let surface = surface(for: tab) else { return }
        surface.overlay.showTyping(in: rect.map { scaled($0, surface.zoom) }, text: text)
    }

    static func scan(_ tab: Tab) {
        surface(for: tab)?.overlay.scan()
    }

    static func shutter(_ tab: Tab) {
        guard let surface = surface(for: tab) else { return }
        surface.overlay.shutter()
        AppDelegate.shared?.window(containing: tab)?.root.content.glow.swell()
    }

    static func scroll(_ tab: Tab, at point: CGPoint, deltaY: Double) {
        guard let surface = surface(for: tab) else { return }
        surface.overlay.scrollHint(at: scaled(point, surface.zoom), deltaY: CGFloat(deltaY))
    }
}
