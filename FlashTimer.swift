import SwiftUI
import Combine
import AVFoundation
import UIKit

@main
struct FlashTimerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Patterns

/// A pattern is a flat list of time slots. One slot lasts 1 / (2 x speed) seconds,
/// so the Strobe pattern (on, off) behaves exactly like the original.
struct FlashPattern: Identifiable, Codable, Equatable {
    var id: String
    var name: String
    var units: [Bool]
    var defaultSpeed: Double
    var isCustom: Bool

    static let builtIns: [FlashPattern] = {
        let dot: [Bool] = [true, false]
        let dash: [Bool] = [true, true, true, false]
        let gap: [Bool] = [false, false]
        let s = dot + dot + dot
        let o = dash + dash + dash
        let sos = s + gap + o + gap + s + [Bool](repeating: false, count: 6)
        return [
            FlashPattern(id: "strobe", name: "Strobe", units: [true, false], defaultSpeed: 8, isCustom: false),
            FlashPattern(id: "double", name: "Double",
                         units: [true, false, true, false, false, false], defaultSpeed: 6, isCustom: false),
            FlashPattern(id: "triple", name: "Triple",
                         units: [true, false, true, false, true, false, false, false, false], defaultSpeed: 5, isCustom: false),
            FlashPattern(id: "long", name: "Long blink",
                         units: [true, true, true, false, false, false], defaultSpeed: 3, isCustom: false),
            FlashPattern(id: "sos", name: "SOS", units: sos, defaultSpeed: 4, isCustom: false)
        ]
    }()
}

struct PatternGlyph: View {
    let units: [Bool]

    var body: some View {
        Canvas { ctx, size in
            guard !units.isEmpty else { return }
            let w = size.width / CGFloat(units.count)
            for (i, on) in units.enumerated() where on {
                let rect = CGRect(x: CGFloat(i) * w, y: 0, width: max(1, w - 0.6), height: size.height)
                ctx.fill(Path(rect), with: .foreground)
            }
        }
    }
}

// MARK: - Torch engine

/// Owns the torch and the strobe timer. Everything runs on one serial queue,
/// so once stop() is queued no further flash can happen after it.
final class Strobe {
    private let queue = DispatchQueue(label: "strobe", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var device: AVCaptureDevice?
    private var generation = 0
    private var power: Float = 1
    private var pattern: [Bool] = [true, false]
    private var step = 0

    func start(hz: Double, power: Float, pattern: [Bool], until end: Date, onFinish: @escaping () -> Void) {
        queue.async {
            self.teardown()
            self.power = power
            self.pattern = pattern
            self.step = 0
            guard let d = AVCaptureDevice.default(for: .video), d.hasTorch else { return }
            do { try d.lockForConfiguration() } catch { return }
            self.device = d
            self.generation += 1
            let gen = self.generation
            var on = false
            var lastLevel: Float = -1

            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now(), repeating: 1.0 / (hz * 2), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in
                guard let self = self, self.generation == gen, let d = self.device else { return }
                if Date() >= end {
                    self.teardown()
                    DispatchQueue.main.async(execute: onFinish)
                    return
                }
                let seq = self.pattern.isEmpty ? [true, false] : self.pattern
                let wantOn = seq[self.step % seq.count]
                self.step += 1
                if wantOn {
                    let level = max(0.01, min(self.power, AVCaptureDevice.maxAvailableTorchLevel))
                    if !on || level != lastLevel {
                        try? d.setTorchModeOn(level: level)
                        lastLevel = level
                    }
                    on = true
                } else if on {
                    d.torchMode = .off
                    on = false
                }
            }
            self.timer = t
            t.resume()
        }
    }

    func setPower(_ p: Float) {
        queue.async { self.power = p }
    }

    func setPattern(_ p: [Bool]) {
        queue.async {
            self.pattern = p
            self.step = 0
        }
    }

    func setSpeed(_ hz: Double) {
        queue.async {
            self.timer?.schedule(deadline: .now(), repeating: 1.0 / (hz * 2), leeway: .milliseconds(1))
        }
    }

    func stop() {
        queue.async { self.teardown() }
    }

    private func teardown() {
        generation += 1
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        if let d = device {
            d.torchMode = .off
            d.unlockForConfiguration()
        }
        device = nil
    }
}

// MARK: - Design tokens

enum Palette {
    static let ink      = Color(red: 0.047, green: 0.051, blue: 0.063)
    static let panel    = Color(red: 0.086, green: 0.090, blue: 0.110)
    static let hairline = Color.white.opacity(0.07)
    static let tungsten = Color(red: 1.0, green: 0.78, blue: 0.42)
    static let text     = Color(red: 0.95, green: 0.94, blue: 0.91)
    static let muted    = Color(red: 0.56, green: 0.57, blue: 0.61)
}

// MARK: - Custom fader

