import HighlightSwift
import SwiftUI

/// Code block chrome: language header, copy button (hover-revealed on macOS, always
/// visible on iOS), horizontally scrolling monospace body.
struct CodeBlockView: View {
    let language: String?
    let code: String
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(self.language ?? "code")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                if ["diff", "patch"].contains(self.language?.lowercased() ?? "") {
                    let summary = DiffSummary(self.code)
                    Text("+\(summary.additions)").foregroundStyle(.green)
                    Text("−\(summary.deletions)").foregroundStyle(.red)
                }
                Spacer()
                CopyBlockButton(
                    text: CopyPayload.code(self.code),
                    accessibilityName: "Copy code",
                    revealed: self.hovering)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4))
            if ["diff", "patch"].contains(self.language?.lowercased() ?? "") {
                let summary = DiffSummary(self.code)
                if !summary.files.isEmpty {
                    DisclosureGroup("\(summary.files.count) \(summary.files.count == 1 ? "file" : "files") in this diff") {
                        ForEach(summary.files, id: \.self) { path in
                            Label(path, systemImage: "doc.text")
                                .font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.font(.caption).padding(10)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Group {
                    if ["diff", "patch"].contains(self.language?.lowercased() ?? "") {
                        DiffText(code: self.code)
                    } else { CodeHighlightText(code: self.code, language: self.language) }
                }.padding(12)
            }
        }
        .background(.quaternary.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        #if os(macOS)
        .onHover { self.hovering = $0 }
        #endif
    }
}

/// Offline syntax highlighting (HighlightSwift → bundled highlight.js, no network).
/// The fence's language tag drives highlighting; unknown tags fall back to plain
/// monospace because a failed highlight leaves the raw attributed text in place.
struct CodeHighlightText: View {
    let code: String
    let language: String?

    private var mode: HighlightMode {
        guard let language = self.language?.trimmingCharacters(in: .whitespaces).lowercased(),
              !language.isEmpty else { return .automatic }
        return .languageAliasIgnoreIllegal(language)
    }

    var body: some View {
        CodeText(self.code)
            .highlightMode(self.mode)
            .codeTextColors(.theme(.xcode))
            .font(.system(size: 13))
            .lineSpacing(2.5)
            .fixedSize(horizontal: true, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Keep every diff line visible, with semantic +/- cues as well as color.
private struct DiffText: View {
    let code: String
    var body: some View {
        Text(attributedCode)
            .font(.system(size: 13, design: .monospaced))
            .lineSpacing(3)
            .fixedSize(horizontal: true, vertical: true)
            .textSelection(.enabled)
    }
    private var attributedCode: AttributedString {
        var result = AttributedString()
        let lines = code.components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            var text = AttributedString(line + (index < lines.count - 1 ? "\n" : ""))
            if line.hasPrefix("+++") || line.hasPrefix("---") { text.foregroundColor = .secondary }
            else if line.hasPrefix("+") { text.foregroundColor = .green }
            else if line.hasPrefix("-") { text.foregroundColor = .red }
            else if line.hasPrefix("@@") { text.foregroundColor = .accentColor }
            result += text
        }
        return result
    }
}
