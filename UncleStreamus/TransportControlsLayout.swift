import SwiftUI

// MARK: - Proportional transport row

/// Per-subview weight for `ProportionalHStack`. Default 1 (a standard button);
/// the FX button uses a smaller weight so it stays proportionally narrower.
struct ButtonWeightKey: LayoutValueKey {
    static let defaultValue: CGFloat = 1
}

extension View {
    func buttonWeight(_ weight: CGFloat) -> some View {
        layoutValue(key: ButtonWeightKey.self, value: weight)
    }
}

/// Lays out its subviews in a row, dividing the proposed width by each subview's
/// `ButtonWeightKey` weight. Unlike a `GeometryReader`-measured width, this runs
/// synchronously every layout pass, so the buttons track an animating container
/// width in lockstep with no `@State` round-trip (no jump, ratchet, or deadlock).
struct ProportionalHStack: Layout {
    var spacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) { $0 + $1.sizeThatFits(.unspecified).width }
        let height = subviews
            .map { $0.sizeThatFits(ProposedViewSize(width: nil, height: proposal.height)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let totalSpacing = spacing * CGFloat(max(0, subviews.count - 1))
        let avail = max(0, bounds.width - totalSpacing)
        let weights = subviews.map { $0[ButtonWeightKey.self] }
        let totalWeight = weights.reduce(0, +)
        var x = bounds.minX
        for (i, sub) in subviews.enumerated() {
            let w = totalWeight > 0
                ? avail * (weights[i] / totalWeight)
                : avail / CGFloat(subviews.count)
            sub.place(at: CGPoint(x: x, y: bounds.minY),
                      anchor: .topLeading,
                      proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w + spacing
        }
    }
}

// MARK: - Width-reveal transition

/// Reveals/collapses a view by animating its frame width while clipping the
/// (fixed-width) content — so an inline sidebar pushes the main content in
/// lockstep instead of sliding in over pre-reserved space, with no content squish.
struct WidthReveal: ViewModifier {
    var width: CGFloat
    var fullWidth: CGFloat
    var alignment: Alignment
    /// On transition removal SwiftUI freezes the departing view's origin at its
    /// leading edge. For a trailing-pinned panel (right sidebar) that makes the
    /// content slide left as the width shrinks; offsetting by `fullWidth - width`
    /// keeps the clip window pinned to the screen's right edge instead.
    var pinTrailing: Bool = false

    func body(content: Content) -> some View {
        content
            .frame(width: width, alignment: alignment)
            .clipped()
            // Clip the window FIRST, then translate it: `.offset` is render-only
            // (doesn't move layout bounds), so clipping after offset would clip at the
            // un-offset position and the content/clip would misalign (stray black bar).
            .offset(x: pinTrailing ? (fullWidth - width) : 0)
            // Let the panel's List/Form background fill the bottom safe area (home
            // indicator) instead of `.clipped()` leaving a black strip. `.container`
            // only — so it doesn't fight the keyboard for the history search field.
            .ignoresSafeArea(.container, edges: .bottom)
    }
}

extension AnyTransition {
    /// Leading-pinned reveal (left sidebar). The leading edge stays planted on both
    /// insert and remove, so no offset compensation is needed.
    static func widthReveal(_ width: CGFloat, alignment: Alignment) -> AnyTransition {
        .modifier(
            active: WidthReveal(width: 0, fullWidth: width, alignment: alignment),
            identity: WidthReveal(width: width, fullWidth: width, alignment: alignment)
        )
    }

    /// Trailing-pinned reveal (right sidebar). Insertion needs no compensation, but
    /// removal does (see `pinTrailing`), so the two directions are asymmetric.
    static func widthRevealTrailing(_ width: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: WidthReveal(width: 0, fullWidth: width, alignment: .trailing),
                identity: WidthReveal(width: width, fullWidth: width, alignment: .trailing)
            ),
            removal: .modifier(
                active: WidthReveal(width: 0, fullWidth: width, alignment: .trailing, pinTrailing: true),
                identity: WidthReveal(width: width, fullWidth: width, alignment: .trailing, pinTrailing: true)
            )
        )
    }
}
