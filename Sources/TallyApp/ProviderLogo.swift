import AppKit
import SwiftUI
import TallyCore

enum ProviderArtwork {
    struct Logo: Decodable { let name: String; let svg: String }
    // Native and web use the same release-bundled artwork from the accepted prototype.
    static let logos = try! JSONDecoder().decode([String: Logo].self, from: Data(contentsOf: resource("logos", "json")))
    // Tally's own tally-mark glyph, shown in the menu bar when no Account is pinned. Source: assets/tally-glyph.svg.
    static let appGlyph = NSImage(data: try! Data(contentsOf: resource("tally-glyph", "svg")))!
    private static func resource(_ name: String, _ ext: String) -> URL {
        Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "Tally_TallyApp.bundle")
            ?? Bundle.module.url(forResource: name, withExtension: ext)!
    }
    static let light = [0x1d1d1f, 0x2456e6, 0xd96d0b, 0x1e8a4c, 0x8b3fc9, 0xcf2f5a]
    static let dark = [0xf5f5f7, 0x7d9bff, 0xffa24a, 0x4fd08a, 0xc58bf2, 0xff7e9e]
    static func color(_ index: Int, dark: Bool) -> Color {
        let hex = (dark ? self.dark : light)[index]
        return Color(.sRGB, red: Double(hex >> 16) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct ProviderLogo: View {
    let provider: String
    let color: Int
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        if let logo = ProviderArtwork.logos[provider], let image = NSImage(data: Data(logo.svg.utf8)) {
            Image(nsImage: image).resizable().renderingMode(.template)
                .foregroundStyle(ProviderArtwork.color(color, dark: scheme == .dark))
                .frame(width: size, height: size).accessibilityLabel(logo.name)
        }
    }
}

struct MenuPins: View {
    @ObservedObject var runtime: Runtime
    var body: some View {
        let pins = runtime.snapshot?.accounts.filter(\.pinned) ?? []
        HStack(spacing: 2) {
            if pins.isEmpty {
                Image(nsImage: ProviderArtwork.appGlyph).resizable().renderingMode(.template)
                    .frame(width: 18, height: 18).padding(.horizontal, 4).accessibilityLabel("Tally")
            }
            ForEach(pins) { account in
                HStack(spacing: 3) {
                    ProviderLogo(provider: account.provider, color: account.identityColorIndex, size: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        if account.pin.lines.isEmpty {
                            HStack(spacing: 1) {
                                Text("?").font(.system(size: 12, weight: .medium))
                                if account.pin.warning { Image(systemName: "exclamationmark.triangle").font(.system(size: 8)) }
                            }
                        }
                        ForEach(account.pin.lines, id: \.windowId) { line in
                            HStack(spacing: 1) {
                                Text(line.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "?")
                                if line.stale { Image(systemName: "exclamationmark.triangle").font(.system(size: 8)) }
                            }.font(.system(size: account.pin.lines.count == 2 ? 9.5 : 12, weight: account.pin.lines.count == 2 ? .semibold : .medium))
                                .frame(height: account.pin.lines.count == 2 ? 10 : 16)
                        }
                    }
                }.padding(.horizontal, 4).help(tooltip(account))
            }
        }.fixedSize().frame(height: 24).foregroundStyle(.primary)
    }
    private func tooltip(_ account: Account) -> String {
        let lines = account.pin.lines.map { "\($0.label): \($0.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "?")\($0.stale ? " (stale)" : "")" }
        return "\(account.name) · \(ProviderArtwork.logos[account.provider]?.name ?? account.provider)\n" + (lines.isEmpty ? "Quota unavailable" : lines.joined(separator: "\n"))
    }
}
