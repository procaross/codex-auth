import SwiftUI

enum Palette {
    static let selection = Color(.sRGB, red: 0.31, green: 0.46, blue: 0.48, opacity: 1)
    static let teal = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.48, green: 0.91, blue: 0.86, alpha: 1)
            : NSColor(red: 0.03, green: 0.53, blue: 0.59, alpha: 1)
    })
    static let coral = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1, green: 0.63, blue: 0.52, alpha: 1)
            : NSColor(red: 0.85, green: 0.37, blue: 0.29, alpha: 1)
    })
    static let mint = Color(red: 0.37, green: 0.88, blue: 0.80)
}

struct PixelDot { let x: Double; let y: Double }

enum RobotArtwork {
    static let dots: [PixelDot] = {
        guard let url = Bundle.main.url(forResource: "portrait-64", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let offsets = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]
        var dots: [PixelDot] = []
        for (row, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            for (column, scalar) in line.unicodeScalars.enumerated() where (0x2800...0x28ff).contains(scalar.value) {
                let mask = scalar.value - 0x2800
                for (bit, offset) in offsets.enumerated() where mask & (1 << bit) != 0 {
                    dots.append(PixelDot(x: Double(column * 2 + offset.0), y: Double(row * 4 + offset.1)))
                }
            }
        }
        return dots
    }()
}

struct PixelRobot: View {
    let running: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var pointer = CGPoint.zero
    @State private var hovering = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !running || reduceMotion)) { timeline in
            let time = running && !reduceMotion ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, size in
                let scale = min(size.width, size.height) / 136
                let breath = reduceMotion ? 0 : sin(time * 1.7) * 1.3
                let shiftX = hovering && !reduceMotion ? pointer.x * 2.5 : 0
                let shiftY = hovering && !reduceMotion ? pointer.y * 1.5 : 0
                let origin = CGPoint(x: (size.width - 128 * scale) / 2 + shiftX, y: 5 + breath + shiftY)
                let scan = (time * 15).truncatingRemainder(dividingBy: 178) - 25
                var base = Path(), bright = Path(), medium = Path()
                for dot in RobotArtwork.dots {
                    let distance = abs(dot.y - scan)
                    let radius = scale * (distance < 4 ? 0.46 : 0.40)
                    let rect = CGRect(x: origin.x + dot.x * scale, y: origin.y + dot.y * scale, width: radius * 2, height: radius * 2)
                    if running && !reduceMotion && distance < 3 { bright.addEllipse(in: rect) }
                    else if running && !reduceMotion && distance < 10 { medium.addEllipse(in: rect) }
                    else { base.addEllipse(in: rect) }
                }
                context.fill(base, with: .color(colorScheme == .dark ? Palette.mint.opacity(0.78) : Palette.teal.opacity(0.88)))
                context.fill(medium, with: .color(colorScheme == .dark ? Palette.mint : Palette.teal))
                context.fill(bright, with: .color(colorScheme == .dark ? .white : Palette.coral))
                let beacon = CGRect(x: origin.x + 23 * scale - 2, y: origin.y - 1, width: 4, height: 4)
                context.fill(Path(ellipseIn: beacon), with: .color(Palette.coral.opacity(0.75 + sin(time * 2) * 0.2)))
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hovering = true; pointer = CGPoint(x: (point.x - 100) / 100, y: (point.y - 100) / 100)
            case .ended: hovering = false
            }
        }
        .accessibilityLabel("半色调像素机器人").accessibilityAddTraits(.isImage)
    }
}

struct DotMeter: View {
    let remaining: Double?
    var threshold: Double = 10
    var body: some View {
        Canvas { context, size in
            let count = max(12, Int(size.width / 5.5))
            let filled = remaining.map { Int(ceil($0 / 100 * Double(count * 3))) } ?? 0
            let step = size.width / Double(count)
            let dotSize = min(2.4, step * 0.52)
            var on = Path(), off = Path()
            for column in 0..<count {
                for row in 0..<3 {
                    let rect = CGRect(x: Double(column) * step, y: Double(row) * 4.8, width: dotSize, height: dotSize)
                    if column * 3 + row < filled { on.addRoundedRect(in: rect, cornerSize: CGSize(width: 0.5, height: 0.5)) }
                    else { off.addRoundedRect(in: rect, cornerSize: CGSize(width: 0.5, height: 0.5)) }
                }
            }
            context.fill(off, with: .color(.secondary.opacity(0.17)))
            context.fill(on, with: .color((remaining ?? 100) <= threshold ? Palette.coral : Palette.teal))
        }
        .frame(height: 13).accessibilityHidden(true)
    }
}
