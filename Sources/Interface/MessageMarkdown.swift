import MarkdownUI
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

private typealias AppTheme = AAUV.Theme

struct MessageMarkdown: View, Equatable {
    let text: String
    var citations: [WebCitation] = []
    @State private var citationScope = UUID().uuidString.lowercased()
    @Environment(\.colorScheme) private var scheme

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.text == rhs.text && lhs.citations == rhs.citations }

    var body: some View {
        let document = MarkdownCitations(text: text, citations: citations, scope: citationScope)
        VStack(alignment: .leading, spacing: 8) {
            Markdown(document.content)
                .markdownTheme(Self.theme)
                .markdownImageProvider(MathBlockImageProvider(textColor: AppTheme.Palette.ink,
                                                             fontSize: AppTheme.Fonts.scaled(16)))
                .markdownInlineImageProvider(MathInlineImageProvider(textColor: AppTheme.Palette.ink,
                                                                    fontSize: AppTheme.Fonts.scaled(16), scheme: scheme))
            if !document.sources.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("网页来源").font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.Palette.inkMuted)
                    ForEach(document.sources) { source in
                        Link(destination: source.url) {
                            Text("\(source.id). \(source.title)")
                                .font(.footnote)
                                .foregroundStyle(AppTheme.Palette.accent)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .pendingChatSelectableText()
        .environment(\.openURL, OpenURLAction { url in
            if let destination = document.links[url.absoluteString] { return .systemAction(destination) }
            return Self.allowsExternalURL(url) ? .systemAction : .discarded
        })
    }

    static func allowsExternalURL(_ url: URL) -> Bool { WebCitation.allows(url) }

    private static let theme = MarkdownUI.Theme()
        .text {
            ForegroundColor(AppTheme.Palette.ink)
            FontSize(AppTheme.Fonts.scaled(16))
        }
        .link {
            ForegroundColor(AppTheme.Palette.accent)
        }
        .strong { FontWeight(.semibold) }
        .emphasis { FontStyle(.italic) }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.92))
            BackgroundColor(AppTheme.Palette.surfaceMuted)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(22)
                }
                .markdownMargin(top: 6, bottom: 2)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(19)
                }
                .markdownMargin(top: 6, bottom: 2)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(17)
                }
                .markdownMargin(top: 4, bottom: 2)
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .padding(.vertical, 4)
                .overlay(alignment: .leading) {
                    Rectangle().fill(AppTheme.Palette.hairline).frame(width: 3)
                }
                .markdownTextStyle { ForegroundColor(AppTheme.Palette.inkMuted) }
        }
        .listItem { $0.label.markdownMargin(top: 2, bottom: 2) }
        .paragraph { $0.label.fixedSize(horizontal: false, vertical: true).markdownMargin(top: 0, bottom: 6) }
        .codeBlock { configuration in
            MessageCodeBlock(content: configuration.content, language: configuration.language)
        }
        .table { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: true)
                    .markdownTableBorderStyle(.init(.allBorders, color: AppTheme.Palette.hairline, strokeStyle: .init(lineWidth: 0.5)))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(AppTheme.Palette.surface, AppTheme.Palette.surfaceMuted.opacity(0.5))
                    )
            }
            .markdownMargin(top: 4, bottom: 8)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(15)
                    if configuration.row == 0 { FontWeight(.semibold) }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
}

private struct MessageCodeBlock: View {
    let content: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.flatMap { $0.isEmpty ? nil : $0 } ?? "代码")
                    .font(AppTheme.Fonts.monospaced(size: 11))
                    .foregroundStyle(AppTheme.Palette.inkMuted)
                Spacer(minLength: 8)
                Button("复制") {
                    #if os(iOS)
                    UIPasteboard.general.string = content
                    #else
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    #endif
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .accessibilityLabel("复制代码")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            ScrollView(.horizontal) {
                Text(content)
                    .font(AppTheme.Fonts.monospaced(size: 13.5))
                    .foregroundStyle(AppTheme.Palette.ink)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .background(AppTheme.Palette.surfaceMuted, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(AppTheme.Palette.hairline, lineWidth: 0.5)
        }
        .markdownMargin(top: 4, bottom: 8)
    }
}
