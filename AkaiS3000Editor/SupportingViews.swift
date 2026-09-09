import SwiftUI

// MARK: - Scroll / drag / click capture

/// A transparent overlay that reports raw scroll-wheel / trackpad deltas, mouse
/// drags, and clicks back to SwiftUI, all from a single AppKit view. SwiftUI has
/// no native hook for raw wheel events, and layering a separate SwiftUI drag
/// gesture on top of a scroll-catching NSView steals the scroll events — so one
/// NSView owns all three interactions here to avoid them fighting.
///
/// It sits ABOVE the waveform canvas but BELOW the loop handles in the ZStack,
/// so a drag starting on a loop handle still moves the handle (the handle view
/// is hit first), while a drag anywhere else pans.
struct WaveformInteractionCatcher: NSViewRepresentable {
    /// (deltaY, cursorX, viewWidth). Positive deltaY = scroll up → zoom in.
    let onScroll: (CGFloat, CGFloat, CGFloat) -> Void
    /// (translationX, viewWidth) during a plain horizontal drag — pans.
    let onDrag: (CGFloat, CGFloat) -> Void
    /// Called once when a drag ends (or a click completes) so pan state can reset.
    let onDragEnded: () -> Void
    /// (cursorX, viewWidth) for a click that didn't move far — set the marker.
    let onClick: (CGFloat, CGFloat) -> Void
    /// (startX, currentX, viewWidth) during an OPTION-drag — live rubber-band
    /// selection. Reported continuously so the marquee can be drawn.
    let onSelect: (CGFloat, CGFloat, CGFloat) -> Void
    /// (startX, endX, viewWidth) when an OPTION-drag ends — commit zoom to range.
    let onSelectEnded: (CGFloat, CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.apply(onScroll: onScroll, onDrag: onDrag, onDragEnded: onDragEnded,
                onClick: onClick, onSelect: onSelect, onSelectEnded: onSelectEnded)
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.apply(onScroll: onScroll, onDrag: onDrag, onDragEnded: onDragEnded,
                     onClick: onClick, onSelect: onSelect, onSelectEnded: onSelectEnded)
    }

    final class CatcherView: NSView {
        private var onScroll: ((CGFloat, CGFloat, CGFloat) -> Void)?
        private var onDrag: ((CGFloat, CGFloat) -> Void)?
        private var onDragEnded: (() -> Void)?
        private var onClick: ((CGFloat, CGFloat) -> Void)?
        private var onSelect: ((CGFloat, CGFloat, CGFloat) -> Void)?
        private var onSelectEnded: ((CGFloat, CGFloat, CGFloat) -> Void)?

        private var mouseDownX: CGFloat = 0
        private var movedFar = false
        /// True when the current drag began with Option held — a zoom-to-region
        /// marquee rather than a pan.
        private var selecting = false

        func apply(onScroll: @escaping (CGFloat, CGFloat, CGFloat) -> Void,
                   onDrag: @escaping (CGFloat, CGFloat) -> Void,
                   onDragEnded: @escaping () -> Void,
                   onClick: @escaping (CGFloat, CGFloat) -> Void,
                   onSelect: @escaping (CGFloat, CGFloat, CGFloat) -> Void,
                   onSelectEnded: @escaping (CGFloat, CGFloat, CGFloat) -> Void) {
            self.onScroll = onScroll
            self.onDrag = onDrag
            self.onDragEnded = onDragEnded
            self.onClick = onClick
            self.onSelect = onSelect
            self.onSelectEnded = onSelectEnded
        }

        override func scrollWheel(with event: NSEvent) {
            // Prefer the precise (trackpad) delta; fall back to the coarse wheel
            // delta for a physical mouse. Only the vertical component drives zoom.
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
            guard dy != 0 else { return }
            let local = convert(event.locationInWindow, from: nil)
            onScroll?(dy, local.x, bounds.width)
        }

        override func mouseDown(with event: NSEvent) {
            mouseDownX = convert(event.locationInWindow, from: nil).x
            movedFar = false
            // Option held at press = zoom-to-region marquee for this whole drag.
            selecting = event.modifierFlags.contains(.option)
        }

        override func mouseDragged(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            let dx = x - mouseDownX
            if abs(dx) > 4 { movedFar = true }
            guard movedFar else { return }
            if selecting {
                onSelect?(mouseDownX, x, bounds.width)
            } else {
                onDrag?(dx, bounds.width)
            }
        }

        override func mouseUp(with event: NSEvent) {
            let x = convert(event.locationInWindow, from: nil).x
            if selecting {
                if movedFar { onSelectEnded?(mouseDownX, x, bounds.width) }
                // A near-zero Option-click does nothing (no region).
            } else if !movedFar {
                onClick?(x, bounds.width)
            }
            onDragEnded?()
            movedFar = false
            selecting = false
        }
    }
}

// MARK: - Waveform View

struct WaveformView: View {
    let audioData: Data
    let numSamples: Int
    let loopEnabled: Bool
    let loopStart: Binding<Double>?
    let loopEnd: Binding<Double>?
    let playhead: Double
    /// Optional play-start marker, in FRAMES. Click the waveform to set it;
    /// playback (in SampleDetailView) begins from here. nil = start of sample.
    let playStart: Binding<Double?>?
    @State private var waveformPoints: [CGFloat] = []
    /// Per-bucket signed min/max of the actual samples (normalised −1..1), so the
    /// drawn shape is the real waveform (sine looks like a sine, square like a
    /// square) rather than an absolute-value envelope.
    @State private var waveMin: [CGFloat] = []
    @State private var waveMax: [CGFloat] = []

    /// The visible sample window, in FRAMES: [viewStart, viewEnd). Defaults to
    /// the whole sample and is narrowed/widened by scroll-to-zoom. All x-axis
    /// math (waveform buckets, loop region, handles, playhead) is expressed
    /// relative to this window so zooming just changes what maps to [0, width].
    @State private var viewStart: Double = 0
    @State private var viewEnd: Double = 0
    /// Set once the first real window is established, so we don't keep resetting
    /// the zoom on every layout pass — only on first appear and on sample change.
    @State private var didInitWindow = false

    /// Smallest zoom window, in frames — stops zoom-in from collapsing to a
    /// single sample (which would just show one flat bar).
    private let minVisibleFrames: Double = 16

    /// Pan state: the visible window's start frame captured at drag begin, so
    /// the whole gesture pans relative to where it started (no drift).
    @State private var panAnchorStart: Double? = nil

    /// Latest known view width, captured from GeometryReader, so the key-event
    /// monitor (which has no geometry of its own) can zoom with the right width.
    @State private var lastWidth: CGFloat = 0
    /// Whether the pointer is currently over this waveform. The arrow-key zoom
    /// only acts while hovering, so it doesn't hijack arrows meant for the
    /// sidebar list when the mouse is elsewhere.
    @State private var isHovering = false
    /// The local key monitor handle, removed on disappear.
    @State private var keyMonitor: Any? = nil

