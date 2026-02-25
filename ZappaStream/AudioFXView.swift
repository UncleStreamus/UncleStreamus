#if os(macOS)
import SwiftUI

// MARK: - EQ Scale (Canvas-drawn tick marks + dB labels)

struct EQScaleView: View {
    let height: CGFloat

    private let marks: [(db: Int, major: Bool)] = [
        (6, true), (3, false), (0, true), (-3, false), (-6, true)
    ]

    var body: some View {
        Canvas { ctx, size in
            for m in marks {
                let y = size.height * CGFloat(6 - m.db) / 12.0

                var path = Path()
                path.move(to: CGPoint(x: size.width - (m.major ? 8 : 5), y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(
                    path,
                    with: m.db == 0 ? .foreground : .color(.secondary.opacity(0.55)),
                    lineWidth: m.major ? 1.0 : 0.5
                )

                let label = m.db > 0 ? "+\(m.db)" : "\(m.db)"
                var drawCtx = ctx
                drawCtx.opacity = m.db == 0 ? 0.85 : 0.45
                let resolved = drawCtx.resolve(
                    Text(label)
                        .font(.system(size: 7, weight: m.db == 0 ? .semibold : .regular))
                )
                let anchor: UnitPoint
                switch m.db {
                case 6:  anchor = .topLeading
                case -6: anchor = .bottomLeading
                default: anchor = .leading
                }
                drawCtx.draw(resolved, at: CGPoint(x: 0, y: y), anchor: anchor)
            }
        }
        .frame(width: 28, height: height)
    }
}

// MARK: - Vertical EQ Fader (Canvas-based)

struct VerticalEQSlider: View {
    @Binding var value: Float   // -6 … +6 dB
    let onUpdate: () -> Void

    private let thumbSize:  CGFloat = 20
    private let trackWidth: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let trackTop = thumbSize / 2
            let trackH   = geo.size.height - thumbSize
            let centerY  = trackTop + trackH / 2

            Canvas { (ctx: inout GraphicsContext, size: CGSize) in
                let normalised = CGFloat((value + 6) / 12)
                let thumbY     = (1 - normalised) * trackH
                let thumbMidY  = thumbY + thumbSize / 2
                let fillTop    = min(thumbMidY, centerY)
                let fillHeight = abs(thumbMidY - centerY)
                let fillColor: Color = value >= 0 ? .blue : .orange
                let cx         = size.width / 2

                // Track rail
                ctx.fill(
                    Path(roundedRect: CGRect(x: cx - trackWidth/2, y: trackTop,
                                            width: trackWidth, height: trackH),
                         cornerRadius: trackWidth / 2),
                    with: .color(.secondary.opacity(0.22))
                )

                // Active fill
                if fillHeight > 1 {
                    ctx.fill(
                        Path(roundedRect: CGRect(x: cx - trackWidth/2, y: fillTop,
                                                width: trackWidth, height: fillHeight),
                             cornerRadius: 2),
                        with: .color(fillColor.opacity(0.35))
                    )
                }

                // 0 dB notch
                let notchW: CGFloat = trackWidth + 8
                ctx.fill(
                    Path(CGRect(x: cx - notchW/2, y: centerY - 0.5,
                                width: notchW, height: 1)),
                    with: .color(.secondary.opacity(0.55))
                )

                // Thumb
                let thumbRect = CGRect(x: cx - thumbSize/2, y: thumbY,
                                       width: thumbSize, height: thumbSize)
                let thumbPath = Path(ellipseIn: thumbRect)
                var shadowCtx = ctx
                shadowCtx.addFilter(.shadow(color: Color.black.opacity(0.28),
                                            radius: 2.5, x: 0, y: 1.5))
                shadowCtx.fill(thumbPath, with: .color(.white))
                ctx.stroke(thumbPath, with: .color(Color.accentColor), lineWidth: 1.5)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let relY = drag.location.y - trackTop
                        value = 6 - max(0, min(1, Float(relY / trackH))) * 12
                        onUpdate()
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    withAnimation(.spring(response: 0.25)) { value = 0 }
                    onUpdate()
                }
            )
        }
    }
}

// MARK: - Horizontal Slider (Canvas-based)

