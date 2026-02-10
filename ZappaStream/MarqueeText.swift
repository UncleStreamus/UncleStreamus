import SwiftUI

/// A text view that scrolls horizontally when the content is wider than the available space
struct MarqueeText: View {
    let text: String
    let style: Font.TextStyle
    let weight: Font.Weight

    @Environment(\.fontScale) private var fontScale

    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var isAnimating = false

    // Scrolling parameters
    private let scrollSpeed: Double = 30 // points per second
    private let pauseDuration: Double = 2.0 // seconds to pause at start and end

    private var needsScrolling: Bool {
        textWidth > containerWidth && containerWidth > 0
    }

    /// How far we need to scroll to reveal the end of the text
    private var scrollDistance: CGFloat {
        max(0, textWidth - containerWidth)
    }

    private var fontSize: CGFloat {
        let baseSize: CGFloat = {
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
        }()
        return baseSize * fontScale
    }

    var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width

            Text(text)
                .font(.system(size: fontSize, weight: weight))
                .fixedSize()
                .offset(x: offset)
                .frame(width: availableWidth, alignment: .leading)
                .clipped()
                .onAppear {
                    containerWidth = availableWidth
                }
                .onChange(of: availableWidth) { _, newWidth in
                    containerWidth = newWidth
                    restartAnimation()
                }
                .onChange(of: text) { _, _ in
                    measureAndAnimate()
                }
                .onChange(of: fontScale) { _, _ in
                    measureAndAnimate()
                }
        }
        .frame(height: fontSize * 1.3) // Approximate line height
        .background(
            // Measure text width off-screen
            Text(text)
                .font(.system(size: fontSize, weight: weight))
                .fixedSize()
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear {
                                textWidth = geo.size.width
                                startScrollingIfNeeded()
                            }
                            .onChange(of: geo.size.width) { _, newWidth in
                                textWidth = newWidth
                            }
                    }
                )
                .hidden()
        )
    }

    private func measureAndAnimate() {
        // Reset and remeasure
        isAnimating = false
        offset = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            startScrollingIfNeeded()
        }
    }

    private func startScrollingIfNeeded() {
        guard needsScrolling, !isAnimating else { return }
        isAnimating = true
        offset = 0
        animateScroll()
    }

    private func restartAnimation() {
        isAnimating = false
        offset = 0

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            startScrollingIfNeeded()
        }
    }

    private func animateScroll() {
        guard needsScrolling, isAnimating else {
            isAnimating = false
            return
        }

        let scrollDuration = scrollDistance / scrollSpeed

        // Pause at start
        DispatchQueue.main.asyncAfter(deadline: .now() + pauseDuration) {
            guard self.isAnimating, self.needsScrolling else { return }

            // Scroll left to reveal the end
            withAnimation(.linear(duration: scrollDuration)) {
                self.offset = -self.scrollDistance
            }

            // Pause at end, then jump back to start
            DispatchQueue.main.asyncAfter(deadline: .now() + scrollDuration + pauseDuration) {
                guard self.isAnimating else { return }

                // Jump back to start (no animation)
                self.offset = 0

                // Continue the loop
                self.animateScroll()
            }
        }
    }
}
