//
//  SetlistInfoView.swift
//  ZappaStream
//

import SwiftUI
import WebKit

// MARK: - Data Model

struct SetlistInfoItem: Identifiable {
    let url: URL
    let showDate: String   // "YYYY MM DD" format — used to auto-scroll to the playing show
    var id: String { url.absoluteString }
}

// MARK: - CSS Generation (layout only, no colour overrides)

private func makeSetlistInfoCSS() -> String {
    // The zappateers FZShows pages use a CSS-float two-column layout:
    //   #title     — page title bar
    //   #float     — float container wrapping #content + #menu
    //     #content — main show listings (floated left, ~70% width)
    //     #menu    — tour navigation sidebar (floated right, ~25% width)
    //   #foot      — footer
    //
    // Strategy: remove the floats so they stack vertically as
    //   #content (main) → #menu (tour nav, now at bottom)
    #if os(macOS)
    let fontSize = "16px"
    #else
    let fontSize = "30px"
    #endif
    let rules: [(String, String)] = [
        // Reasonable reading width and no horizontal overflow
        ("body", "margin:12px 14px 24px 14px!important;padding:0!important;overflow-x:hidden!important;font-family:-apple-system,'Helvetica Neue',sans-serif!important;font-size:\(fontSize)!important;line-height:1.5!important;"),
        // Title and footer have fixed heights that clip content at large font sizes — let them grow
        ("#title", "height:auto!important;min-height:0!important;"),
        ("#foot", "height:auto!important;min-height:0!important;"),
        // Collapse the float container
        ("#float", "overflow:visible!important;width:100%!important;"),
        // Main content: full width, no float
        ("#content", "float:none!important;width:100%!important;margin:0!important;padding:0!important;box-sizing:border-box!important;"),
        // Right menu: full width, no float, separated from content above
        ("#menu", "float:none!important;width:100%!important;margin:20px 0 0 0!important;padding:12px 0 0 0!important;box-sizing:border-box!important;border-top:1px solid rgba(128,128,128,0.3)!important;clear:both!important;"),
        // Images don't overflow the narrow pane
        ("img", "max-width:100%!important;height:auto!important;"),
    ]
    return rules.map { "\($0.0){\($0.1)}" }.joined()
}

// MARK: - Navigation Coordinator

private class SetlistInfoCoordinator: NSObject, WKNavigationDelegate {
    var onLoadFinished: (() -> Void)?
    var loadedURL: URL?
    var scrollToDate: String?
    var lastScrollToTopTrigger: UUID?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Scroll to the currently-playing show after the page loads
        if let date = scrollToDate, !date.isEmpty {
            // Show dates appear at the start of <h4> text, e.g. "1973 11 07 - Venue..."
            // Escape any single quotes in the date string (shouldn't occur, but defensive)
            let safe = date.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function(){
                var h4s = document.querySelectorAll('h4');
                for (var i = 0; i < h4s.length; i++) {
                    if (h4s[i].textContent.indexOf('\(safe)') !== -1) {
                        h4s[i].scrollIntoView({ block: 'start' });
                        break;
                    }
                }
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
        DispatchQueue.main.async { self.onLoadFinished?() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async { self.onLoadFinished?() }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        DispatchQueue.main.async { self.onLoadFinished?() }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Allow initial load and in-pane zappateers navigation; open external links in browser
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           url.host?.contains("zappateers.com") == false {
            decisionHandler(.cancel)
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        } else {
            decisionHandler(.allow)
        }
    }
}

// MARK: - WKWebView Configuration

private func makeWebViewConfig() -> WKWebViewConfiguration {
    let config = WKWebViewConfiguration()

    // Inject viewport meta at document start so WebKit uses mobile layout width
    let viewportJS = """
        var m = document.createElement('meta');
        m.name = 'viewport';
        m.content = 'width=device-width,initial-scale=1';
        document.head.appendChild(m);
        """
    config.userContentController.addUserScript(
        WKUserScript(source: viewportJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    )

    // Inject layout CSS at document end
    let css = makeSetlistInfoCSS()
    let cssJS = "var s=document.createElement('style');s.textContent=`\(css)`;document.head.appendChild(s);"
    config.userContentController.addUserScript(
        WKUserScript(source: cssJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    )

    return config
}

// MARK: - WKWebView Representable

#if os(macOS)
private struct SetlistInfoWebView: NSViewRepresentable {
    let url: URL
    let scrollToDate: String?
    let onLoadFinished: () -> Void
    let scrollToTopTrigger: UUID

    func makeCoordinator() -> SetlistInfoCoordinator { SetlistInfoCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: makeWebViewConfig())
        wv.navigationDelegate = context.coordinator
        wv.setValue(false, forKey: "drawsBackground")
        context.coordinator.onLoadFinished = onLoadFinished
        context.coordinator.scrollToDate = scrollToDate
        context.coordinator.loadedURL = url
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLoadFinished = onLoadFinished
        context.coordinator.scrollToDate = scrollToDate
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            webView.load(URLRequest(url: url))
        }
        if context.coordinator.lastScrollToTopTrigger != scrollToTopTrigger {
            context.coordinator.lastScrollToTopTrigger = scrollToTopTrigger
            webView.evaluateJavaScript("window.scrollTo({ top: 0, behavior: 'smooth' });", completionHandler: nil)
        }
    }
}
#else
private struct SetlistInfoWebView: UIViewRepresentable {
    let url: URL
    let scrollToDate: String?
    let onLoadFinished: () -> Void
    let scrollToTopTrigger: UUID

    func makeCoordinator() -> SetlistInfoCoordinator { SetlistInfoCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView(frame: .zero, configuration: makeWebViewConfig())
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        context.coordinator.onLoadFinished = onLoadFinished
        context.coordinator.scrollToDate = scrollToDate
        context.coordinator.loadedURL = url
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLoadFinished = onLoadFinished
        context.coordinator.scrollToDate = scrollToDate
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            webView.load(URLRequest(url: url))
        }
        if context.coordinator.lastScrollToTopTrigger != scrollToTopTrigger {
            context.coordinator.lastScrollToTopTrigger = scrollToTopTrigger
            webView.evaluateJavaScript("window.scrollTo({ top: 0, behavior: 'smooth' });", completionHandler: nil)
        }
    }
}
#endif

// MARK: - SetlistInfoPaneView

struct SetlistInfoPaneView: View {
    let item: SetlistInfoItem

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var scrollToTopTrigger = UUID()

    var body: some View {
        VStack(spacing: 0) {
            // Header bar
            HStack {
                Text("FZShows")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture {
                scrollToTopTrigger = UUID()
            }

            Divider()

            // Web view with loading overlay
            ZStack {
                SetlistInfoWebView(url: item.url, scrollToDate: item.showDate, onLoadFinished: {
                    withAnimation(.easeIn(duration: 0.2)) { isLoading = false }
                }, scrollToTopTrigger: scrollToTopTrigger)
                .opacity(isLoading ? 0 : 1)

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Open in browser...") {
                    #if os(macOS)
                    NSWorkspace.shared.open(item.url)
                    #else
                    UIApplication.shared.open(item.url)
                    #endif
                }
                .font(.caption)
                .foregroundColor(.accentColor)
            }
            .padding(.vertical, 8)
            .padding(.trailing, 12)
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }
}