struct FXHorizontalSlider: View {
    @Binding var value: Float   // 0…1 normalised
    let resetValue: Float
    let onUpdate: () -> Void

    private let thumbSize:   CGFloat = 20
    private let trackHeight: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let trackLeft = thumbSize / 2
            let trackW    = geo.size.width - thumbSize
            let cy        = geo.size.height / 2

            Canvas { (ctx: inout GraphicsContext, size: CGSize) in
                let thumbX = trackLeft + CGFloat(value) * trackW

                // Track rail
                ctx.fill(
                    Path(roundedRect: CGRect(x: trackLeft, y: cy - trackHeight / 2,
                                            width: trackW, height: trackHeight),
                         cornerRadius: trackHeight / 2),
                    with: .color(.secondary.opacity(0.22))
                )

                // Fill from left to thumb
                let fillW = max(0, thumbX - trackLeft)
                if fillW > 0 {
                    ctx.fill(
                        Path(roundedRect: CGRect(x: trackLeft, y: cy - trackHeight / 2,
                                                width: fillW, height: trackHeight),
                             cornerRadius: trackHeight / 2),
                        with: .color(Color.accentColor.opacity(0.35))
                    )
                }

                // Thumb
                let thumbRect = CGRect(x: thumbX - thumbSize / 2, y: cy - thumbSize / 2,
                                      width: thumbSize, height: thumbSize)
                let thumbPath = Path(ellipseIn: thumbRect)
                var shadowCtx = ctx
                shadowCtx.addFilter(.shadow(color: Color.black.opacity(0.28),
                                            radius: 2.5, x: 0, y: 1.5))
                shadowCtx.fill(thumbPath, with: .color(.white))
                ctx.stroke(thumbPath, with: .color(Color.accentColor), lineWidth: 1.5)
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let relX = drag.location.x - trackLeft
                        value = max(0, min(1, Float(relX / trackW)))
                        onUpdate()
                    }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    withAnimation(.spring(response: 0.25)) { value = resetValue }
                    onUpdate()
                }
            )
        }
        .frame(height: 22)
    }
}

// MARK: - EQ Band View

struct EQBandView: View {
    let label: String
    @Binding var gain: Float
    let onUpdate: () -> Void

    private let trackHeight: CGFloat = 90

    var body: some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 28)
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.25)) { gain = 0 }
                    onUpdate()
                }

            HStack(spacing: 3) {
                EQScaleView(height: trackHeight)
                VerticalEQSlider(value: $gain, onUpdate: onUpdate)
                    .frame(height: trackHeight)
            }

            Text(gain > 0 ? "+\(Int(gain.rounded())) dB"
                 : gain < 0 ? "\(Int(gain.rounded())) dB"
                 : "0 dB")
                .font(.caption2)
                .monospacedDigit()
                .foregroundColor(gain > 0 ? .blue : gain < 0 ? .orange : .secondary)
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.25)) { gain = 0 }
                    onUpdate()
                }
        }
        .frame(width: 68)
    }
}

// MARK: - Stereo Width Slider

struct StereoWidthSlider: View {
    @Binding var value: Float

    private let snapPoint:   Float  = 0.75
    private let snapRadius:  Float  = 0.025
    private let thumbSize:   CGFloat = 20
    private let trackHeight: CGFloat = 5
    @State private var isSnapped = true

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let trackLeft = thumbSize / 2
                let trackW    = geo.size.width - thumbSize
                let cy        = geo.size.height / 2

