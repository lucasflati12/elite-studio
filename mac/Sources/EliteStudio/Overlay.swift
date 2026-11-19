import AppKit
import CoreText

/// Draws the Coppa Élite name/tag cards and the logo, at frame-pixel size.
/// The same images are used by the viewer and by the export, so they match exactly.
enum Overlay {
    static let night = NSColor(srgbRed: 9 / 255, green: 26 / 255, blue: 46 / 255, alpha: 224 / 255)
    static let line = NSColor(white: 1, alpha: 96 / 255)
    static let gold = NSColor(srgbRed: 1, green: 210 / 255, blue: 63 / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 11 / 255, green: 22 / 255, blue: 38 / 255, alpha: 1)

    static func registerFonts() {
        for name in ["ArchivoBlack", "Archivo800", "Archivo700"] {
            if let u = Bundle.main.url(forResource: name, withExtension: "woff") {
                CTFontManagerRegisterFontsForURL(u as CFURL, .process, nil)
            }
        }
    }

    static func display(_ size: CGFloat) -> NSFont {
        NSFont(name: "ArchivoBlack-Regular", size: size) ?? NSFont.systemFont(ofSize: size, weight: .black)
    }
    static func heavy(_ size: CGFloat) -> NSFont {
        NSFont(name: "Archivo-ExtraBold", size: size) ?? NSFont.systemFont(ofSize: size, weight: .heavy)
    }
    /// First-name font: Archivo ExtraBold sized so its capitals are exactly as tall as the surname's (Archivo Black).
    static func firstName(_ size: CGFloat) -> NSFont {
        let b = display(size), h = heavy(size)
        guard h.capHeight > 0 else { return h }
        return heavy(size * b.capHeight / h.capHeight)
    }

    /// Scale from the 1080-wide design to the sequence frame.
    static func unit(_ frame: CGSize) -> CGFloat { min(frame.width, frame.height) / 1080 }

    // MARK: - cards

    struct Element {
        let image: CGImage
        let rect: CGRect          // frame pixels, top-left origin
        let delay: Double         // seconds after clip start
    }

    private static var cache: [String: [Element]] = [:]

    static func elements(for card: TitleCard, frame: CGSize) -> [Element] {
        let key = "\(card.hashValue)|\(frame.width)x\(frame.height)"
        if let e = cache[key] { return e }
        if cache.count > 200 { cache.removeAll() }
        let k = unit(frame) * CGFloat(card.size)
        var out: [Element] = []
        let x0 = CGFloat(card.x) * frame.width
        let y0 = CGFloat(card.y) * frame.height
        if card.style == "text" {
            let f = display(64 * k)
            let text = NSAttributedString(string: card.names, attributes: [.font: f, .foregroundColor: NSColor.white,
                                                                          .strokeColor: NSColor.black, .strokeWidth: -3])
            let size = text.size()
            if let img = render(CGSize(width: size.width + 8 * k, height: size.height + 8 * k), { _ in text.draw(at: CGPoint(x: 4 * k, y: 4 * k)) }) {
                out.append(Element(image: img, rect: CGRect(x: x0, y: y0, width: CGFloat(img.width), height: CGFloat(img.height)), delay: 0))
            }
            cache[key] = out; return out
        }
        let names = card.names.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var nameH: CGFloat = 0
        if !names.isEmpty, let img = nameCard(names, label: card.label, showLabel: card.showLabel, k: k) {
            nameH = CGFloat(img.height)
            out.append(Element(image: img, rect: CGRect(x: x0, y: y0, width: CGFloat(img.width), height: nameH), delay: 0))
        }
        let tag = card.tag.trimmingCharacters(in: .whitespaces)
        if !tag.isEmpty, let img = tagCard(tag.uppercased(), k: k) {
            let y = nameH > 0 ? y0 + nameH + 10 * k : y0
            out.append(Element(image: img, rect: CGRect(x: x0, y: y, width: CGFloat(img.width), height: CGFloat(img.height)), delay: nameH > 0 ? 0.2 : 0))
        }
        cache[key] = out
        return out
    }

    /// Opacity and horizontal slide of a card element at `t` seconds into a clip of length `dur`.
    static func animation(t: Double, dur: Double, delay: Double, fade: Double, unit k: CGFloat) -> (alpha: Double, dx: CGFloat) {
        let fd = max(0.05, fade)
        let a0 = delay
        let c = { (v: Double) in min(1, max(0, v)) }
        let alpha = c((t - a0) / fd) * c(1 - (t - max(a0, dur - fd)) / fd)
        let dx = -60 * k * CGFloat(pow(1 - c((t - a0) / 0.45), 3))
        return (alpha, dx)
    }