    /// Live rubber-band selection (Option-drag), as x-pixels [start, current].
    /// nil when not selecting. On release the range is committed as the new zoom.
    @State private var selectionX: (CGFloat, CGFloat)? = nil

    init(audioData: Data, numSamples: Int = 0, loopEnabled: Bool = false,
         loopStart: Binding<Double>? = nil, loopEnd: Binding<Double>? = nil,
         playhead: Double = 0, playStart: Binding<Double?>? = nil) {
        self.audioData = audioData
        self.numSamples = numSamples
        self.loopEnabled = loopEnabled
        self.loopStart = loopStart
        self.loopEnd = loopEnd
        self.playhead = playhead
        self.playStart = playStart
    }

    /// The canonical sample count (slen) passed in from the header — the same
    /// value the Akai reports and the single source of truth for the waveform
    /// x-axis and loop-region scaling, so the drawn loop region matches playback.
    private var frameCount: Int {
        numSamples
    }

    /// Width of the current visible window in frames (guards against a zero/
    /// unset window before the first layout).
    private var visibleSpan: Double {
        let span = viewEnd - viewStart
        return span > 0 ? span : Double(max(frameCount, 1))
    }

    /// Map a sample frame to an x-pixel within the current visible window.
    private func frameToX(_ frame: Double, width: CGFloat) -> CGFloat {
        CGFloat((frame - viewStart) / visibleSpan) * width
    }

    /// Map an x-pixel back to a sample frame within the current visible window.
    private func xToFrame(_ x: CGFloat, width: CGFloat) -> Double {
        viewStart + Double(max(0, min(1, x / max(width, 1)))) * visibleSpan
    }

    /// Establish or reset the visible window to the whole sample.
    private func resetWindow() {
        viewStart = 0
        viewEnd = Double(max(frameCount, 1))
        didInitWindow = true
    }

    /// Handle one scroll tick: zoom about the cursor. Positive delta = zoom in.
    /// The frame under the cursor is held fixed so the waveform grows/shrinks
    /// around the pointer, then the window is clamped to [0, frameCount] with a
    /// minimum span.
    private func zoom(delta: CGFloat, cursorX: CGFloat, width: CGFloat) {
        guard frameCount > 0, width > 0 else { return }
        let total = Double(frameCount)
        // Current window, defaulting to the whole sample if not yet set.
        var start = didInitWindow ? viewStart : 0
        var end = didInitWindow ? viewEnd : total
        let span = max(end - start, 1)

        // Frame currently under the cursor — the fixed point of the zoom.
        let cursorFrac = Double(max(0, min(1, cursorX / width)))
        let anchorFrame = start + cursorFrac * span

        // Exponential zoom: each notch scales the span by a small factor. Sign of
        // delta chooses in/out; magnitude gives smooth trackpad response. Scroll
        // direction is flipped from the OS default here by request: scrolling up
        // (delta>0) zooms OUT, scrolling down zooms IN.
        let step = Double(delta) * 0.01
        let scale = exp(step)                // delta>0 (up) -> scale>1 -> zoom out
        var newSpan = span * scale
        newSpan = max(minVisibleFrames, min(total, newSpan))

        // Keep the anchor frame under the cursor: newStart so that
        // anchorFrame = newStart + cursorFrac * newSpan.
        var newStart = anchorFrame - cursorFrac * newSpan
        var newEnd = newStart + newSpan

        // Clamp to the sample bounds without changing the span.
        if newStart < 0 { newStart = 0; newEnd = newSpan }
        if newEnd > total { newEnd = total; newStart = total - newSpan }
        if newStart < 0 { newStart = 0 }

        start = newStart; end = newEnd
        viewStart = start; viewEnd = end
        didInitWindow = true
        computeWaveform(width: width)
    }

    /// Zoom by an explicit factor about a given frame (used by keyboard zoom,
    /// where there's no cursor). factor<1 zooms in, factor>1 zooms out. The
    /// anchor frame stays put; the window is clamped to [0, frameCount].
    private func zoomBy(factor: Double, anchorFrame: Double, width: CGFloat) {
        guard frameCount > 0, width > 0 else { return }
        let total = Double(frameCount)
        let span = visibleSpan
        let anchor = max(0, min(total, anchorFrame))
        let anchorFrac = span > 0 ? (anchor - viewStart) / span : 0.5
        var newSpan = span * factor
        newSpan = max(minVisibleFrames, min(total, newSpan))
        var newStart = anchor - anchorFrac * newSpan
        var newEnd = newStart + newSpan
        if newStart < 0 { newStart = 0; newEnd = newSpan }
        if newEnd > total { newEnd = total; newStart = total - newSpan }
        if newStart < 0 { newStart = 0 }
        viewStart = newStart; viewEnd = newEnd
        didInitWindow = true
        computeWaveform(width: width)
    }

    /// Keyboard zoom: up = zoom in, down = zoom out, anchored to the play-start
    /// marker (or the centre of the current view if no marker is set). Exposed
    /// (non-private) so SampleDetailView's key handler can call it.
    func keyboardZoom(zoomIn: Bool, width: CGFloat) {
        let anchor = playStart?.wrappedValue ?? (viewStart + visibleSpan / 2)
        zoomBy(factor: zoomIn ? 0.6 : 1.0 / 0.6, anchorFrame: anchor, width: width)
    }

    /// Keyboard pan: left/right arrows nudge the visible window by a fraction of
    /// its span. No effect when fully zoomed out (nowhere to pan).
    func keyboardPan(right: Bool) {
        guard frameCount > 0 else { return }
        let total = Double(frameCount)
        let span = visibleSpan
        guard span < total else { return }          // fully zoomed out
        let stepFrames = span * 0.2 * (right ? 1 : -1)
        var newStart = viewStart + stepFrames
        newStart = max(0, min(total - span, newStart))
        viewStart = newStart
        viewEnd = newStart + span
        computeWaveform(width: lastWidth)
    }

