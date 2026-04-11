import SwiftUI
import WebKit

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Help")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 24, height: 24)
                        .background(Theme.bgTertiary)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Theme.bgSecondary)

            HelpWebView()
        }
        .background(Theme.bgPrimary)
        .preferredColorScheme(.dark)
    }
}

struct HelpWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let fileName = lang == "ja" ? "help_ja" : "help_en"
        if let url = Bundle.main.url(forResource: fileName, withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
