// The Running screen's inspector: one program under translation in detail. Live output (the
// log maclator keeps per process), CPU and memory over the last minutes, uptime, its processes.
//
// Charts follow the dataviz rules in Paper's palette: one measure per chart (never two y-axes),
// a single ink series so no legend (the title names it), a 2px line over a 10% wash, solid
// hairline grid, an end dot with a paper ring and its value, a crosshair + tooltip on hover,
// and a now/average/peak readout as the text equivalent.

import AppKit
import Charts
import SwiftUI

struct GuestInspector: View {
    @EnvironmentObject var monitor: GuestMonitor
    @EnvironmentObject var launcher: Launcher
    /// The program as it was when opened; `live` is nil once it has ended.
    let snapshot: GuestProcess
    let live: GuestProcess?
    let close: () -> Void
    let openInLibrary: (() -> Void)?
    @StateObject private var log = LogTail()

    private var g: GuestProcess { live ?? snapshot }
    private var samples: [Sample] { monitor.history[snapshot.pid] ?? [] }

    var body: some View {
        ScrollViewReader { outer in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                // Snapshot debug aid (MACLATOR_SNAPSHOT_SCROLL): the output section first.
                if ProcessInfo.processInfo.environment["MACLATOR_SNAPSHOT_SCROLL"] != nil { output }
                HStack(spacing: 12) {
                    Pane {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            KPI(label: "Uptime", value: uptime, note: "since " + g.started.formatted(date: .omitted, time: .shortened))
                        }
                    }
                    Pane { KPI(label: "Processes", value: "\(g.processes)", note: g.processes == 1 ? "no helpers" : "\(g.processes - 1) helpers") }
                    Pane { KPI(label: "Windows", value: "\(g.windows)", note: "on screen") }
                }
                Pane(title: "CPU") {
                    UsageChart(samples: samples, title: "CPU", value: \.cpu, format: { "\(Int($0.rounded()))%" },
                               floor: 100, note: "Percent of one core, all processes together")
                }
                Pane(title: "Memory") {
                    UsageChart(samples: samples, title: "Memory", value: { Double($0.residentBytes) },
                               format: { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .memory) },
                               floor: Double(64 << 20), note: "Resident memory, all processes together")
                }
                if g.members.count > 1 { processes }
                if ProcessInfo.processInfo.environment["MACLATOR_SNAPSHOT_SCROLL"] == nil { output.id("output") }
            }
            .padding(22)
        }
        .onAppear {
            // Snapshot debug aid: show the output section.
            if ProcessInfo.processInfo.environment["MACLATOR_SNAPSHOT_SCROLL"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { outer.scrollTo("output", anchor: .bottom) }
            }
        }
        }
        .background(Paper.paper)
        .onAppear { log.follow(g.members.map(\.pid).isEmpty ? [g.pid] : g.members.map(\.pid)) }
        .onChange(of: g.members.map(\.pid)) { _, pids in if !pids.isEmpty { log.follow(pids) } }
        .onDisappear { log.stop() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: g.icon).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(g.name).font(Paper.serif(28)).lineLimit(1)
                    Text("pid " + String(g.pid)).font(Paper.mono(10.5)).foregroundStyle(Paper.ink3)
                }
                Spacer()
                Button(action: close) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(PaperButtonStyle(small: true))
                    .accessibilityLabel("Close details")
            }
            Text(([g.program] + g.args).joined(separator: " "))
                .font(Paper.mono(10.5)).foregroundStyle(Paper.ink2).textSelection(.enabled)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                StatusLine(health: live == nil ? .down : .live, text: live == nil ? "Ended" : "Running under translation")
                Spacer()
                if let openInLibrary {
                    Button(action: openInLibrary) { Text("Library") }.buttonStyle(PaperButtonStyle(small: true))
                }
                if live != nil {
                    Button { monitor.stop(g) } label: { Text("Stop") }.buttonStyle(PaperButtonStyle(kind: .danger, small: true))
                }
            }
        }
    }

    private var processes: some View {
        Pane(title: "Processes") {
            VStack(spacing: 0) {
                ForEach(g.members) { m in
                    HStack(spacing: 12) {
                        Text(m.role).font(Paper.sans(13, .medium)).lineLimit(1)
                        Text("\(m.pid)").font(Paper.mono(10.5)).foregroundStyle(Paper.ink3)
                        Spacer()
                        Metric(label: "CPU", value: "\(Int(m.cpu.rounded()))%")
                        Metric(label: "Mem", value: ByteCountFormatter.string(fromByteCount: Int64(m.residentBytes), countStyle: .memory), width: 70)
                    }
                    .padding(.vertical, 7)
                    if m.id != g.members.last?.id { Hairline() }
                }
            }
        }
    }

    @State private var filter = ""
    @State private var follow = true

    private var output: some View {
        let multi = Set(log.lines.map(\.pid)).count > 1
        let shown = filter.isEmpty ? log.lines : log.lines.filter { $0.text.localizedCaseInsensitiveContains(filter) }
        return Pane(title: "Output", accessory: {
            HStack(spacing: 6) {
                Button { follow.toggle() } label: { Text(follow ? "Following" : "Paused") }
                    .buttonStyle(PaperButtonStyle(small: true))
                    .accessibilityAddTraits(follow ? .isSelected : [])
                Button { NSWorkspace.shared.activateFileViewerSelecting([LogTail.url(g.pid)]) } label: { Text("Log file") }
                    .buttonStyle(PaperButtonStyle(small: true))
            }
        }) {
            VStack(alignment: .leading, spacing: 10) {
                PaperField(placeholder: "Filter output", text: $filter)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(shown.suffix(800)) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    if multi {
                                        Text("\(line.pid)").font(Paper.mono(9.5)).foregroundStyle(Paper.ink3).frame(width: 44, alignment: .leading)
                                    }
                                    Text(line.text.isEmpty ? " " : line.text)
                                        .font(Paper.mono(10.5))
                                        .foregroundStyle(line.text.hasPrefix("maclator:") ? Paper.err : (line.text.hasPrefix("# maclator") ? Paper.ink3 : Paper.ink2))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .id(line.id)
                            }
                            if shown.isEmpty {
                                Text(emptyText).font(Paper.sans(12.5)).foregroundStyle(Paper.ink3).padding(.vertical, 8)
                            }
                        }
                        .padding(10)
                    }
                    .frame(height: 280)
                    .background(RoundedRectangle(cornerRadius: Paper.radiusSmall).fill(Paper.paperLo.opacity(0.7)))
                    .onChange(of: log.lines.last?.id) { _, id in
                        if follow, let id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    private var emptyText: String {
        if !filter.isEmpty { return "No output matches." }
        if log.missing.contains(g.pid) {
            return "No log for this process: it was started by an older maclator, or with MACLATOR_NO_LOG."
        }
        return "Nothing written to stdout or stderr yet."
    }

    private var uptime: String {
        let t = Int((live == nil ? (samples.last?.time ?? Date()) : Date()).timeIntervalSince(g.started))
        if t >= 3600 { return "\(t / 3600)h \(t % 3600 / 60)m" }
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// One measure over time: a 2px ink line over a 10% wash, hover crosshair with a tooltip,
/// the latest value at the end dot, and a now/average/peak readout below.
struct UsageChart: View {
    let samples: [Sample]
    let title: String
    let value: (Sample) -> Double
    let format: (Double) -> String
    /// The y-axis runs at least this high (100% CPU, 64 MB), so a quiet program doesn't look busy.
    let floor: Double
    let note: String
    @State private var hover: Sample?

    private var peak: Double { samples.map(value).max() ?? 0 }

    /// Top of the y-axis: a round step above the peak (and at least `floor`), so the ticks are
    /// 0, top/2 and top in clean numbers.
    private var top: Double {
        let want = max(floor, peak * 1.15)
        var step = floor
        while step < want { step *= 2 }
        return step
    }
    private var average: Double { samples.isEmpty ? 0 : samples.map(value).reduce(0, +) / Double(samples.count) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if samples.count < 2 {
                Text("Collecting readings…").font(Paper.sans(12.5)).foregroundStyle(Paper.ink3)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                chart.frame(height: 120)
            }
            HStack(spacing: 18) {
                Metric(label: "Now", value: samples.last.map { format(value($0)) } ?? "—", width: 64)
                Metric(label: "Average", value: samples.isEmpty ? "—" : format(average), width: 64)
                Metric(label: "Peak", value: samples.isEmpty ? "—" : format(peak), width: 64)
                Spacer()
                Text(span).font(Paper.mono(10)).foregroundStyle(Paper.ink3)
            }
            Text(note).font(Paper.sans(12)).foregroundStyle(Paper.ink3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): now \(samples.last.map { format(value($0)) } ?? "unknown"), average \(format(average)), peak \(format(peak)), over \(span)")
    }

    private var spanSeconds: Double {
        guard let a = samples.first?.time, let b = samples.last?.time else { return 0 }
        return b.timeIntervalSince(a)
    }

    private var span: String {
        guard !samples.isEmpty else { return "" }
        let s = Int(spanSeconds)
        return s >= 60 ? "last \(s / 60) min" : "last \(s) s"
    }

    private var chart: some View {
        Chart {
            ForEach(samples) { s in
                AreaMark(x: .value("Time", s.time), y: .value(title, value(s)))
                    .foregroundStyle(Paper.ink.opacity(0.10))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.time), y: .value(title, value(s)))
                    .foregroundStyle(Paper.ink)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if let h = hover {
                RuleMark(x: .value("Time", h.time))
                    .foregroundStyle(Paper.line2)
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(format(value(h))).font(Paper.sans(12, .semibold)).foregroundStyle(Paper.ink)
                            Text(h.time.formatted(date: .omitted, time: .standard)).font(Paper.mono(9.5)).foregroundStyle(Paper.ink3)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Paper.paperHi))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Paper.line, lineWidth: 1))
                        .shadow(color: Paper.ink.opacity(0.08), radius: 6, y: 2)
                    }
                dot(h)
            } else if let last = samples.last {
                dot(last)
                    .annotation(position: .topLeading, spacing: 4) {
                        Text(format(value(last))).font(Paper.mono(10)).foregroundStyle(Paper.ink2)
                    }
            }
        }
        .chartYScale(domain: 0...top)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Paper.line)
                AxisValueLabel {
                    if let d = v.as(Date.self) {
                        // Seconds matter over a few minutes; past ten, hours and minutes are enough.
                        Text(spanSeconds < 600 ? d.formatted(.dateTime.minute().second()) : d.formatted(date: .omitted, time: .shortened))
                            .font(Paper.mono(9.5)).foregroundStyle(Paper.ink3)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, top / 2, top]) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(Paper.line)
                AxisValueLabel {
                    if let d = v.as(Double.self) { Text(d == 0 ? "0" : format(d)).font(Paper.mono(9.5)).foregroundStyle(Paper.ink3) }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let p):
                            guard let frame = proxy.plotFrame else { return }
                            let x = p.x - geo[frame].origin.x
                            if let t: Date = proxy.value(atX: x) {
                                hover = samples.min { abs($0.time.timeIntervalSince(t)) < abs($1.time.timeIntervalSince(t)) }
                            }
                        case .ended:
                            hover = nil
                        }
                    }
            }
        }
    }

    /// An 8px ink dot with a 2px paper ring (the ring is a larger paper dot drawn underneath).
    @ChartContentBuilder
    private func dot(_ s: Sample) -> some ChartContent {
        PointMark(x: .value("Time", s.time), y: .value(title, value(s)))
            .symbolSize(144)
            .foregroundStyle(Paper.paperHi)
        PointMark(x: .value("Time", s.time), y: .value(title, value(s)))
            .symbolSize(64)
            .foregroundStyle(Paper.ink)
    }
}