    /// Zoom the visible window to a pixel range selected by Option-drag. The two
    /// x-positions map to frames in the CURRENT window; the smaller becomes the
    /// new start, the larger the new end. To avoid over-zooming, a too-narrow
    /// drag is ignored (nothing happens) rather than snapping to an extreme zoom,
    /// and the resulting window is never allowed below a comfortable floor.
    private func zoomToRange(startX: CGFloat, endX: CGFloat, width: CGFloat) {
        guard frameCount > 0, width > 0 else { return }
        // Ignore accidental hair-thin selections: a drag under ~24px shouldn't
        // zoom at all (it would jump to an extreme close-up).
        let pixelSpan = abs(endX - startX)
        guard pixelSpan >= 24 else { return }

        let total = Double(frameCount)
        let a = xToFrame(min(startX, endX), width: width)
        let b = xToFrame(max(startX, endX), width: width)
        var newStart = max(0, min(a, b))
        var newEnd = min(total, max(a, b))
        // Don't zoom in tighter than a comfortable floor. Use a larger floor than
        // the scroll/keyboard minimum so drag-zoom lands somewhere readable
        // rather than on a handful of samples.
        let dragFloor = max(minVisibleFrames, min(total, 128))
        if newEnd - newStart < dragFloor {
            let mid = (newStart + newEnd) / 2
            newStart = max(0, mid - dragFloor / 2)
            newEnd = min(total, newStart + dragFloor)
            newStart = max(0, newEnd - dragFloor)
        }
        viewStart = newStart
        viewEnd = newEnd
        didInitWindow = true
        computeWaveform(width: width)
    }

    /// Pan the visible window horizontally by a pixel translation, relative to
    /// the window captured at the start of the drag. Positive translation drags
    /// the content right (reveals earlier frames), so the window moves left.
    /// Clamped to [0, frameCount] without changing the span.
    private func pan(translationX: CGFloat, width: CGFloat) {
        guard frameCount > 0, width > 0 else { return }
        let total = Double(frameCount)
        let span = visibleSpan
        // Anchor the pan to the window start at gesture begin.
        if panAnchorStart == nil { panAnchorStart = viewStart }
        let anchor = panAnchorStart ?? viewStart
        // Convert the pixel drag into a frame offset. Dragging right (positive)
        // should move the window's start DOWN (earlier), so subtract.
        let framesPerPixel = span / Double(width)
        var newStart = anchor - Double(translationX) * framesPerPixel
        // Clamp so the window stays within [0, total] and keeps its span.
        newStart = max(0, min(total - span, newStart))
        viewStart = newStart
        viewEnd = newStart + span
        computeWaveform(width: width)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                LinearGradient(
                    colors: [Color(nsColor: .controlBackgroundColor), Color(nsColor: .windowBackgroundColor)],
                    startPoint: .top, endPoint: .bottom
                )

                if waveformPoints.isEmpty {
                    Text("No audio data").font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Rectangle().fill(Color.secondary.opacity(0.15)).frame(height: 1)
                        .allowsHitTesting(false)

                    // The real waveform: one filled rectangle per bucket, from
                    // that bucket's min to its max. Drawing independent rects
                    // (rather than one closed min/max polygon) avoids any risk of
                    // self-intersecting contours cancelling out under the fill's
                    // winding rule — each bar fills unconditionally.
                    Canvas { context, size in
                        let n = min(waveMin.count, waveMax.count)
                        guard n > 0 else { return }
                        let midY = size.height / 2
                        let step = size.width / CGFloat(n)
                        func y(_ v: CGFloat) -> CGFloat { midY - v * midY }

                        var bars = Path()
                        for i in 0..<n {
                            let x = CGFloat(i) * step
                            let top = y(waveMax[i])
                            let bottom = y(waveMin[i])
                            let h = max(bottom - top, 1)   // at least 1px so silent/flat spans still show a hairline
                            bars.addRect(CGRect(x: x, y: top, width: max(step, 1), height: h))
                        }

                        context.fill(bars, with: .linearGradient(
                            Gradient(colors: [Color.blue.opacity(0.85), Color.blue.opacity(0.5)]),
                            startPoint: CGPoint(x: 0, y: 0),
                            endPoint: CGPoint(x: 0, y: size.height)))
                    }
                    .allowsHitTesting(false)

                    // Scroll / drag / click capture. A single AppKit view owns
                    // all three so they don't fight (a separate SwiftUI drag layer
                    // on top would steal the scroll events). Sits ABOVE the
                    // waveform canvas but BELOW the loop handles, so a drag that
                    // starts on a handle moves the handle, while a drag elsewhere
                    // pans and a click sets the play-start marker.
                    WaveformInteractionCatcher(
                        onScroll: { dy, cursorX, width in
                            zoom(delta: dy, cursorX: cursorX, width: width)
                        },
                        onDrag: { translationX, width in
                            pan(translationX: translationX, width: width)
                        },
                        onDragEnded: {
                            panAnchorStart = nil
                            selectionX = nil
                        },
                        onClick: { cursorX, width in
                            let frame = xToFrame(cursorX, width: width)
                            playStart?.wrappedValue = max(0, min(Double(frameCount), frame))
                        },
                        onSelect: { startX, currentX, _ in
                            selectionX = (startX, currentX)
                        },
                        onSelectEnded: { startX, endX, width in
                            selectionX = nil
                            zoomToRange(startX: startX, endX: endX, width: width)
                        }
                    )
                    .help("Scroll to zoom · drag to pan · ⌥-drag to zoom into a region · click to set play-start")

                    // Rubber-band selection overlay during an ⌥-drag. Purely a
                    // visual guide; the actual zoom happens on release.
                    if let sel = selectionX {
                        let x0 = min(sel.0, sel.1)
                        let x1 = max(sel.0, sel.1)
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.2))
                            .frame(width: max(0, x1 - x0), height: geo.size.height)
                            .offset(x: x0)
                            .overlay(
                                Rectangle()
                                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                                    .frame(width: max(0, x1 - x0), height: geo.size.height)
                                    .offset(x: x0)
                            )
                            .allowsHitTesting(false)
                    }