struct Fader: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var impact: UIImpactFeedbackGenerator.FeedbackStyle? = nil
    /// A magnetic stop. Dragging within `snap` of it holds the value on the stop.
    var detent: Double? = nil
    var snap: Double = 0
    var detentLabel: String? = nil

    private let haptic = UISelectionFeedbackGenerator()

    var body: some View {
        GeometryReader { geo in
            let knob: CGFloat = 28
            let usable = max(1, geo.size.width - knob)
            let span = range.upperBound - range.lowerBound
            let frac = CGFloat((value - range.lowerBound) / span)
            let x = frac * usable

            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.09)).frame(height: 8)
                Capsule().fill(Palette.tungsten).frame(width: x + knob / 2, height: 8)

                if let d = detent {
                    let dx = CGFloat((d - range.lowerBound) / span) * usable + knob / 2
                    Capsule()
                        .fill(Palette.text.opacity(0.55))
                        .frame(width: 2, height: 18)
                        .offset(x: dx - 1)
                }

                Circle()
                    .fill(Palette.text)
                    .frame(width: knob, height: knob)
                    .offset(x: x)
            }
            .frame(height: knob)
            .overlay(alignment: .topLeading) {
                if let d = detent, let text = detentLabel {
                    let labelW: CGFloat = 52
                    let dx = CGFloat((d - range.lowerBound) / span) * usable + knob / 2
                    Text(text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.muted)
                        .frame(width: labelW)
                        .offset(x: min(max(0, dx - labelW / 2), geo.size.width - labelW), y: knob + 2)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = min(max(0, (g.location.x - knob / 2) / usable), 1)
                        var v = range.lowerBound + Double(f) * span
                        v = (v / step).rounded() * step
                        v = min(max(v, range.lowerBound), range.upperBound)
                        var snapped = false
                        if let d = detent, abs(v - d) <= snap {
                            v = d
                            snapped = true
                        }
                        if v != value {
                            value = v
                            if snapped {
                                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            } else if let style = impact {
                                UIImpactFeedbackGenerator(style: style).impactOccurred()
                            } else {
                                haptic.selectionChanged()
                            }
                        }
                    }
            )
        }
        .frame(height: detentLabel == nil ? 28 : 46)
        .accessibilityElement()
        .accessibilityLabel(title)
        .accessibilityValue(Text("\(Int(value))"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }
}

// MARK: - Pattern editor

struct PatternEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var draft: FlashPattern
    let isNew: Bool
    let onSave: (FlashPattern) -> Void
    let onDelete: () -> Void
    @State private var error = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(isNew ? "New pattern" : "Edit pattern")
                        .font(.system(size: 22, weight: .semibold))
                        .fontWidth(.expanded)
                        .foregroundStyle(Palette.text)

                    VStack(alignment: .leading, spacing: 8) {
                        label("Name")
                        TextField("Pattern name", text: $draft.name)
                            .textInputAutocapitalization(.sentences)
                            .font(.system(size: 17))
                            .foregroundStyle(Palette.text)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.panel))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
                            .onChange(of: draft.name) { _, _ in error = "" }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            label("Slots")
                            Spacer()
                            lengthButton("minus") { resize(-1) }
                            Text("\(draft.units.count)")
                                .font(.system(size: 15, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Palette.tungsten)
                                .frame(minWidth: 28)
                            lengthButton("plus") { resize(1) }
                        }
                        Text("Tap a slot to turn the light on or off. The pattern repeats from the start.")
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.muted)

                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(draft.units.indices, id: \.self) { i in
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(draft.units[i] ? Palette.tungsten : Color.white.opacity(0.07))
                                    .frame(height: 40)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        draft.units[i].toggle()
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        error = ""
                                    }
                                    .accessibilityElement()
                                    .accessibilityLabel("Slot \(i + 1)")
                                    .accessibilityValue(draft.units[i] ? "On" : "Off")
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                    }

                    VStack(spacing: 12) {
                        HStack {
                            label("Default speed")
                            Spacer()
                            Text("\(Int(draft.defaultSpeed)) per second")
                                .font(.system(size: 15, weight: .medium))
                                .monospacedDigit()
                                .foregroundStyle(Palette.tungsten)
                        }
                        Fader(title: "Default speed", value: $draft.defaultSpeed, range: 1...20, step: 1, impact: .rigid)
                    }

                    if !error.isEmpty {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.40))
                    }

                    VStack(spacing: 10) {
                        Button(action: save) {
                            Text("Save pattern")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 15)
                                .foregroundStyle(Palette.ink)
                                .background(Capsule().fill(Palette.tungsten))
                        }
                        .buttonStyle(.plain)

                        Button { dismiss() } label: {
                            Text("Cancel")
                                .font(.system(size: 16, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .foregroundStyle(Palette.text)
                        }
                        .buttonStyle(.plain)

                        if !isNew {
                            Button {
                                onDelete()
                                dismiss()
                            } label: {
                                Text("Delete pattern")
                                    .font(.system(size: 16, weight: .medium))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.40))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Palette.text)
    }

    private func lengthButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
                .frame(width: 32, height: 32)
                .background(Circle().fill(Color.white.opacity(0.09)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(symbol == "plus" ? "Add slot" : "Remove slot")
    }

    private func resize(_ delta: Int) {
        let n = draft.units.count + delta
        guard (4...32).contains(n) else { return }
        if delta > 0 { draft.units.append(false) } else { draft.units.removeLast() }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func save() {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            error = "Give your pattern a name."
            return
        }
        if !draft.units.contains(true) {
            error = "Turn on at least one slot."
            return
        }
        draft.name = trimmed
        onSave(draft)
        dismiss()
    }
}