                Canvas { (ctx: inout GraphicsContext, size: CGSize) in
                    let thumbX  = trackLeft + CGFloat(value) * trackW
                    let markerX = trackLeft + trackW * CGFloat(snapPoint)

                    ctx.fill(
                        Path(roundedRect: CGRect(x: trackLeft, y: cy - trackHeight / 2,
                                                width: trackW, height: trackHeight),
                             cornerRadius: trackHeight / 2),
                        with: .color(.secondary.opacity(0.22))
                    )

                    let fillW = max(0, thumbX - trackLeft)
                    if fillW > 0 {
                        ctx.fill(
                            Path(roundedRect: CGRect(x: trackLeft, y: cy - trackHeight / 2,
                                                    width: fillW, height: trackHeight),
                                 cornerRadius: trackHeight / 2),
                            with: .color(Color.accentColor.opacity(0.35))
                        )
                    }

                    // Snap marker at "Original" (0.75)
                    ctx.fill(
                        Path(CGRect(x: markerX - 0.75, y: cy - 10, width: 1.5, height: 20)),
                        with: .color(Color.accentColor.opacity(0.65))
                    )

                    let thumbRect = CGRect(x: thumbX - thumbSize / 2, y: cy - thumbSize / 2,
                                          width: thumbSize, height: thumbSize)
                    let thumbPath = Path(ellipseIn: thumbRect)
                    var shadowCtx = ctx
                    shadowCtx.addFilter(.shadow(color: Color.black.opacity(0.28),
                                                radius: 2.5, x: 0, y: 1.5))
                    shadowCtx.fill(thumbPath, with: .color(.white))
                    ctx.stroke(thumbPath, with: .color(Color.accentColor), lineWidth: 1.5)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let relX   = drag.location.x - trackLeft
                            let newVal = max(0, min(1, Float(relX / trackW)))
                            let inZone = abs(newVal - snapPoint) < snapRadius
                            if isSnapped && !inZone {
                                isSnapped = false
                                value     = newVal
                            } else if !isSnapped && inZone {
                                isSnapped = true
                                value     = snapPoint
                            } else if isSnapped {
                                value     = snapPoint
                            } else {
                                value     = newVal
                            }
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        withAnimation(.spring(response: 0.25)) { value = snapPoint }
                        isSnapped = true
                    }
                )
            }
            .frame(height: 22)

            GeometryReader { labelGeo in
                let trackLeft = thumbSize / 2
                let trackW    = labelGeo.size.width - thumbSize
                let markerX   = trackLeft + trackW * CGFloat(snapPoint)

                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        Text("Mono")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Wider")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 3) {
                        Image(systemName: "diamond.fill")
                            .font(.system(size: 7))
                        Text("Original")
                            .font(.caption2)
                    }
                    .foregroundColor(.accentColor)
                    .fixedSize()
                    .position(x: markerX, y: labelGeo.size.height / 2)
                }
            }
            .frame(height: 16)
        }
    }
}

// MARK: - Stereo Pan Slider

struct StereoPanSlider: View {
    @Binding var value: Float   // 0 = full left, 0.5 = center, 1 = full right

    private let snapPoint:   Float  = 0.5
    private let snapRadius:  Float  = 0.025
    private let thumbSize:   CGFloat = 20
    private let trackHeight: CGFloat = 5
    @State private var isSnapped = true

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let trackLeft = thumbSize / 2
                let trackW    = geo.size.width - thumbSize
                let cy        = geo.size.height / 2
                let centerX   = trackLeft + trackW * CGFloat(snapPoint)