                    if loopEnabled, frameCount > 0,
                       let startBinding = loopStart, let endBinding = loopEnd {
                        let w = geo.size.width
                        let ls = min(startBinding.wrappedValue, Double(frameCount))
                        // Real playback is a simple bounded loop: S -> end of the
                        // buffer, then jump back to S. So for display we ALWAYS
                        // clamp the end to the buffer length, guaranteeing S sits
                        // left of E and the highlighted region never wraps off the
                        // right edge — matching what's actually heard.
                        let le = min(endBinding.wrappedValue, Double(frameCount))
                        // Positions are relative to the visible window now, so the
                        // loop markers track the zoom.
                        let startX = frameToX(ls, width: w)
                        let endX   = frameToX(le, width: w)
                        let regionW = max(0, endX - startX)

                        Rectangle()
                            .fill(Color.green.opacity(0.15))
                            .frame(width: regionW, height: geo.size.height)
                            .offset(x: startX)
                            .allowsHitTesting(false)

                        // Loop start handle — bar on its leading edge, at loopStart.
                        LoopHandle(color: .green, label: "S", barEdge: .leading)
                            .frame(width: 14, height: geo.size.height)
                            .offset(x: startX)
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let newVal = xToFrame(value.location.x, width: w)
                                    if newVal < endBinding.wrappedValue - 1 {
                                        startBinding.wrappedValue = max(0, newVal)
                                    }
                                }
                            )

                        // Loop end handle — bar on its trailing edge, at loopEnd
                        // (clamped to the buffer length).
                        LoopHandle(color: .red, label: "E", barEdge: .trailing)
                            .frame(width: 14, height: geo.size.height)
                            .offset(x: endX - 14)
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let newVal = xToFrame(value.location.x, width: w)
                                    if newVal > startBinding.wrappedValue + 1 {
                                        endBinding.wrappedValue = min(Double(frameCount), newVal)
                                    }
                                }
                            )
                    }

                    // Play-start marker: the frame playback begins from, set by
                    // clicking the waveform OR dragging this marker. Drawn only
                    // when set and within the visible window.
                    if let ps = playStart?.wrappedValue {
                        let psX = frameToX(ps, width: geo.size.width)
                        if psX >= 0 && psX <= geo.size.width {
                            let w = geo.size.width
                            ZStack(alignment: .top) {
                                Rectangle()
                                    .fill(Color.white)
                                    .frame(width: 1.5, height: geo.size.height)
                                Image(systemName: "triangle.fill")
                                    .font(.system(size: 7))
                                    .rotationEffect(.degrees(90))
                                    .foregroundStyle(.white)
                                    .offset(y: -1)
                            }
                            // A wider transparent hit area around the 1.5px line so
                            // it's grabbable, matching the loop handles. Dragging
                            // moves the play-start; clicking the waveform elsewhere
                            // still sets it via the interaction catcher below.
                            .frame(width: 14, height: geo.size.height, alignment: .top)
                            .contentShape(Rectangle())
                            .offset(x: psX - 7)
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let newVal = xToFrame(value.location.x, width: w)
                                    playStart?.wrappedValue = max(0, min(Double(frameCount), newVal))
                                }
                            )
                            .cursor(.resizeLeftRight)
                        }
                    }

                    if playhead > 0 {
                        // playhead is a 0..1 fraction of the WHOLE sample; convert
                        // to a frame, then into the visible window's x-space.
                        let playFrame = playhead * Double(max(frameCount, 1))
                        let playX = frameToX(playFrame, width: geo.size.width)
                        // Only draw it when it's actually within the visible window.
                        if playX >= 0 && playX <= geo.size.width {
                            Rectangle()
                                .fill(Color.white.opacity(0.8))
                                .frame(width: 1.5, height: geo.size.height)
                                .offset(x: playX)
                                .allowsHitTesting(false)
                        }
                    }

                    // Zoom hint / reset: only shown once zoomed in. Double-click
                    // anywhere (or this pill) to zoom back out to the whole sample.
                    if didInitWindow && (viewStart > 0 || viewEnd < Double(frameCount)) {
                        Button {
                            resetWindow(); computeWaveform(width: geo.size.width)
                        } label: {
                            Label("Fit", systemImage: "arrow.left.and.right")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .help("Zoom out to the whole sample")
                    }
                }
            }
            .onAppear {
                if !didInitWindow { resetWindow() }
                lastWidth = geo.size.width
                computeWaveform(width: geo.size.width)
                installKeyMonitor()
            }
            .onChange(of: geo.size.width) { _, newWidth in
                lastWidth = newWidth
                computeWaveform(width: newWidth)
            }
            .onChange(of: audioData) { _, _ in
                // New sample — reset the zoom to show all of it.
                resetWindow()
                computeWaveform(width: geo.size.width)
            }
            .onHover { inside in isHovering = inside }
            .onDisappear {
                if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            }
        }
    }

    /// Install a local key monitor for arrow-up/down zoom. Only acts while the
    /// pointer is over this waveform, so it never steals arrow keys from the
    /// sidebar list (whose own monitor navigates the sample/program lists). When
    /// it handles a key it returns nil to consume the event, so the sidebar
    /// monitor — registered earlier at app launch — never sees it.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isHovering else { return event }
            // 126 = up (zoom in), 125 = down (zoom out),
            // 123 = left (pan left), 124 = right (pan right).
            if event.keyCode == 126 {
                keyboardZoom(zoomIn: true, width: lastWidth); return nil
            }
            if event.keyCode == 125 {
                keyboardZoom(zoomIn: false, width: lastWidth); return nil
            }
            if event.keyCode == 123 {
                keyboardPan(right: false); return nil
            }
            if event.keyCode == 124 {
                keyboardPan(right: true); return nil
            }
            return event
        }
    }

    private func computeWaveform(width: CGFloat) {
        guard !audioData.isEmpty else { return }
        let requestedBuckets = Int(width * 2)
        guard requestedBuckets > 0 else { return }
        let localData = audioData
        // Snapshot the visible window on the main thread; default to the whole
        // sample if it hasn't been initialised yet.
        let totalFramesAll = localData.count / 2
        let winStart = didInitWindow ? Int(viewStart.rounded(.down)) : 0
        let winEnd = didInitWindow ? Int(viewEnd.rounded(.up)) : totalFramesAll

        DispatchQueue.global(qos: .userInitiated).async {
            let totalFrames = localData.count / 2
            guard totalFrames > 0 else {
                DispatchQueue.main.async {
                    self.waveformPoints = []; self.waveMin = []; self.waveMax = []
                }
                return
            }
            // Clamp the visible window to the real buffer.
            let lo = max(0, min(winStart, totalFrames - 1))
            let hi = max(lo + 1, min(winEnd, totalFrames))
            let windowFrames = hi - lo
            // Never use more buckets than there are samples IN THE WINDOW,
            // otherwise most buckets map to an empty fractional span
            // (startSample==endSample) and render as a flat line. For a tightly
            // zoomed window this means one bucket per sample — the truest shape.
            let buckets = min(requestedBuckets, windowFrames)
            guard buckets > 0 else { return }
            // Spread the VISIBLE window across ALL buckets. For each bucket
            // capture the signed MIN and MAX sample value, so the drawn band is
            // the actual waveform shape (sine, square, saw) rather than an
            // absolute-value envelope.
            var mins: [CGFloat] = []; mins.reserveCapacity(buckets)
            var maxs: [CGFloat] = []; maxs.reserveCapacity(buckets)
            for b in 0..<buckets {
                let startSample = lo + (b * windowFrames) / buckets
                var endSample = lo + ((b + 1) * windowFrames) / buckets
                if endSample <= startSample { endSample = startSample + 1 }
                endSample = min(endSample, totalFrames)
                var loV: Int32 = Int32.max
                var hiV: Int32 = Int32.min
                for s in startSample..<endSample {
                    let byteIdx = s * 2
                    if byteIdx + 1 < localData.count {
                        let v = Int32(Int16(bitPattern:
                            UInt16(localData[byteIdx]) | (UInt16(localData[byteIdx + 1]) << 8)))
                        if v < loV { loV = v }
                        if v > hiV { hiV = v }
                    }
                }
                if loV == Int32.max { loV = 0; hiV = 0 }
                mins.append(CGFloat(loV) / 32768.0)
                maxs.append(CGFloat(hiV) / 32768.0)
            }

            DispatchQueue.main.async {
                self.waveMin = mins
                self.waveMax = maxs
                self.waveformPoints = maxs   // non-empty marker for the "has audio" check
            }
        }
    }
}

