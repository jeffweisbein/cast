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
                Spacer()
                CopyBlockButton(
                    text: CopyPayload.code(self.code),
                    accessibilityName: "Copy code",
                    revealed: self.hovering)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.4))
            ScrollView(.horizontal, showsIndicators: false) {
                CodeHighlightText(code: self.code, language: self.language)
                    .padding(12)
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
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
