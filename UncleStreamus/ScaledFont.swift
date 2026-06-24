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
        let font: Font
        if UIDevice.current.userInterfaceIdiom == .pad {
            let base = UIFont.preferredFont(forTextStyle: uiTextStyle(for: style)).pointSize
            font = .system(size: base * (1.2 / 1.1), weight: weight)
        } else {
            font = .system(style, weight: weight)
        }
        return content.font(font)
        #else
        return content.font(.system(size: FontSizeMap.baseSize(for: style) * fontScale, weight: weight))
        #endif
    }
}

#if os(iOS)
private func uiTextStyle(for style: Font.TextStyle) -> UIFont.TextStyle {
    switch style {
    case .largeTitle:    return .largeTitle
    case .title:         return .title1
    case .title2:        return .title2
    case .title3:        return .title3
    case .headline:      return .headline
    case .subheadline:   return .subheadline
    case .body:          return .body
    case .callout:       return .callout
    case .footnote:      return .footnote
    case .caption:       return .caption1
    case .caption2:      return .caption2
    @unknown default:    return .body
    }
}
#endif