// MARK: - Loop Handle

struct LoopHandle: View {
    let color: Color
    let label: String
    /// Which edge the vertical bar sits on, so it lines up exactly with the
    /// loop-region highlight edge rather than the centre of the handle.
    var barEdge: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: barEdge, spacing: 0) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(color)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Rectangle()
                .fill(color)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
        }
        .frame(width: 14)
        .cursor(.resizeLeftRight)
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        self.onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}

// MARK: - Toast

/// A transient, self-dismissing message that slides in at the bottom of the
/// view and fades out after a delay — no click needed.
struct ToastData: Equatable {
    var message: String
    var isError: Bool = false
    /// Unique token so re-showing the same text retriggers the animation/timer.
    var token = UUID()
}

struct ToastView: View {
    let data: ToastData

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: data.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(data.isError ? .orange : .green)
            Text(data.message)
                .font(.callout)
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2)))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
    }
}

extension View {
    /// Presents a toast bound to an optional ToastData. The toast auto-dismisses
    /// after `duration` seconds by clearing the binding.
    func toast(_ toast: Binding<ToastData?>, duration: Double = 2.0) -> some View {
        modifier(ToastModifier(toast: toast, duration: duration))
    }
}

private struct ToastModifier: ViewModifier {
    @Binding var toast: ToastData?
    let duration: Double
    @State private var workItem: DispatchWorkItem?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let toast {
                    ToastView(data: toast)
                        .padding(.bottom, 24)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .id(toast.token)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: toast)
            .onChange(of: toast?.token) { _, _ in
                guard toast != nil else { return }
                workItem?.cancel()
                let item = DispatchWorkItem {
                    withAnimation { toast = nil }
                }
                workItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: item)
            }
    }
}

// MARK: - Disk Path Bar