// MARK: - Main screen

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var durationSec = 30.0
    @State private var power = 100.0
    @State private var speed = 8.0
    @State private var patternID = "strobe"
    @State private var editing: FlashPattern?

    @AppStorage("customPatterns") private var customData = Data()

    @State private var endDate: Date?
    @State private var total: TimeInterval = 30
    @State private var now = Date()
    @State private var strobe = Strobe()

    private let ticker = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    private var isRunning: Bool { endDate != nil }

    private var remaining: TimeInterval {
        max(0, (endDate ?? now).timeIntervalSince(now))
    }

    private var progress: Double {
        isRunning ? min(1, remaining / max(total, 1)) : 1
    }

    private var customPatterns: [FlashPattern] {
        (try? JSONDecoder().decode([FlashPattern].self, from: customData)) ?? []
    }

    private var allPatterns: [FlashPattern] {
        FlashPattern.builtIns + customPatterns
    }

    private var pattern: FlashPattern {
        allPatterns.first { $0.id == patternID } ?? FlashPattern.builtIns[0]
    }

    var body: some View {
        ZStack {
            Palette.ink.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.top, 8)

                Spacer(minLength: 12)

                lens

                Spacer(minLength: 12)

                ScrollView(showsIndicators: false) {
                    controls
                }

                Text("Rapid flashing can trigger seizures in people with photosensitive epilepsy.")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                    .padding(.horizontal, 12)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .onReceive(ticker) { date in
            now = date
            if let end = endDate, date >= end {
                stop()
            }
        }
        .onChange(of: power) { _, p in
            strobe.setPower(Float(p / 100))
        }
        .onChange(of: speed) { _, s in
            strobe.setSpeed(s)
        }
        .onChange(of: patternID) { _, _ in
            strobe.setPattern(pattern.units)
        }
        .onChange(of: customData) { _, _ in
            strobe.setPattern(pattern.units)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && isRunning { stop() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .sheet(item: $editing) { p in
            PatternEditor(
                draft: p,
                isNew: !customPatterns.contains { $0.id == p.id },
                onSave: { saved in savePattern(saved) },
                onDelete: { deletePattern(p) }
            )
            .presentationDetents([.large])
            .presentationBackground(Palette.ink)
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack {
            Text("Strobe")
                .font(.system(size: 20, weight: .semibold))
                .fontWidth(.expanded)
                .foregroundStyle(Palette.text)
            Spacer()
            HStack(spacing: 7) {
                Circle()
                    .fill(isRunning ? Palette.tungsten : Palette.muted.opacity(0.6))
                    .frame(width: 7, height: 7)
                Text(isRunning ? "Live" : "Ready")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isRunning ? Palette.tungsten : Palette.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Palette.panel))
            .overlay(Capsule().stroke(Palette.hairline, lineWidth: 1))
        }
    }

    private var lens: some View {
        Button(action: toggle) {
            ZStack {
                // Steady glow at the chosen power. It never flashes with the torch.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Palette.tungsten.opacity(isRunning ? 0.10 + 0.50 * power / 100 : 0.0), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 130
                        )
                    )
                    .padding(16)
                    .animation(.easeOut(duration: 0.35), value: isRunning)

                Circle()
                    .stroke(Color.white.opacity(0.07), lineWidth: 10)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Palette.tungsten, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .opacity(isRunning ? 1 : 0.28)
                    .animation(.linear(duration: 0.1), value: progress)

                VStack(spacing: 6) {
                    Text(format(isRunning ? remaining : durationSec))
                        .font(.system(size: 60, weight: .thin))
                        .monospacedDigit()
                        .foregroundStyle(Palette.text)
                        .contentTransition(.numericText())
                    Text(isRunning ? "Tap to stop" : "Tap to start")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isRunning ? Palette.tungsten : Palette.muted)
                }
            }
            .frame(width: 236, height: 236)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isRunning ? "Stop flashing" : "Start flashing")
    }

    private var controls: some View {
        VStack(spacing: 0) {
            // Duration
            VStack(spacing: 12) {
                row(title: "Duration", value: format(durationSec))
                Fader(title: "Duration in seconds", value: $durationSec, range: 1...30, step: 1, impact: .rigid)
                HStack(spacing: 8) {
                    ForEach([5.0, 10.0, 20.0, 30.0], id: \.self) { s in
                        Button { durationSec = s } label: {
                            Text(chipLabel(s))
                                .font(.system(size: 13, weight: .medium))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .foregroundStyle(durationSec == s ? Palette.ink : Palette.text)
                                .background(Capsule().fill(durationSec == s ? Palette.tungsten : Color.white.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
            .disabled(isRunning)
            .opacity(isRunning ? 0.35 : 1)

            divider

            // Power (live)
            VStack(spacing: 12) {
                row(title: "Power", value: "\(Int(power))%")
                Fader(title: "Torch power", value: $power, range: 5...100, step: 1, impact: .rigid)
            }
            .padding(16)

            divider

            // Speed (live, with a magnetic stop at the pattern's default)
            VStack(spacing: 12) {
                row(title: "Speed", value: "\(Int(speed)) per second")
                Fader(
                    title: "Flashes per second",
                    value: $speed,
                    range: 1...20,
                    step: 1,
                    impact: .rigid,
                    detent: pattern.defaultSpeed,
                    snap: 1,
                    detentLabel: "Default"
                )
            }
            .padding(16)

            divider

            // Pattern (live)
            VStack(spacing: 12) {
                row(title: "Pattern", value: pattern.name)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(allPatterns) { p in
                            if p.isCustom {
                                chip(for: p)
                                    .contextMenu {
                                        Button("Edit") { editing = p }
                                        Button("Delete", role: .destructive) { deletePattern(p) }
                                    }
                            } else {
                                chip(for: p)
                            }
                        }
                        newChip
                    }
                }
                if !customPatterns.isEmpty {
                    Text("Touch and hold one of your patterns to edit or delete it.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Palette.panel))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Palette.hairline, lineWidth: 1))
        .animation(.easeOut(duration: 0.2), value: isRunning)
    }

    private func chip(for p: FlashPattern) -> some View {
        let selected = p.id == patternID
        return Button { select(p) } label: {
            VStack(spacing: 6) {
                PatternGlyph(units: p.units)
                    .frame(width: 64, height: 14)
                Text(p.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .foregroundStyle(selected ? Palette.ink : Palette.text)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Palette.tungsten : Color.white.opacity(0.07))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(p.name) pattern")
    }

    private var newChip: some View {
        Button { editing = newPattern() } label: {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 64, height: 14)
                Text("New")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .foregroundStyle(Palette.text)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Palette.muted.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Create a new pattern")
    }

    private var divider: some View {
        Rectangle().fill(Palette.hairline).frame(height: 1).padding(.horizontal, 16)
    }

    private func row(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Palette.text)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Palette.tungsten)
        }
    }

    // MARK: Actions

    private func select(_ p: FlashPattern) {
        guard p.id != patternID else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        patternID = p.id
        speed = p.defaultSpeed
    }

    private func newPattern() -> FlashPattern {
        FlashPattern(
            id: UUID().uuidString,
            name: "Custom \(customPatterns.count + 1)",
            units: [true, false, true, false, false, false, false, false],
            defaultSpeed: 8,
            isCustom: true
        )
    }

    private func saveCustoms(_ list: [FlashPattern]) {
        customData = (try? JSONEncoder().encode(list)) ?? Data()
    }

    private func savePattern(_ p: FlashPattern) {
        var list = customPatterns
        let isNew: Bool
        if let i = list.firstIndex(where: { $0.id == p.id }) {
            list[i] = p
            isNew = false
        } else {
            list.append(p)
            isNew = true
        }
        saveCustoms(list)
        patternID = p.id
        if isNew { speed = p.defaultSpeed }
    }

    private func deletePattern(_ p: FlashPattern) {
        saveCustoms(customPatterns.filter { $0.id != p.id })
        if patternID == p.id {
            patternID = "strobe"
            speed = FlashPattern.builtIns[0].defaultSpeed
        }
    }

    private func toggle() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        isRunning ? stop() : start()
    }

    private func start() {
        total = durationSec
        now = Date()
        let end = now.addingTimeInterval(total)
        endDate = end
        strobe.start(hz: speed, power: Float(power / 100), pattern: pattern.units, until: end) {
            endDate = nil
        }
    }

    private func stop() {
        strobe.stop()
        endDate = nil
    }

    private func format(_ t: TimeInterval) -> String {
        let s = Int(ceil(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private func chipLabel(_ s: Double) -> String {
        s < 60 ? "\(Int(s))s" : "\(Int(s) / 60)m"
    }
}
