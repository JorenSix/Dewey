import AppKit

/// A menu row with a caption and an inline NSSlider (custom NSMenuItem view), optional end labels.
/// `tickMarks` (≥ 2) adds that many tick marks and snaps the slider to them; `valueText` shows a live
/// value label right-aligned on the caption row.
@MainActor
final class MenuSliderView: NSView {
    let slider: NSSlider
    private let onChange: (Double) -> Void
    private let valueText: ((Double) -> String)?
    private var valueLabel: NSTextField?
    private var lastSnapped: Double?

    init(title: String, min: Double, max: Double, value: Double,
         minLabel: String? = nil, maxLabel: String? = nil, tickMarks: Int? = nil,
         valueText: ((Double) -> String)? = nil, onChange: @escaping (Double) -> Void) {
        self.onChange = onChange
        self.valueText = valueText
        slider = NSSlider(value: value, minValue: min, maxValue: max, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 240,
                                 height: (minLabel == nil ? 46 : 54) + (tickMarks == nil ? 0 : 4)))
        autoresizingMask = [.width]

        let caption = NSTextField(labelWithString: title)
        caption.font = NSFont.menuFont(ofSize: 0)
        caption.textColor = .labelColor
        caption.frame = NSRect(x: 14, y: frame.height - 22, width: 212, height: 17)
        addSubview(caption)

        if let valueText {
            let v = NSTextField(labelWithString: valueText(value))
            v.font = NSFont.menuFont(ofSize: 0)
            v.textColor = .secondaryLabelColor
            v.alignment = .right
            v.frame = NSRect(x: 106, y: frame.height - 22, width: 120, height: 17)
            addSubview(v)
            valueLabel = v
        }

        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(changed(_:))
        if let tickMarks, tickMarks >= 2 {
            slider.numberOfTickMarks = tickMarks
            slider.allowsTickMarkValuesOnly = true
            slider.tickMarkPosition = .below
            lastSnapped = slider.doubleValue
        }
        slider.frame = NSRect(x: 14, y: minLabel == nil ? 4 : 14, width: 212, height: tickMarks == nil ? 20 : 22)
        addSubview(slider)

        if let minLabel, let maxLabel {
            for (text, x, align) in [(minLabel, 14.0, NSTextAlignment.left), (maxLabel, 126.0, .right)] {
                let l = NSTextField(labelWithString: text)
                l.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1)
                l.textColor = .secondaryLabelColor
                l.alignment = align
                l.frame = NSRect(x: x, y: 0, width: 100, height: 14)
                addSubview(l)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func changed(_ sender: NSSlider) {
        let v = sender.doubleValue
        valueLabel?.stringValue = valueText?(v) ?? ""
        if sender.allowsTickMarkValuesOnly {
            // Snapped slider: only report actual step changes (continuous drags repeat the same value).
            guard v != lastSnapped else { return }
            lastSnapped = v
        }
        onChange(v)
    }

    static func item(_ view: MenuSliderView) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = view
        return item
    }
}

/// Tiny fly glyph (template image) for the status item: head, thorax, abdomen, two swept wings.
@MainActor
func makeFlyGlyph(size: CGFloat = 18) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
        let s = r.width / 18
        NSColor.black.setFill()
        NSColor.black.setStroke()
        // Wings (outlined, swept back), drawn first.
        for side in [-1.0, 1.0] {
            let wing = NSBezierPath(ovalIn: NSRect(x: -2.6 * s, y: -6.2 * s, width: 5.2 * s, height: 9.5 * s))
            var t = AffineTransform(translationByX: 9 * s + CGFloat(side) * 3.6 * s, byY: 7.6 * s)
            t.rotate(byDegrees: CGFloat(side) * 28)
            wing.transform(using: t)
            wing.lineWidth = 1.1 * s
            wing.stroke()
        }
        // Abdomen, thorax, head (head up).
        NSBezierPath(ovalIn: NSRect(x: 6.6 * s, y: 1.2 * s, width: 4.8 * s, height: 7.6 * s)).fill()
        NSBezierPath(ovalIn: NSRect(x: 6.3 * s, y: 8.0 * s, width: 5.4 * s, height: 4.8 * s)).fill()
        NSBezierPath(ovalIn: NSRect(x: 7.0 * s, y: 12.4 * s, width: 4.0 * s, height: 3.4 * s)).fill()
        // Legs (three short strokes per side).
        let legs = NSBezierPath()
        legs.lineWidth = 0.9 * s
        for (dy, dx) in [(11.5, 3.2), (10.0, 3.8), (8.6, 3.2)] as [(CGFloat, CGFloat)] {
            legs.move(to: NSPoint(x: 7.0 * s, y: dy * s)); legs.line(to: NSPoint(x: (7.0 - dx) * s, y: (dy + (dy > 10 ? 1.6 : -1.6)) * s))
            legs.move(to: NSPoint(x: 11.0 * s, y: dy * s)); legs.line(to: NSPoint(x: (11.0 + dx) * s, y: (dy + (dy > 10 ? 1.6 : -1.6)) * s))
        }
        legs.stroke()
        return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "Dewey"
    return img
}
