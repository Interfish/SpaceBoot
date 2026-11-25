import Cocoa
import CoreGraphics

/// Renders SpaceBoot's vector menu bar template icon using three staggered slanted
/// Space planes matching the App Icon's C1 identity.
enum StatusBarIcon {
    private static let canvasSize = NSSize(width: 18, height: 18)

    private static let planeWidth: CGFloat = 8.2
    private static let planeHeight: CGFloat = 6.8
    private static let planeSlant: CGFloat = 4.3
    private static let cornerRadius: CGFloat = 1.2
    private static let separatorStrokeWidth: CGFloat = 2.1

    private static let planeOrigins: [CGPoint] = [
        CGPoint(x: 4.35, y: 2.30), // Back / bottom-right plane
        CGPoint(x: 2.75, y: 5.60), // Middle plane
        CGPoint(x: 1.15, y: 8.90)  // Front / top-left plane
    ]

    private static let idleAlphas: [CGFloat] = [0.40, 0.68, 1.0]
    private static let busyDimAlpha: CGFloat = 0.34
    private static let busyActiveAlpha: CGFloat = 1.0

    static let busyPhaseCount = 3

    private static let cachedIdleImage: NSImage = makeTemplateImage(activePhase: nil)
    private static let cachedBusyImages: [NSImage] = (0..<busyPhaseCount).map {
        makeTemplateImage(activePhase: $0)
    }

    static func idleImage() -> NSImage {
        cachedIdleImage
    }

    static func busyImage(phase: Int) -> NSImage {
        let normalized = ((phase % busyPhaseCount) + busyPhaseCount) % busyPhaseCount
        return cachedBusyImages[normalized]
    }

    // MARK: - Vector Drawing

    private static func makeTemplateImage(activePhase: Int?) -> NSImage {
        let image = NSImage(size: canvasSize, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            drawGlyph(in: ctx, bounds: rect, activePhase: activePhase)
            return true
        }
        // Template rendering lets AppKit adapt cleanly to Light/Dark mode and wallpaper-tinted menu bars.
        image.isTemplate = true
        image.accessibilityDescription = SpaceBootConfig.appName
        return image
    }

    private static func drawGlyph(in ctx: CGContext, bounds: CGRect, activePhase: Int?) {
        let scaleX = bounds.width / canvasSize.width
        let scaleY = bounds.height / canvasSize.height

        ctx.saveGState()
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.translateBy(x: bounds.minX, y: bounds.minY)
        ctx.scaleBy(x: scaleX, y: scaleY)

        let alphas: [CGFloat] = activePhase.map { phase in
            (0..<planeOrigins.count).map { $0 == phase ? busyActiveAlpha : busyDimAlpha }
        } ?? idleAlphas

        // Isolate .clear separator punch-outs to the glyph layer so surrounding context is untouched.
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        for index in 0..<planeOrigins.count {
            let planePath = slantedPlanePath(origin: planeOrigins[index])

            if index > 0 {
                ctx.setBlendMode(.clear)
                ctx.addPath(planePath)
                ctx.fillPath()
                ctx.setLineWidth(separatorStrokeWidth)
                ctx.setLineJoin(.round)
                ctx.addPath(planePath)
                ctx.strokePath()
            }

            ctx.setBlendMode(.normal)
            ctx.setFillColor(NSColor.black.withAlphaComponent(alphas[index]).cgColor)
            ctx.addPath(planePath)
            ctx.fillPath()
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private static func slantedPlanePath(origin: CGPoint) -> CGPath {
        let p0 = CGPoint(x: origin.x, y: origin.y)
        let p1 = CGPoint(x: origin.x + planeWidth, y: origin.y)
        let p2 = CGPoint(x: origin.x + planeWidth + planeSlant, y: origin.y + planeHeight)
        let p3 = CGPoint(x: origin.x + planeSlant, y: origin.y + planeHeight)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: (p0.x + p1.x) * 0.5, y: p0.y))
        path.addArc(tangent1End: p1, tangent2End: p2, radius: cornerRadius)
        path.addArc(tangent1End: p2, tangent2End: p3, radius: cornerRadius)
        path.addArc(tangent1End: p3, tangent2End: p0, radius: cornerRadius)
        path.addArc(tangent1End: p0, tangent2End: p1, radius: cornerRadius)
        path.closeSubpath()
        return path
    }
}
