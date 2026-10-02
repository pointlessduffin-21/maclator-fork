// Paper, the house design system (pointlessduffin-21/paper-design), carried over to SwiftUI.
// Tokens are the kit's paper.css values; components follow paper.css / tool.css: paper ground,
// ink type, one vermilion accent, Instrument Serif for titles, Inter for text, JetBrains Mono
// for small uppercase labels only. Light only.

import SwiftUI

enum Paper {
    static let paper = Color(hex: 0xF5F2EB)
    static let paperHi = Color(hex: 0xFAF8F3)
    static let paperLo = Color(hex: 0xEBE6DB)
    static let ink = Color(hex: 0x1C1B18)
    static let ink2 = Color(hex: 0x4F4B43)
    static let ink3 = Color(hex: 0x8A857A)
    static let line = Color(hex: 0x1C1B18, opacity: 0.12)
    static let line2 = Color(hex: 0x1C1B18, opacity: 0.22)
    static let accent = Color(hex: 0xD2462F)
    static let ok = Color(hex: 0x3D7A57)
    static let warn = Color(hex: 0xC68A17)
    static let err = Color(hex: 0xD2462F)
    static let down = Color(hex: 0xB5AFA3)

    static let radius: CGFloat = 18
    static let radiusSmall: CGFloat = 12
    /// cubic-bezier(.2, .7, .2, 1)
    static let ease = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.25)

    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        .custom(italic ? "InstrumentSerif-Italic" : "InstrumentSerif-Regular", size: size)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Inter", size: size).weight(weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("JetBrains Mono", size: size).weight(weight)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

// MARK: - Type

/// `.eyebrow`: a 22px hairline, then a mono uppercase label.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(Paper.ink3).frame(width: 22, height: 1)
            MonoLabel(text, size: 11.5, tracking: 0.14)
        }
    }
}

/// Small uppercase mono label (`.label`, `.pane__title`, `.kpi__label`).
struct MonoLabel: View {
    let text: String
    var size: CGFloat = 10.5
    var tracking: CGFloat = 0.12
    var color: Color = Paper.ink3
    init(_ text: String, size: CGFloat = 10.5, tracking: CGFloat = 0.12, color: Color = Paper.ink3) {
        self.text = text; self.size = size; self.tracking = tracking; self.color = color
    }
    var body: some View {
        Text(text.uppercased())
            .font(Paper.mono(size, .medium))
            .tracking(size * tracking)
            .foregroundStyle(color)
    }
}

/// A serif title with at most one accent phrase in italic vermilion: `Title("App", em: "library")`.
struct Title: View {
    let before: String
    let em: String
    var after: String = ""
    var size: CGFloat = 40
    var body: some View {
        (Text(before).font(Paper.serif(size))
            + Text(em).font(Paper.serif(size, italic: true)).foregroundColor(Paper.accent)
            + Text(after).font(Paper.serif(size)))
            .foregroundStyle(Paper.ink)
            .tracking(-size * 0.015)
            .lineSpacing(0)
    }
}

// MARK: - Status

enum Health {
    case ok, warn, err, down, live
    var color: Color {
        switch self {
        case .ok, .live: Paper.ok
        case .warn: Paper.warn
        case .err: Paper.err
        case .down: Paper.down
        }
    }
}

/// `.dot`: a 7px status dot. `.live` pulses (and stops when Reduce Motion is on).
struct StatusDot: View {
    let health: Health
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    var body: some View {
        Circle()
            .fill(health.color)
            .frame(width: 7, height: 7)
            .background(
                Circle()
                    .stroke(Paper.ok.opacity(pulse ? 0 : 0.45), lineWidth: pulse ? 7 : 0)
                    .frame(width: 7, height: 7)
                    .opacity(health == .live ? 1 : 0)
            )
            .onAppear {
                guard health == .live, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 2.4).repeatForever(autoreverses: false)) { pulse = true }
            }
    }
}

/// Status is a dot plus words, never colour alone.
struct StatusLine: View {
    let health: Health
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            StatusDot(health: health)
            Text(text).font(Paper.sans(13)).foregroundStyle(Paper.ink2)
        }
        .accessibilityElement(children: .combine)
    }
}

/// `.chip`: a mono pill on translucent paper.
struct Chip: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Paper.mono(11))
            .tracking(0.44)
            .foregroundStyle(Paper.ink2)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Paper.paperHi.opacity(0.6)))
            .overlay(Capsule().stroke(Paper.line2, lineWidth: 1))
    }
}

// MARK: - Surfaces

/// `.pane`: translucent paper, a hairline, 18px radius; optional mono title row.
struct Pane<Content: View, Accessory: View>: View {
    var title: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let title {
                HStack {
                    MonoLabel(title)
                    Spacer()
                    accessory()
                }
            }
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Paper.radius).fill(Paper.paperHi.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: Paper.radius).stroke(Paper.line, lineWidth: 1))
    }
}

