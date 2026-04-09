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
    @State private var scrollTask: Task<Void, Never>? = nil

    // Scrolling parameters
    private let scrollSpeed: Double = 20 // points per second
    private let pauseDuration: Double = 5.0 // seconds to pause at start and end

    private var needsScrolling: Bool {
        textWidth > containerWidth && containerWidth > 0
    }

    private var scrollDistance: CGFloat {
        max(0, textWidth - containerWidth)
    }

    private var fontSize: CGFloat {
        FontSizeMap.baseSize(for: style) * fontScale
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
                    // Ignore sub-pixel fluctuations to prevent spurious mid-scroll restarts
                    guard abs(newWidth - containerWidth) > 1 else { return }
                    containerWidth = newWidth
                    restartAnimation()
                }
                .onChange(of: text) { _, _ in
                    // Cancel immediately and reset; wait for textWidth update to start
                    scrollTask?.cancel()
                    scrollTask = nil
                    offset = 0
                }
                .onChange(of: fontScale) { _, _ in
                    restartAnimation()
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
                                restartAnimation()
                            }
                            .onChange(of: geo.size.width) { _, newWidth in
                                textWidth = newWidth
                                restartAnimation()
                            }
                    }
                )
                .hidden()
        )
    }

    private func restartAnimation() {
        scrollTask?.cancel()
        scrollTask = nil
        // Suppress any in-flight SwiftUI animation when snapping back to start
        withTransaction(Transaction(animation: nil)) { offset = 0 }

        guard needsScrolling else { return }

        scrollTask = Task { @MainActor in
            await runScrollLoop()
        }
    }

    @MainActor
    private func runScrollLoop() async {
        // Brief settle delay so textWidth and containerWidth are both current
        try? await Task.sleep(for: .milliseconds(50))

        while !Task.isCancelled && needsScrolling {
            // Pause at start
            do {
                try await Task.sleep(for: .seconds(pauseDuration))
            } catch {
                return
            }
            guard !Task.isCancelled, needsScrolling else { return }

            // Scroll left to reveal end — compute distance fresh each iteration
            let distance = scrollDistance
            let duration = distance / scrollSpeed
            withAnimation(.linear(duration: duration)) {
                offset = -distance
            }

            // Pause at end
            do {
                try await Task.sleep(for: .seconds(duration + pauseDuration))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            // Jump back to start (no animation)
            offset = 0
        }
    }
}
