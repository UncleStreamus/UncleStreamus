import SwiftUI

// MARK: - Font Scale Environment Key

private struct FontScaleKey: EnvironmentKey {
    static let defaultValue: Double = 1.0
}

extension EnvironmentValues {
    var fontScale: Double {
        get { self[FontScaleKey.self] }
        set { self[FontScaleKey.self] = newValue }
    }
}

// MARK: - Font Size Mapping

/// Shared base font sizes for text styles (used by ScaledFontModifier and MarqueeText)
enum FontSizeMap {
    static func baseSize(for style: Font.TextStyle) -> CGFloat {
        switch style {
        case .largeTitle: return 26
        case .title: return 22
        case .title2: return 17
        case .title3: return 15
        case .headline: return 13
        case .subheadline: return 11
        case .body: return 13
        case .callout: return 12
        case .footnote: return 10
        case .caption: return 10
        case .caption2: return 9
        @unknown default: return 13
        }
    }
}

// MARK: - Scaled Font View Extension

extension View {
    /// Applies a scaled system font based on the fontScale environment value
    func scaledFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> some View {
        self.modifier(ScaledFontModifier(style: style, weight: weight))
    }
}

private struct ScaledFontModifier: ViewModifier {
    @Environment(\.fontScale) private var fontScale
    let style: Font.TextStyle
    let weight: Font.Weight

    func body(content: Content) -> some View {
        #if os(iOS)
        // Use iOS native text styles for standard readability
        content.font(.system(style, weight: weight))
        #else
        // Keep custom scaled sizes for macOS
        content.font(.system(size: FontSizeMap.baseSize(for: style) * fontScale, weight: weight))
        #endif
    }
}