                Canvas { (ctx: inout GraphicsContext, size: CGSize) in
                    let thumbX = trackLeft + CGFloat(value) * trackW

                    ctx.fill(
                        Path(roundedRect: CGRect(x: trackLeft, y: cy - trackHeight / 2,
                                                width: trackW, height: trackHeight),
                             cornerRadius: trackHeight / 2),
                        with: .color(.secondary.opacity(0.22))
                    )

                    // Fill from center to thumb
                    let fillStart = min(thumbX, centerX)
                    let fillEnd   = max(thumbX, centerX)
                    let fillW     = fillEnd - fillStart
                    if fillW > 1 {
                        ctx.fill(
                            Path(roundedRect: CGRect(x: fillStart, y: cy - trackHeight / 2,
                                                    width: fillW, height: trackHeight),
                                 cornerRadius: trackHeight / 2),
                            with: .color(Color.accentColor.opacity(0.35))
                        )
                    }

                    // Center snap marker
                    ctx.fill(
                        Path(CGRect(x: centerX - 0.75, y: cy - 10, width: 1.5, height: 20)),
                        with: .color(Color.accentColor.opacity(0.65))
                    )

                    let thumbRect = CGRect(x: thumbX - thumbSize / 2, y: cy - thumbSize / 2,
                                          width: thumbSize, height: thumbSize)
                    let thumbPath = Path(ellipseIn: thumbRect)
                    var shadowCtx = ctx
                    shadowCtx.addFilter(.shadow(color: Color.black.opacity(0.28),
                                                radius: 2.5, x: 0, y: 1.5))
                    shadowCtx.fill(thumbPath, with: .color(.white))
                    ctx.stroke(thumbPath, with: .color(Color.accentColor), lineWidth: 1.5)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let relX   = drag.location.x - trackLeft
                            let newVal = max(0, min(1, Float(relX / trackW)))
                            let inZone = abs(newVal - snapPoint) < snapRadius
                            if isSnapped && !inZone {
                                isSnapped = false
                                value     = newVal
                            } else if !isSnapped && inZone {
                                isSnapped = true
                                value     = snapPoint
                            } else if isSnapped {
                                value     = snapPoint
                            } else {
                                value     = newVal
                            }
                        }
                )
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        withAnimation(.spring(response: 0.25)) { value = snapPoint }
                        isSnapped = true
                    }
                )
            }
            .frame(height: 22)

            HStack(spacing: 0) {
                Text("L")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 3) {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 7))
                    Text("Center")
                        .font(.caption2)
                }
                .foregroundColor(.accentColor)
                Spacer()
                Text("R")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Audio FX View

struct AudioFXView: View {
    @Bindable var player: BASSRadioPlayer

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {

                // — Master Bypass + Reset All —
                HStack {
                    Text("FX Bypass")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Button("Reset All") {
                        withAnimation(.spring(response: 0.25)) { player.resetAllFX() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Toggle("", isOn: $player.masterBypassEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .onChange(of: player.masterBypassEnabled) { player.updateMasterBypass() }
                }

                Text("Settings auto-reset at start of each show")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .italic()
                    .frame(maxWidth: .infinity, alignment: .leading)

                Divider()

                VStack(spacing: 12) {

                    // — 3-Band EQ —
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("3-Band EQ")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                            Toggle("", isOn: $player.eqEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .onChange(of: player.eqEnabled) { player.updateEQ() }
                        }

                        HStack(spacing: 12) {
                            EQBandView(label: "Low\n100 Hz",  gain: $player.eqLowGain,  onUpdate: player.updateEQ)
                            EQBandView(label: "Mid\n1 kHz",   gain: $player.eqMidGain,  onUpdate: player.updateEQ)
                            EQBandView(label: "High\n10 kHz", gain: $player.eqHighGain, onUpdate: player.updateEQ)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .opacity(player.eqEnabled ? 1.0 : 0.4)
                    }

                    Divider()

                    // — Compressor —
                    VStack(spacing: 6) {
                        HStack {
                            Text("Compressor")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                            Toggle("", isOn: $player.compressorOn)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .onChange(of: player.compressorOn) { player.updateCompressor() }
                        }
                        HStack {
                            Text("Gentle").font(.caption).foregroundColor(.secondary)
                            FXHorizontalSlider(value: $player.compressorAmount, resetValue: 0.5,
                                              onUpdate: player.updateCompressorAmount)
                            Text("Heavy").font(.caption).foregroundColor(.secondary)
                        }
                        .opacity(player.compressorOn ? 1.0 : 0.4)
                    }

                    Divider()

                    // — Stereo Width + Pan —
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Stereo Width")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                            Toggle("", isOn: $player.stereoWidthEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .onChange(of: player.stereoWidthEnabled) { player.saveFXToDefaults() }
                        }
                        StereoWidthSlider(value: $player.stereoWidth)
                            .opacity(player.stereoWidthEnabled ? 1.0 : 0.4)
                            .onChange(of: player.stereoWidth) { player.saveFXToDefaults() }

                        Text("Stereo Pan")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .padding(.top, 4)
                        StereoPanSlider(value: $player.stereoPan)
                            .opacity(player.stereoWidthEnabled ? 1.0 : 0.4)
                            .onChange(of: player.stereoPan) { player.saveFXToDefaults() }
                    }
                }
                .opacity(player.masterBypassEnabled ? 0.4 : 1.0)
            }
            .padding()
        }
    }
}
#endif