extension Pane where Accessory == EmptyView {
    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.accessory = { EmptyView() }
        self.content = content
    }
}

/// `.kpi`: a mono label and one serif number.
struct KPI: View {
    let label: String
    let value: String
    var note: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MonoLabel(label, size: 10)
            Text(value).font(Paper.serif(34)).foregroundStyle(Paper.ink).lineLimit(1).minimumScaleFactor(0.6)
            if let note { Text(note).font(Paper.mono(11)).foregroundStyle(Paper.ink3) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Buttons

/// `.btn`: an outlined pill that fills with ink on hover; `.ink` is the solid primary,
/// `.danger` the vermilion outline; `small` is the mono `.btn--sm`.
struct PaperButtonStyle: ButtonStyle {
    enum Kind { case outline, ink, danger }
    var kind: Kind = .outline
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, kind: kind, small: small)
    }

    private struct Inner: View {
        let configuration: Configuration
        let kind: Kind
        let small: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .lineLimit(1)
                .fixedSize() // a button label never wraps
                .font(small ? Paper.mono(11, .medium) : Paper.sans(15, .medium))
                .tracking(small ? 0.66 : 0)
                .foregroundStyle(foreground)
                .padding(.horizontal, small ? 14 : 24)
                .frame(minHeight: small ? 32 : 44)
                .background(Capsule().fill(background))
                .overlay(Capsule().stroke(border, lineWidth: 1))
                .contentShape(Capsule())
                .opacity(enabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(Paper.ease, value: hover)
                .onHover { hover = $0 }
        }

        private var background: Color {
            switch kind {
            case .ink: hover ? .black : Paper.ink
            case .danger: hover ? Paper.err : .clear
            case .outline: hover && !small ? Paper.ink : .clear
            }
        }
        private var foreground: Color {
            switch kind {
            case .ink: Paper.paper
            case .danger: hover ? Paper.paper : Paper.err
            case .outline: hover && !small ? Paper.paper : Paper.ink
            }
        }
        private var border: Color {
            switch kind {
            case .ink: Paper.ink
            case .danger: Paper.err
            case .outline: small ? (hover ? Paper.ink : Paper.line2) : Paper.ink
            }
        }
    }
}

/// A trailing arrow that nudges right on hover, as in `.btn .arrow`.
struct ArrowLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    @State private var hover = false
    var body: some View {
        HStack(spacing: 8) {
            Text(text)
            Text("→").offset(x: hover ? 3 : 0).animation(Paper.ease, value: hover)
        }
        .onHover { hover = $0 }
    }
}

/// `.seg`: a segmented control; the selected segment is ink on paper.
struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    withAnimation(Paper.ease) { selection = value }
                } label: {
                    Text(label.uppercased())
                        .lineLimit(1)
                        .fixedSize()
                        .font(Paper.mono(11))
                        .tracking(0.66)
                        .foregroundStyle(selection == value ? Paper.paper : Paper.ink2)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 30)
                        .background(Capsule().fill(selection == value ? Paper.ink : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Paper.paperHi))
        .overlay(Capsule().stroke(Paper.line2, lineWidth: 1))
    }
}

/// `.input`: paper-hi field, a hairline that turns ink on focus.
struct PaperField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool
    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Paper.ink3))
            .textFieldStyle(.plain)
            .font(Paper.sans(14))
            .foregroundStyle(Paper.ink)
            .focused($focused)
            .padding(.horizontal, 14)
            .frame(minHeight: 36)
            .background(RoundedRectangle(cornerRadius: Paper.radiusSmall).fill(Paper.paperHi))
            .overlay(RoundedRectangle(cornerRadius: Paper.radiusSmall).stroke(focused ? Paper.ink : Paper.line2, lineWidth: 1))
            .shadow(color: Paper.ink.opacity(focused ? 0.08 : 0), radius: 0, x: 0, y: 0)
    }
}

/// A Paper checkbox row: hairline box, ink check, Inter label and a hint.
struct PaperToggle: View {
    let title: String
    let hint: String
    @Binding var isOn: Bool
    var body: some View {
        Button {
            withAnimation(Paper.ease) { isOn.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(isOn ? Paper.ink : Paper.paperHi)
                    .frame(width: 18, height: 18)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(isOn ? Paper.ink : Paper.line2, lineWidth: 1))
                    .overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Paper.paper).opacity(isOn ? 1 : 0))
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Paper.sans(14, .medium)).foregroundStyle(Paper.ink)
                    Text(hint).font(Paper.sans(12.5)).foregroundStyle(Paper.ink3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A 1px hairline (`--line`).
struct Hairline: View {
    var body: some View { Rectangle().fill(Paper.line).frame(height: 1) }
}
