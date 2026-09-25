import AppKit
import SwiftUI
import TallyCore

// Ink on blue-black, matching the web palette. Ink is healthy; ember means a window is running out; active marks the account OpenCode uses.
enum Palette {
    static let ground = dynamic(light: 0xeef1f6, dark: 0x0f131b)
    static let panel = dynamic(light: 0xfafbfd, dark: 0x151b26)
    static let raised = dynamic(light: 0xffffff, dark: 0x1c2331)
    static let ink = dynamic(light: 0x121826, dark: 0xe7ebf3)
    static let dust = dynamic(light: 0x5b6577, dark: 0x8b95a8)
    static let line = dynamic(light: 0x121826, dark: 0xe7ebf3, alpha: 0.1)
    static let spent = dynamic(light: 0x121826, dark: 0xe7ebf3, alpha: 0.15)
    static let wash = dynamic(light: 0x121826, dark: 0xe7ebf3, alpha: 0.05)
    static let ember = dynamic(light: 0xd23f1a, dark: 0xff6e4a)
    static let active = dynamic(light: 0x1f7a52, dark: 0x5fd49a)

    private static func dynamic(light: Int, dark: Int, alpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
        })
    }
}

extension Font {
    static func readout(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight).width(.expanded).monospacedDigit()
    }
}

/// The allowance drawn as tally strokes; spent strokes fade. A tall mark shows where an even pace would be.
struct TallyMeter: View, Animatable {
    var percent: Double?
    var fill: Color = Palette.ink
    var uncertain = false
    var pace: Double? = nil
    var height: CGFloat = 12

    // Interpolating the percentage lets a changed reading ink in or fade out stroke by stroke.
    nonisolated var animatableData: Double {
        get { percent ?? 0 }
        set { if percent != nil { percent = newValue } }
    }

    var body: some View {
        Canvas { context, size in
            let pitch: CGFloat = 4.5, stroke: CGFloat = 2
            let filled = size.width * CGFloat(min(100, max(0, percent ?? 0)) / 100)
            var x: CGFloat = 0
            while x + stroke <= size.width {
                let rect = CGRect(x: x, y: 2, width: stroke, height: size.height - 4)
                let color = percent != nil && x + stroke / 2 < filled ? fill : Palette.spent
                if uncertain {
                    var y = rect.minY
                    while y < rect.maxY { context.fill(Path(CGRect(x: x, y: y, width: stroke, height: min(2.5, rect.maxY - y))), with: .color(color)); y += 4.5 }
                } else { context.fill(Path(rect), with: .color(color)) }
                x += pitch
            }
            if let pace {
                let px = size.width * CGFloat(min(100, max(0, pace)) / 100)
                context.fill(Path(roundedRect: CGRect(x: px - 1, y: 0, width: 2, height: size.height), cornerRadius: 1), with: .color(Palette.ink))
            }
        }
        .frame(height: height + 4)
        .accessibilityElement()
        .accessibilityValue("\(percent.map { "\(Int($0.rounded()))%" } ?? "Unknown") remaining")
    }
}

func clockLabel(_ date: Date, now: Date = Date()) -> String {
    let calendar = Calendar.current
    let time = date.formatted(date: .omitted, time: .shortened)
    if calendar.isDate(date, inSameDayAs: now) { return time }
    if date.timeIntervalSince(now) < 6 * 86_400 { return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)" }
    return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
}

/// Presses shrink slightly and spring back.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.22, bounce: 0.45), value: configuration.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10).frame(minHeight: 24)
            .foregroundStyle(prominent ? Palette.ground : Palette.ink)
            .background(prominent ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(configuration.isPressed ? Palette.spent : Palette.wash), in: Capsule())
            .overlay { if !prominent { Capsule().strokeBorder(Palette.line) } }
            .opacity(configuration.isPressed && prominent ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.22, bounce: 0.45), value: configuration.isPressed)
    }
}
