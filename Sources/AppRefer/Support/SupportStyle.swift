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

enum SupportText {
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