    private static func attr(_ s: String, _ font: NSFont, _ color: NSColor, _ kern: CGFloat) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern])
    }

    /// Draws text with its baseline exactly at `baseline` (top-left based, flipped context).
    private static func drawOnBaseline(_ s: NSAttributedString, x: CGFloat, baseline: CGFloat, _ ctx: CGContext) {
        let line = CTLineCreateWithAttributedString(s)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func render(_ size: CGSize, _ draw: (CGContext) -> Void) -> CGImage? {
        let w = Int(ceil(size.width)), h = Int(ceil(size.height))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let g = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        draw(ctx)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private static func nameCard(_ names: [String], label: String, showLabel: Bool, k: CGFloat) -> CGImage? {
        let parts: [(String, String)] = names.map {
            let toks = $0.uppercased().split(separator: " ").map(String.init)
            return toks.count == 1 ? ("", toks[0]) : (toks[0], toks.dropFirst().joined(separator: " "))
        }
        var size: CGFloat = names.count == 1 ? 60 : 46
        var tw: CGFloat = 0
        while true {
            tw = parts.map { f, l in
                (f.isEmpty ? 0 : attr(f, firstName(size * k), .white, k).size().width)
                    + (!f.isEmpty && !l.isEmpty ? 22 * k : 0)
                    + (l.isEmpty ? 0 : attr(l, display(size * k), .white, k).size().width)
            }.max() ?? 0
            if tw <= 780 * k || size <= 30 { break }
            size -= 2
        }
        let hasLabel = showLabel && !label.isEmpty
        let lab = attr(label, heavy(20 * k), gold, 6 * k)
        let labW = hasLabel ? lab.size().width : 0
        let padx = 36 * k
        let labBlock: CGFloat = hasLabel ? 40 * k : 0
        let lineH = (size * 1.28 * k).rounded()
        let top = (hasLabel ? 22 : 18) * k
        let h = top + labBlock + lineH * CGFloat(names.count) + 20 * k
        let w = padx * 2 + max(tw, labW)
        return render(CGSize(width: w, height: h)) { ctx in
            night.setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: w, height: h)).fill()
            line.setStroke()
            let b = NSBezierPath(rect: CGRect(x: k, y: k, width: w - 2 * k, height: h - 2 * k))
            b.lineWidth = 2 * k
            b.stroke()
            if hasLabel { lab.draw(at: CGPoint(x: padx, y: top - 2 * k)) }
            var y = top + labBlock
            for (f, l) in parts {
                // both names sit on one baseline, capitals vertically centred in the line
                let bf = display(size * k), ff = firstName(size * k)
                let baseline = y + (lineH + bf.capHeight) / 2
                var x = padx
                if !f.isEmpty {
                    let s = attr(f, ff, NSColor(white: 1, alpha: 235 / 255), k)
                    drawOnBaseline(s, x: x, baseline: baseline, ctx)
                    x += s.size().width + 22 * k
                }
                if !l.isEmpty { drawOnBaseline(attr(l, bf, .white, k), x: x, baseline: baseline, ctx) }
                y += lineH
            }
        }
    }

    private static func tagCard(_ tag: String, k: CGFloat) -> CGImage? {
        let s = attr(tag, display(46 * k), ink, 8 * k)
        let px = 38 * k, h = 76 * k
        let w = px * 2 + s.size().width - 8 * k
        return render(CGSize(width: w, height: h)) { _ in
            gold.setFill()
            NSBezierPath(rect: CGRect(x: 0, y: 0, width: w, height: h)).fill()
            let f = display(46 * k)
            s.draw(at: CGPoint(x: px, y: (h - (f.ascender - f.descender)) / 2))
        }
    }

    // MARK: - logo

    private static var logoCache: (key: String, image: CGImage)?
    private static var logoSource: CGImage? = {
        guard let u = Bundle.main.url(forResource: "coppa-elite-logo", withExtension: "png"),
              let img = NSImage(contentsOf: u)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return img
    }()

    static func logo(settings s: SequenceSettings) -> Element? {
        guard s.showLogo, let src = logoSource else { return nil }
        let frame = s.size
        let k = unit(frame)
        let side = CGFloat(s.logoSize) * k
        let key = "\(side)"
        let img: CGImage
        if let c = logoCache, c.key == key { img = c.image } else {
            guard let r = render(CGSize(width: side, height: side), { ctx in
                ctx.interpolationQuality = .high
                ctx.saveGState()
                ctx.translateBy(x: 0, y: side); ctx.scaleBy(x: 1, y: -1)
                ctx.draw(src, in: CGRect(x: 0, y: 0, width: side, height: side))
                ctx.restoreGState()
            }) else { return nil }
            img = r
            logoCache = (key, r)
        }
        let margin = 44 * k
        let x = s.logoRight ? frame.width - side - margin : margin
        let y = CGFloat(s.logoY) / 1920 * frame.height
        return Element(image: img, rect: CGRect(x: x, y: y, width: side, height: side), delay: 0)
    }
}