/// A thin strip shown at the top of the app when a disk image is loaded. Shows
/// the full file path; click it to reveal the file in Finder, or use the copy
/// button to put the path on the clipboard.
struct DiskPathBar: View {
    let url: URL
    @State private var copied = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            // Click the path to reveal in Finder.
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Text(url.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")

            // Copy path to clipboard.
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 14))
                    .foregroundStyle(copied ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help("Copy path")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

// MARK: - Greaseweazle Log View

/// Main-window view shown while Greaseweazle is reading/writing, or after it has
/// finished (until dismissed). Shows a progress bar and a live, scrolling log.
struct GreaseweazleLogView: View {
    @ObservedObject var runner: GreaseweazleRunner

    private var title: String {
        switch runner.activity {
        case .reading: return "Reading floppy…"
        case .writing: return "Writing floppy…"
        case .idle:    return "Greaseweazle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "opticaldiscdrive.fill")
                    .font(.largeTitle).foregroundStyle(.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.bold())
                    Text("Drive \(runner.drive.rawValue)")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if runner.isBusy {
                    Button(role: .destructive) { runner.cancel() } label: {
                        Label("Cancel", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button { runner.clearLog() } label: {
                        Label("Dismiss", systemImage: "xmark")
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Full path of the file being read/written.
            if let url = runner.currentFileURL {
                HStack(spacing: 6) {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    Text(url.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Progress bar: determinate if we parsed a percentage, else indeterminate.
            if let p = runner.progress {
                ProgressView(value: p) {
                    Text("\(Int(p * 100))%").font(.caption.monospaced())
                }
                .progressViewStyle(.linear)
            } else if runner.isBusy {
                ProgressView().progressViewStyle(.linear)
            }

            // Live log.
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(runner.logLines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(logColor(line))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(idx)
                        }
                    }
                    .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
                .onChange(of: runner.logLines.count) { _, count in
                    if count > 0 { withAnimation { proxy.scrollTo(count - 1, anchor: .bottom) } }
                }
            }
        }
        .padding(24)
    }

    private func logColor(_ line: String) -> Color {
        if line.hasPrefix("ERROR") || line.hasPrefix("✗") { return .red }
        if line.hasPrefix("✓") { return .green }
        if line.hasPrefix("$") { return .secondary }
        return .primary
    }
}

// MARK: - Info Card / Row

struct InfoCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        // Deliberately NOT a GroupBox. GroupBox doesn't reliably measure/
        // propagate height for dynamic content — confirmed twice now: once
        // with the Keyzones List (which needed a fixed frame to scroll within
        // but GroupBox grew it unbounded instead), and again here, where a
        // caption that wraps to 3 lines was getting clipped because GroupBox
        // under-measured the content's real height. A plain VStack always
        // sizes to exactly what its children report, no surprises. spacing:8
        // on the inner VStack matches GroupBox's old default stacking gap, so
        // callers passing several sibling views (e.g. multiple InfoRows) keep
        // the same visual spacing as before.
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
            // Each top-level row of `content` is forced to the card's full width
            // (see FullWidthRows). That single rule is what makes every control,
            // caption and label inside a card behave consistently: intrinsic
            // controls still lay out normally, but multi-line Text is given a
            // bounded width so it WRAPS instead of taking its ideal single-line
            // width and clipping at the card edge. Callers therefore don't need
            // to sprinkle `.frame(maxWidth: .infinity)` on every caption.
            _VariadicView.Tree(FullWidthRows(spacing: 8)) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor).opacity(0.4)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Lays out each top-level child of an InfoCard as its own full-width, leading-
/// aligned row. Because every row is offered (and fills) the card's full width,
/// multi-line Text inside a card wraps to the available width instead of taking
/// its ideal single-line width and clipping — so callers get correct wrapping
/// for free, without per-caption `.frame(maxWidth: .infinity)`.
private struct FullWidthRows: _VariadicView_MultiViewRoot {
    var spacing: CGFloat = 8

    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(children) { child in
                child.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Flow Layout

/// A simple left-to-right, top-to-bottom wrapping layout — lets pills/bubbles of
/// varying sizes pack naturally onto multiple lines (used by the program editor's
/// sample-pill bar).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, lineHeight: CGFloat = 0, totalHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                totalHeight += lineHeight + spacing
                x = 0; lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        totalHeight += lineHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Disk Map

/// A wide map of the whole disk: the 1600 real blocks wrapped across just 3
/// rows (instead of a tall 40-row square), full width, so each item gets far
/// more vertical room. Plain black background represents free space implicitly
/// — no grid lines, no per-block cells, no separate "free" bubble — with each
/// sample/program/volume drawn as one continuous rounded bubble merged from its
/// REAL FAT-chain run(s), positioned exactly where it physically sits. Hover
/// anywhere for exact details; names show inside a bubble when there's room.
struct DiskMapView: View {
    @ObservedObject var diskImage: AkaiDiskImage
    @State private var hoverText: String? = nil

    private let rows = 3
    private let rowHeight: CGFloat = 34   // fixed; total map height = rowHeight * rows

    private var cols: Int {
        max(1, Int(ceil(Double(diskImage.totalBlocks) / Double(rows))))
    }

    private var usedFraction: Double {
        guard diskImage.totalBlocks > 0 else { return 0 }
        return Double(diskImage.totalBlocks - diskImage.freeBlocks) / Double(diskImage.totalBlocks)
    }

    private func color(for kind: AkaiDiskImage.DiskBlockKind) -> Color {
        switch kind {
        case .system:  return Color.secondary.opacity(0.55)
        case .free:    return Color.black
        case .sample:  return Color(red: 0.91, green: 0, blue: 0.11)
        case .program: return Color.purple
        case .multi:   return Color.teal
        }
    }

    private func name(for kind: AkaiDiskImage.DiskBlockKind) -> String {
        switch kind {
        case .system:         return diskImage.diskName.isEmpty ? "VOLUME" : diskImage.diskName
        case .free:           return "Free Space"
        case .sample(let n):  return n
        case .program(let n): return n
        case .multi(let n):   return n
        }
    }

    private func kindLabel(for kind: AkaiDiskImage.DiskBlockKind) -> String {
        switch kind {
        case .system:  return "Volume"
        case .free:    return "Free"
        case .sample:  return "Sample"
        case .program: return "Program"
        case .multi:   return "Multi"
        }
    }

    private func sameItem(_ a: AkaiDiskImage.DiskBlockKind, _ b: AkaiDiskImage.DiskBlockKind) -> Bool {
        switch (a, b) {
        case (.system, .system), (.free, .free): return true
        case (.sample(let n1), .sample(let n2)): return n1 == n2
        case (.program(let n1), .program(let n2)): return n1 == n2
        case (.multi(let n1), .multi(let n2)): return n1 == n2
        default: return false
        }
    }

    /// One drawable, label-able segment: a horizontal run of same-item blocks
    /// within a single row (a contiguous FAT-chain run is split at row
    /// boundaries, since the grid wraps every `cols` blocks).
    private struct Segment {
        let row: Int
        let colStart: Int
        let colSpan: Int
        let kind: AkaiDiskImage.DiskBlockKind
    }

    /// Walk the real block map and merge consecutive blocks belonging to the
    /// same sample/program/system/free run into row-segments, so a file's actual
    /// contiguous space renders as ONE continuous bubble instead of many tiny
    /// cells. Free segments are dropped — the black background already shows them.
    private func segments(from map: [AkaiDiskImage.DiskBlockKind]) -> [Segment] {
        guard !map.isEmpty else { return [] }
        let c = cols
        var result: [Segment] = []
        var i = 0
        while i < map.count {
            let kind = map[i]
            var j = i + 1
            while j < map.count, sameItem(map[j], kind) { j += 1 }
            // [i, j) is one contiguous real run — split it at row boundaries.
            if case .free = kind {
                i = j
                continue
            }
            var start = i
            while start < j {
                let row = start / c
                let rowEnd = (row + 1) * c
                let segEnd = min(j, rowEnd)
                result.append(Segment(row: row, colStart: start % c, colSpan: segEnd - start, kind: kind))
                start = segEnd
            }
            i = j
        }
        return result
    }

    var body: some View {
        // Computed ONCE per render and reused by both the bubbles and the hover
        // layer below, rather than re-walking every FAT chain on every mouse move.
        let map = diskImage.blockMap()
        let segs = segments(from: map)
        let c = cols
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Disk Map")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%% used", usedFraction * 100))
                    .font(.system(.title3, design: .monospaced).bold())
            }

            GeometryReader { geo in
                let cellWidth = geo.size.width / CGFloat(c)

                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.black)

                    ForEach(Array(segs.enumerated()), id: \.offset) { _, seg in
                        segmentBubble(seg, cellWidth: cellWidth)
                    }

                    // Invisible hover layer on top: map pointer position back to a
                    // block index so hovering ANYWHERE (including plain black free
                    // space) shows exactly what's there. Reuses `map` computed
                    // above instead of recomputing it on every mouse-move tick.
                    Rectangle()
                        .fill(Color.clear)
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                let col = min(c - 1, max(0, Int(location.x / cellWidth)))
                                let row = min(rows - 1, max(0, Int(location.y / rowHeight)))
                                let idx = row * c + col
                                if idx >= 0 && idx < map.count { hoverText = detail(for: map[idx]) }
                            case .ended:
                                hoverText = nil
                            }
                        }
                }
                .frame(width: geo.size.width, height: rowHeight * CGFloat(rows), alignment: .topLeading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: rowHeight * CGFloat(rows))
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Hover readout (reserves its line so the layout doesn't jump).
            Text(hoverText ?? " ")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)

            // Legend.
            HStack(spacing: 16) {
                legendItem(color: Color(red: 0.91, green: 0, blue: 0.11), text: "Samples")
                legendItem(color: .purple, text: "Programs")
                legendItem(color: .teal, text: "Multis")
                legendItem(color: Color.secondary.opacity(0.55), text: "Volume / System")
                legendItem(color: .black, text: "Free")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func detail(for kind: AkaiDiskImage.DiskBlockKind) -> String {
        "\(kindLabel(for: kind)) \u{2014} \(name(for: kind))"
    }

    /// Draw one row-segment as a continuous rounded bubble at its real position,
    /// full row height, with the item's name centred inside if there's room
    /// (otherwise just the colour — hover still gives the name).
    ///
    /// A bubble's TRUE width can be sub-pixel for tiny files (e.g. a 1-block
    /// program in a ~530-column grid), making it invisible and impossible to
    /// hover. We fudge a minimum visual width so every item is at least visible
    /// and hoverable — the hover/help text always reports the real block count,
    /// so this is purely a visibility aid, not a misrepresentation of the data.
    private let minVisualWidth: CGFloat = 10

    @ViewBuilder
    private func segmentBubble(_ seg: Segment, cellWidth: CGFloat) -> some View {
        let realWidth = CGFloat(seg.colSpan) * cellWidth
        let width = max(realWidth, minVisualWidth)
        let height = rowHeight
        // Keep the bubble's centre anchored to its real position even when
        // fudged wider, so it still reads as "roughly here" rather than drifting.
        let realX = CGFloat(seg.colStart) * cellWidth
        let x = realX - (width - realWidth) / 2
        let y = CGFloat(seg.row) * rowHeight
        let inset: CGFloat = 1.5
        let label = name(for: seg.kind)
        let canFitLabel = width > 30

        ZStack {
            RoundedRectangle(cornerRadius: min(height, width) * 0.15)
                .fill(color(for: seg.kind))
            if canFitLabel {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.horizontal, 4)
            }
        }
        .frame(width: max(0, width - inset * 2), height: max(0, height - inset * 2))
        .position(x: x + width / 2, y: y + height / 2)
        .help(detail(for: seg.kind))
    }

    @ViewBuilder
    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text)
        }
    }
}

