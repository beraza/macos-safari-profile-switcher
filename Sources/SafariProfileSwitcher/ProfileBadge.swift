import AppKit
import SwiftUI
import SwitcherCore

/// How a profile looks: its badge text (or the Private Browsing symbol), color and name.
struct ProfileLook: Equatable {
    let name: String
    let badge: String
    let color: NSColor
    let isPrivate: Bool

    /// Safari marks Private Browsing with a raised hand.
    static let privateSymbol = "hand.raised.fill"

    static let unknown = ProfileLook(name: "", badge: "•", color: .systemGray, isPrivate: false)
}

extension AppSettings {
    func look(for profile: String, among profiles: [String]) -> ProfileLook {
        ProfileLook(
            name: ProfileMatcher.displayName(profile), badge: badge(for: profile),
            color: color(for: profile, among: profiles).color, isPrivate: profile == ProfileMatcher.privateProfile)
    }
}

/// A colored circle with the badge text, as in the switcher.
struct ProfileBadge: View {
    let look: ProfileLook
    var size: CGFloat = 26

    var body: some View {
        Group {
            if look.isPrivate && look.badge.isEmpty {
                Image(systemName: ProfileLook.privateSymbol).font(.system(size: size * 0.45, weight: .semibold))
            } else {
                Text(look.badge)
                    .font(.system(size: size * (look.badge.count > 1 ? 0.36 : 0.48), weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .background(Circle().fill(Color(nsColor: look.color)))
    }
}

extension NSImage {
    /// A rounded badge for the menu bar, like Safari's profile pill: the badge text (or symbol) on the
    /// profile's color, optionally followed by the name. `dimmed` while Safari isn't the front app.
    static func menuBarBadge(_ look: ProfileLook, showName: Bool, dimmed: Bool) -> NSImage {
        let height: CGFloat = 17
        let font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let symbol = look.isPrivate && look.badge.isEmpty
            ? NSImage(systemSymbolName: ProfileLook.privateSymbol, accessibilityDescription: look.name)?
                .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold).applying(.init(paletteColors: [.white])))
            : nil
        let label = (symbol == nil ? look.badge : "") + (showName ? (symbol == nil ? " " : "") + look.name : "")
        let text = NSAttributedString(string: label, attributes: attributes)
        let symbolWidth = symbol.map { $0.size.width + (showName ? 4 : 0) } ?? 0
        let width = max(height, ceil(text.size().width) + symbolWidth + 10)
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            look.color.withAlphaComponent(dimmed ? 0.45 : 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: height / 2, yRadius: height / 2).fill()
            var x = (rect.width - text.size().width - symbolWidth) / 2
            if let symbol {
                symbol.draw(in: NSRect(x: x, y: (height - symbol.size.height) / 2,
                                       width: symbol.size.width, height: symbol.size.height))
                x += symbolWidth
            }
            text.draw(at: NSPoint(x: x, y: (height - text.size().height) / 2))
            return true
        }
        image.accessibilityDescription = look.name
        return image
    }
}

extension NSImage {
    /// A color dot for menus (SwiftUI menus show images, not shapes).
    static func swatch(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        return image
    }
}
