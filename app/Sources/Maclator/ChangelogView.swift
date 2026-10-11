// The Changelog screen: CHANGELOG.md (bundled by app/build.sh) in the Paper grammar. A small reader
// for the subset the file uses: "## [version] - date" sections, "### " groups, "- " bullets with
// indented continuations and nested bullets, tables, and paragraphs; inline markdown via AttributedString.

import SwiftUI

/// This build's version: MaclatorVersion from Info.plist (app/build.sh writes it from VERSION).
enum AppVersion {
    static var string: String {
        (Bundle.main.object(forInfoDictionaryKey: "MaclatorVersion") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }
    static var build: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "" }
}

struct ChangelogEntry: Identifiable {
    let version: String
    let date: String
    var blocks: [Block] = []
    var id: String { version }

    enum Block {
        case heading(String)
        case paragraph(String)
        case bullets([Bullet])
        case table([[String]])
    }

    struct Bullet {
        var text: String
        var children: [String] = []
    }
}

enum Changelog {
    static func load() -> (intro: String, entries: [ChangelogEntry]) {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return ("", []) }
        return parse(text)
    }

    static func parse(_ text: String) -> (intro: String, entries: [ChangelogEntry]) {
        var intro: [String] = []
        var entries: [ChangelogEntry] = []
        var para: [String] = []
        var bullets: [ChangelogEntry.Bullet] = []
        var table: [[String]] = []

        func flush() {
            if !para.isEmpty {
                let p = para.joined(separator: " ")
                if entries.isEmpty { intro.append(p) } else { entries[entries.count - 1].blocks.append(.paragraph(p)) }
                para = []
            }
            if !bullets.isEmpty, !entries.isEmpty {
                entries[entries.count - 1].blocks.append(.bullets(bullets))
            }
            bullets = []
            if !table.isEmpty, !entries.isEmpty {
                entries[entries.count - 1].blocks.append(.table(table))
            }
            table = []
        }
        /// A table starts: end the paragraph or list before it, keeping the rows gathered so far.
        func flushBeforeTable() {
            if !para.isEmpty || !bullets.isEmpty {
                let t = table
                table = []
                flush()
                table = t
            }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("# ") { continue }
            if raw.hasPrefix("## ") {
                flush()
                // "## [0.1.0-beta.2] - 2026-10-11" or "## Upstream"
                let title = String(raw.dropFirst(3))
                let parts = title.components(separatedBy: " - ")
                let version = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                entries.append(ChangelogEntry(version: version, date: parts.count > 1 ? parts[1] : ""))
                continue
            }
            if raw.hasPrefix("### ") {
                flush()
                entries[entries.count - 1].blocks.append(.heading(String(raw.dropFirst(4))))
                continue
            }
            if line.hasPrefix("[") && line.contains("]: ") { continue } // link reference definitions
            if line.hasPrefix("|") {
                flushBeforeTable()
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if !cells.allSatisfy({ $0.allSatisfy { $0 == "-" || $0 == ":" } }) { table.append(cells) }
                continue
            }
            if raw.hasPrefix("- ") {
                if !para.isEmpty || !table.isEmpty { flush() }
                bullets.append(.init(text: String(raw.dropFirst(2))))
                continue
            }
            if raw.hasPrefix("  - "), !bullets.isEmpty {
                bullets[bullets.count - 1].children.append(String(raw.dropFirst(4)))
                continue
            }
            if raw.hasPrefix("  "), !line.isEmpty, !bullets.isEmpty {
                // continuation of the last bullet (or of its last nested bullet)
                if bullets[bullets.count - 1].children.isEmpty {
                    bullets[bullets.count - 1].text += " " + line
                } else {
                    let n = bullets[bullets.count - 1].children.count
                    bullets[bullets.count - 1].children[n - 1] += " " + line
                }
                continue
            }
            if line.isEmpty { flush(); continue }
            para.append(line)
        }
        flush()
        return (intro.joined(separator: "\n\n"), entries)

    }
}

/// Inline markdown (bold, code, links) in Paper type.
private func md(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

struct ChangelogView: View {
    private let log = Changelog.load()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Eyebrow("Changelog")
                    Title(before: "What's ", em: "new", size: 44)
                    HStack(spacing: 10) {
                        Chip("this app: \(AppVersion.string)")
                        if !AppVersion.build.isEmpty { Chip("build \(AppVersion.build)") }
                    }
                    if !log.intro.isEmpty {
                        Text(md(log.intro)).font(Paper.sans(14)).foregroundStyle(Paper.ink2)
                            .frame(maxWidth: 620, alignment: .leading).tint(Paper.ink)
                    }
                }
                if log.entries.isEmpty {
                    Pane { Text("No changelog in this build.").font(Paper.sans(14)).foregroundStyle(Paper.ink3) }
                }
                ForEach(log.entries) { e in
                    Pane {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(e.version).font(Paper.serif(32))
                                if !e.date.isEmpty { Text(e.date).font(Paper.mono(11)).foregroundStyle(Paper.ink3) }
                                Spacer()
                                if e.version == AppVersion.string { StatusLine(health: .ok, text: "This version") }
                            }
                            ForEach(Array(e.blocks.enumerated()), id: \.offset) { _, b in block(b) }
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 38)
            .padding(.bottom, 30)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(Paper.ink)
    }

    @ViewBuilder
    private func block(_ b: ChangelogEntry.Block) -> some View {
        switch b {
        case .heading(let h):
            MonoLabel(h).padding(.top, 4)
        case .paragraph(let p):
            Text(md(p)).font(Paper.sans(13.5)).foregroundStyle(Paper.ink2).fixedSize(horizontal: false, vertical: true)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    bulletRow(item.text, indent: 0)
                    ForEach(Array(item.children.enumerated()), id: \.offset) { _, c in bulletRow(c, indent: 18) }
                }
            }
        case .table(let rows):
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(row.enumerated()), id: \.offset) { j, cell in
                            Group {
                                if i == 0 {
                                    MonoLabel(cell.isEmpty ? " " : cell, size: 9.5)
                                } else {
                                    Text(md(cell)).font(j == 0 ? Paper.sans(13) : Paper.mono(11.5))
                                        .foregroundStyle(j == 0 ? Paper.ink : Paper.ink2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.vertical, 7)
                    if i < rows.count - 1 { Hairline() }
                }
            }
        }
    }

    private func bulletRow(_ text: String, indent: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(indent > 0 ? Paper.ink3 : Paper.ink2).frame(width: 4, height: 4).offset(y: -3)
            Text(md(text)).font(Paper.sans(13.5)).foregroundStyle(Paper.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, indent)
    }
}