// MARK: - ADSR Envelope View

struct AdsrView: View {
    @Binding var attack: UInt8
    @Binding var decay: UInt8
    @Binding var sustain: UInt8
    @Binding var release: UInt8
    var color: Color = .green

    @State private var dragging: Handle? = nil

    enum Handle { case attack, decay, sustain, release }

    // Fixed layout constants — same approach as the JS reference implementation
    private let pad: CGFloat = 0
    private let yTopPad: CGFloat = 6
    private let yBotPad: CGFloat = 0

    private func calcPoints(size: CGSize) -> (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, p4: CGPoint) {
        let w = size.width - pad * 2
        let yBot = size.height - yBotPad
        let yTop = yTopPad
        let yRange = yBot - yTop

        let aFrac = CGFloat(attack)  / 99.0
        let dFrac = CGFloat(decay)   / 99.0
        let sFrac = CGFloat(sustain) / 99.0
        let rFrac = CGFloat(release) / 99.0

        // Segment widths: A/D/R are time (proportional), S is fixed (it's a level)
        let aW = aFrac * w * 0.25
        let dW = (0.05 + dFrac * 0.20) * w
        let sW = w * 0.25
        let rW = rFrac * 0.25 * w

        let x0 = pad
        let x1 = x0 + aW
        let x2 = x1 + dW
        let x3 = x2 + sW
        let x4 = x3 + rW

        let ySus = yBot - sFrac * yRange

        return (
            CGPoint(x: x0, y: yBot),   // p0: start (silence)
            CGPoint(x: x1, y: yTop),   // p1: attack peak (always full height)
            CGPoint(x: x2, y: ySus),   // p2: decay end (always at sustain level)
            CGPoint(x: x3, y: ySus),   // p3: sustain end
            CGPoint(x: x4, y: yBot)    // p4: release end (silence)
        )
    }

    // Map cursor x directly to a 0-99 value for each handle,
    // using the same geometry as calcPoints so the handle tracks the cursor exactly.
    private func xToVal(_ x: CGFloat, _ handle: Handle, _ pts: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, p4: CGPoint), _ size: CGSize) -> UInt8 {
        let w = size.width - pad * 2
        let frac: CGFloat
        switch handle {
        case .attack:
            frac = (x - pad) / (w * 0.25)
        case .decay:
            frac = (x - pts.p1.x - w * 0.05) / (w * 0.20)
        case .sustain:
            // x is actually y for sustain
            let yBot = size.height - yBotPad
            frac = (yBot - x) / (yBot - yTopPad)
        case .release:
            frac = (x - pts.p3.x) / (w * 0.25)
        }
        return UInt8(max(0, min(99, Int(frac * 99))))
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let pts = calcPoints(size: size)
            let sHandle = CGPoint(x: (pts.p2.x + pts.p3.x) / 2, y: pts.p2.y)

            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.black.opacity(0.35))
                    .allowsHitTesting(false)

                Canvas { ctx, cs in
                    let p = calcPoints(size: cs)

                    // Grid
                    for i in 1..<8 {
                        var line = Path()
                        let x = cs.width * CGFloat(i) / 8
                        line.move(to: CGPoint(x: x, y: 0))
                        line.addLine(to: CGPoint(x: x, y: cs.height))
                        ctx.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
                    }
                    for i in 1..<4 {
                        var line = Path()
                        let y = cs.height * CGFloat(i) / 4
                        line.move(to: CGPoint(x: 0, y: y))
                        line.addLine(to: CGPoint(x: cs.width, y: y))
                        ctx.stroke(line, with: .color(.white.opacity(0.06)), lineWidth: 0.5)
                    }

                    // Vertical dividers between ADSR sections
                    let dividerColor = GraphicsContext.Shading.color(color.opacity(0.25))
                    for x in [p.p1.x, p.p2.x, p.p3.x] {
                        var div = Path()
                        div.move(to: CGPoint(x: x, y: 0))
                        div.addLine(to: CGPoint(x: x, y: cs.height))
                        ctx.stroke(div, with: dividerColor, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }

                    // Fill
                    var fill = Path()
                    fill.move(to: p.p0)
                    fill.addLine(to: p.p1)
                    fill.addLine(to: p.p2)
                    fill.addLine(to: p.p3)
                    fill.addLine(to: p.p4)
                    fill.addLine(to: CGPoint(x: p.p4.x, y: p.p0.y))
                    fill.closeSubpath()
                    ctx.fill(fill, with: .color(color.opacity(0.10)))

                    // Envelope line
                    var env = Path()
                    env.move(to: p.p0)
                    env.addLine(to: p.p1)
                    env.addLine(to: p.p2)
                    env.addLine(to: p.p3)
                    env.addLine(to: p.p4)
                    ctx.stroke(env, with: .color(color), lineWidth: 2)
                }
                .allowsHitTesting(false)

                // Segment labels with values
                let aCenter = (pts.p0.x + pts.p1.x) / 2
                let dCenter = (pts.p1.x + pts.p2.x) / 2
                let sCenter = (pts.p2.x + pts.p3.x) / 2
                let rCenter = (pts.p3.x + pts.p4.x) / 2
                let labelY = size.height / 2

                Group {
                    adsrLabel(letter: "A", value: attack, x: max(5, aCenter), y: labelY)
                    adsrLabel(letter: "D", value: decay,   x: dCenter,          y: labelY)
                    adsrLabel(letter: "S", value: sustain, x: sCenter,          y: labelY)
                    adsrLabel(letter: "R", value: release, x: release == 0 ? pts.p3.x - 5 : min(pts.p4.x - 5, rCenter), y: labelY)
                }
                .allowsHitTesting(false)

                // Handles — white dots at exact node positions
                dot(at: pts.p1,  handle: .attack,  size: size, pts: pts)
                dot(at: pts.p2,  handle: .decay,   size: size, pts: pts)
                dot(at: sHandle, handle: .sustain,  size: size, pts: pts)
                dot(at: pts.p4,  handle: .release,  size: size, pts: pts)
            }
        }
    }

    @ViewBuilder
    private func adsrLabel(letter: String, value: UInt8, x: CGFloat, y: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(letter)
                .foregroundStyle(Color.white)
            Text("\(value)")
                .foregroundStyle(Color.yellow)
        }
        .font(.system(size: 11, weight: .regular, design: .monospaced))
        .multilineTextAlignment(.center)
        .position(x: x, y: y)
    }

    @ViewBuilder
    private func dot(at point: CGPoint, handle: Handle, size: CGSize, pts: (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, p4: CGPoint)) -> some View {
        Circle()
        .fill(Color.white)
        .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
            .frame(width: 12, height: 12)
            .position(point)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if dragging == nil { dragging = handle }
                        guard dragging == handle else { return }
                        // Map cursor position directly to value using same geometry
                        let v: UInt8
                        if handle == .sustain {
                            v = xToVal(value.location.y, handle, pts, size)
                        } else {
                            v = xToVal(value.location.x, handle, pts, size)
                        }
                        switch handle {
                        case .attack:  attack = v
                        case .decay:   decay = v
                        case .sustain: sustain = v
                        case .release: release = v
                        }
                    }
                    .onEnded { _ in dragging = nil }
            )
            .cursor(.pointingHand)
    }
}

