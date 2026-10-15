#if os(iOS)
import SwiftUI

extension View {
    /// Liquid Glass on iOS 26 and later, a material elsewhere.
    @ViewBuilder
    func supportGlass(cornerRadius: CGFloat? = nil, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0).interactive() } ?? Glass.regular.interactive()
            if let cornerRadius {
                self.glassEffect(glass, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            } else {
                self.glassEffect(glass, in: Capsule())
            }
        } else {
            supportMaterial(cornerRadius: cornerRadius, tint: tint)
        }
        #else
        supportMaterial(cornerRadius: cornerRadius, tint: tint)
        #endif
    }

    @ViewBuilder
    private func supportMaterial(cornerRadius: CGFloat?, tint: Color?) -> some View {
        if let cornerRadius {
            self.background(tint ?? Color.clear, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            self.background(tint ?? Color.clear, in: Capsule()).background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Colours for the chat, built from the app's accent.
struct SupportPalette {
    let accent: Color
    /// Lighter, warmer and hotter neighbours of the accent for the hero and avatars.
    let light: Color
    let hot: Color
    let warm: Color
    let deep: Color
    /// Text and icons drawn on the accent (dark on a bright accent such as yellow).
    let onAccent: Color

    init(_ accent: Color) {
        self.accent = accent
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        if !UIColor(accent).getHue(&h, saturation: &s, brightness: &b, alpha: &a) { h = 0.7; s = 0.7; b = 1 }
        func hsb(_ hue: CGFloat, _ sat: CGFloat, _ bri: CGFloat) -> Color {
            Color(hue: Double((hue.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)), saturation: Double(min(1, max(0, sat))), brightness: Double(min(1, max(0, bri))))
        }
        light = hsb(h - 0.02, s * 0.72, b * 1.08 + 0.05)
        hot = hsb(h + 0.23, max(0.2, s * 0.6), 1)
        warm = hsb(h + 0.38, max(0.2, s * 0.62), 1)
        deep = hsb(h + 0.005, s * 1.05, b * 0.86)
        var r: CGFloat = 0, g: CGFloat = 0, bl: CGFloat = 0
        UIColor(accent).getRed(&r, green: &g, blue: &bl, alpha: &a)
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * bl
        onAccent = luminance > 0.62 ? Color(white: 0.08) : .white
    }

    var bubble: LinearGradient { LinearGradient(colors: [light, deep], startPoint: .topLeading, endPoint: .bottomTrailing) }
}

enum SupportColors {
    static let background = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1) : UIColor(red: 0.961, green: 0.957, blue: 0.976, alpha: 1) })
    static let card = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.115, blue: 0.14, alpha: 1) : .white })
    static let muted = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.62, alpha: 1) : UIColor(red: 0.54, green: 0.525, blue: 0.596, alpha: 1) })
    static let shadow = Color(red: 0.16, green: 0.08, blue: 0.35)
}

/// A bubble with its own radius per corner (iOS 15 has no UnevenRoundedRectangle).
struct SupportBubbleShape: Shape {
    var topLeading: CGFloat = 22, topTrailing: CGFloat = 22, bottomTrailing: CGFloat = 22, bottomLeading: CGFloat = 22

    func path(in rect: CGRect) -> Path {
        let m = min(rect.width, rect.height) / 2
        let tl = min(topLeading, m), tr = min(topTrailing, m), br = min(bottomTrailing, m), bl = min(bottomLeading, m)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        p.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        p.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        p.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        p.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }
}

/// A round avatar: a person's initial, or a symbol, on a gradient.
struct SupportAvatar: View {
    let name: String?
    let size: CGFloat
    let colors: [Color]
    var symbol: String? = nil
    /// A portrait (the AI assistant's); the initial shows until it loads, or if it can't.
    var image: URL? = nil

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Group {
                if let symbol { Image(systemName: symbol) } else { Text(SupportText.initial(name)) }
            }
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            if let image {
                AsyncImage(url: image) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() } else { Color.clear }
                }
                .clipShape(Circle())
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The small "AI" tag on everything the AI assistant says.
struct SupportAITag: View {
    let palette: SupportPalette
    var body: some View {
        Text("AI").font(.system(size: 10, weight: .heavy)).tracking(0.4)
            .foregroundStyle(palette.accent)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityLabel("AI assistant")
    }
}

enum SupportText {
    static func clock(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func firstName(_ name: String?) -> String? {
        guard let name, !name.contains("@") else { return nil }
        return name.split(separator: " ").first.map(String.init)
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = Calendar.current.isDateInToday(date) || Calendar.current.isDateInYesterday(date) ? .short : .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func initial(_ name: String?) -> String {
        guard let c = name?.trimmingCharacters(in: .whitespaces).first else { return "•" }
        return String(c).uppercased()
    }
}
#endif