/// A compact slider row matching the existing keyzone editor style.
struct EnvSlider: View {
    let label: String
    @Binding var value: UInt8
    var caption: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .frame(width: 60, alignment: .leading)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { Double(value) },
                    set: { value = UInt8($0) }
                ), in: 0...99, step: 1)
                Text("\(value)")
                    .frame(width: 30)
                    .font(.system(.body, design: .monospaced))
            }
            if !caption.isEmpty {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct DiskInfoView: View {
    @ObservedObject var diskImage: AkaiDiskImage

    /// One parameter where the S3000XL Operator's Manual states a default
    /// value that real hardware byte-diff testing found to be different.
    /// Populated ONLY from confirmed hardware evidence (a photographed LCD
    /// screen or an isolated byte-diff capture) — never guessed — since this
    /// table exists specifically to be trustworthy when the manual and the
    /// real machine disagree.
    struct DefaultDiscrepancy: Identifiable {
        let id = UUID()
        let parameter: String
        let manual: String
        let hardware: String
        let note: String
    }

    /// Confirmed discrepancies between the manual and real hardware. Add a row
    /// here only once a specific reading has been confirmed (photo or byte-diff)
    /// — see the doc comment above.
    static let knownDefaultDiscrepancies: [DefaultDiscrepancy] = [
        DefaultDiscrepancy(
            parameter: "Filter Key Follow",
            manual: "+12 (p.97: “+12 is the default”)",
            hardware: "0 (fresh keygroup, byte-diff confirmed)",
            note: "A real, never-touched keygroup was photographed at +00 — the manual's stated default doesn't match a genuinely fresh unit."
        )
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Image(systemName: "internaldrive.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 4) {
                        // Read-only — this is an info screen, not an editor.
                        Text(diskImage.diskName.isEmpty ? "Untitled Disk" : diskImage.diskName)
                            .font(.title.bold())
                        Text("Akai S3000 Disk Image")
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox {
                    DiskMapView(diskImage: diskImage)
                        .padding(.top, 4)
                }

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 16) {
                    InfoCard(title: "Contents") {
                        InfoRow(label: "Samples",     value: "\(diskImage.samples.count)")
                        InfoRow(label: "Programs",    value: "\(diskImage.programs.count)")
                        InfoRow(label: "Multis",      value: "\(diskImage.multis.count)")
                        InfoRow(label: "Total Files", value: "\(diskImage.samples.count + diskImage.programs.count + diskImage.multis.count)")
                    }
                    InfoCard(title: "Storage") {
                        InfoRow(label: "Total Blocks", value: "\(diskImage.totalBlocks)")
                        InfoRow(label: "Free Blocks",  value: "\(diskImage.freeBlocks)")
                        InfoRow(label: "Block Size",   value: "1024 bytes")
                        InfoRow(label: "Free Space",   value: formatSize(diskImage.freeBlocks * 1024))
                    }
                    InfoCard(title: "Disk Format") {
                        InfoRow(label: "Type",           value: "Akai S3000")
                        InfoRow(label: "Sector Size",    value: "1024 bytes")
                        InfoRow(label: "Sectors/Track",  value: "10")
                        InfoRow(label: "Tracks",         value: "80 × 2")
                        InfoRow(label: "Total Capacity", value: "1.64 MB")
                    }
                }

                if !Self.knownDefaultDiscrepancies.isEmpty {
                    InfoCard(title: "Default Discrepancies") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Cases where the S3000XL Operator's Manual states one default value, but real hardware (byte-diff testing or a photographed fresh unit) shows something different.")
                                .font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(alignment: .top) {
                                Text("Parameter").frame(width: 130, alignment: .leading)
                                Text("Manual Says").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Hardware Shows").frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Divider()
                            ForEach(Array(Self.knownDefaultDiscrepancies.enumerated()), id: \.element.id) { idx, d in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(alignment: .top) {
                                        Text(d.parameter).font(.system(.caption, design: .monospaced))
                                            .frame(width: 130, alignment: .leading)
                                        Text(d.manual).font(.caption)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Text(d.hardware).font(.caption).foregroundStyle(.orange)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    if !d.note.isEmpty {
                                        Text(d.note).font(.caption2).foregroundStyle(.tertiary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                if idx != Self.knownDefaultDiscrepancies.count - 1 { Divider() }
                            }
                        }
                    }
                }

                if !diskImage.samples.isEmpty {
                    InfoCard(title: "Samples") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(diskImage.samples) { s in
                                HStack {
                                    Text(s.header.name.isEmpty ? s.directoryEntry.name : s.header.name)
                                        .font(.system(.caption, design: .monospaced))
                                    Spacer()
                                    Text("\(s.header.sampleRate)Hz")
                                        .font(.caption2).foregroundStyle(.secondary)
                                    Text(midiNoteName(s.header.midiRootNote))
                                        .font(.caption2).foregroundStyle(.blue)
                                }
                                if diskImage.samples.last?.id != s.id { Divider() }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024       { return "\(bytes) B" }
        if bytes < 1024*1024  { return String(format: "%.1f KB", Double(bytes)/1024) }
        return String(format: "%.1f MB", Double(bytes)/1024/1024)
    }

    private func midiNoteName(_ note: UInt8) -> String {
        let names = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
        // -2, not -1: matches the real S3000XL's own octave display (confirmed
        // against hardware), not the common "middle C = C4" MIDI convention.
        let octave = Int(note) / 12 - 2
        return "\(names[Int(note) % 12])\(octave)"
    }
}
