//
//  TrackInfoView.swift
//  ZappaStream
//

import SwiftUI
import WebKit

// MARK: - CSS Generation

private func makeTrackInfoCSS(colorScheme: ColorScheme) -> String {
    let isDark = colorScheme == .dark
    let bgColor     = isDark ? "#1c1c1e" : "#f2f2f7"
    let fgColor     = isDark ? "#e5e5e7" : "#1c1c1e"
    let secondaryFg = isDark ? "#aeaeb2" : "#6e6e73"
    let borderColor = isDark ? "rgba(74,158,255,0.25)" : "rgba(74,158,255,0.35)"
    let quoteColor  = isDark ? "rgba(255,255,255,0.07)" : "rgba(0,0,0,0.05)"
    let quoteBorder = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.2)"
    let tableBorder = isDark ? "rgba(255,255,255,0.12)" : "rgba(0,0,0,0.15)"
    let tableHeader = isDark ? "rgba(74,158,255,0.12)" : "rgba(74,158,255,0.08)"

    // Join on single line — injected via JS template literal which supports multiline,
    // but keeping it flat avoids any edge-case encoding issues.
    let rules: [(String, String)] = [
        ("body", "background-color:\(bgColor)!important;color:\(fgColor)!important;font-family:-apple-system,'Helvetica Neue',sans-serif!important;font-size:13px!important;line-height:1.6!important;margin:12px 16px 24px 16px!important;padding:0!important;"),
        ("p.menu,div#Top,h1", "display:none!important;"),
        ("h2", "color:\(fgColor)!important;font-size:15px!important;font-weight:600!important;margin:0 0 14px 0!important;padding:0!important;"),
        ("h4", "color:#4a9eff!important;font-size:11px!important;font-weight:600!important;text-transform:uppercase!important;letter-spacing:0.07em!important;margin:20px 0 6px 0!important;"),
        ("h5", "color:\(fgColor)!important;font-size:12px!important;font-weight:600!important;margin:12px 0 4px 0!important;"),
        ("div.item", "border-left:2px solid \(borderColor)!important;padding-left:10px!important;margin-bottom:4px!important;"),
        ("ul", "margin:4px 0!important;padding-left:18px!important;"),
        ("li", "margin-bottom:3px!important;"),
        ("a", "color:#4a9eff!important;text-decoration:none!important;"),
        ("a:hover", "text-decoration:underline!important;"),
        ("blockquote", "background-color:\(quoteColor)!important;border-left:3px solid \(quoteBorder)!important;border-radius:0 4px 4px 0!important;margin:8px 0!important;padding:6px 12px!important;font-style:italic!important;color:\(secondaryFg)!important;"),
        ("table", "border-collapse:collapse!important;font-size:11px!important;width:100%!important;margin:8px 0!important;"),
        ("th,td", "border:1px solid \(tableBorder)!important;padding:4px 8px!important;text-align:left!important;"),
        ("th", "background-color:\(tableHeader)!important;font-weight:600!important;"),
        ("address", "display:block!important;font-size:10px!important;color:\(secondaryFg)!important;font-style:normal!important;margin-top:20px!important;padding-top:8px!important;border-top:1px solid \(tableBorder)!important;"),
    ]
    return rules.map { "\($0.0){\($0.1)}" }.joined()
}

// MARK: - WKWebView Coordinator

private class TrackInfoCoordinator: NSObject, WKNavigationDelegate {
    var onLoadFinished: (() -> Void)?
    var loadedURL: URL?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
        // Allow the initial page load and donlope.net in-page navigation; open anything else externally
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url,
           url.host?.contains("donlope.net") == false {
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

// MARK: - WKWebView Representable

#if os(macOS)
private struct TrackInfoWebView: NSViewRepresentable {
    let url: URL
    let colorScheme: ColorScheme
    let onLoadFinished: () -> Void

    func makeCoordinator() -> TrackInfoCoordinator { TrackInfoCoordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let css = makeTrackInfoCSS(colorScheme: colorScheme)
        let js = "var s=document.createElement('style');s.textContent=`\(css)`;document.head.appendChild(s);"
        let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.setValue(false, forKey: "drawsBackground")
        context.coordinator.onLoadFinished = onLoadFinished
        context.coordinator.loadedURL = url
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLoadFinished = onLoadFinished
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            webView.load(URLRequest(url: url))
        }
    }
}
#else
private struct TrackInfoWebView: UIViewRepresentable {
    let url: URL
    let colorScheme: ColorScheme
    let onLoadFinished: () -> Void

    func makeCoordinator() -> TrackInfoCoordinator { TrackInfoCoordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let css = makeTrackInfoCSS(colorScheme: colorScheme)
        let js = "var s=document.createElement('style');s.textContent=`\(css)`;document.head.appendChild(s);"
        let script = WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        context.coordinator.onLoadFinished = onLoadFinished
        context.coordinator.loadedURL = url
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLoadFinished = onLoadFinished
        if context.coordinator.loadedURL != url {
            context.coordinator.loadedURL = url
            webView.load(URLRequest(url: url))
        }
    }
}
#endif

// MARK: - TrackInfoView

struct TrackInfoView: View {
    let trackName: String
    let openURL: (URL) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var lookupResult: DonlopeLookupResult? = nil
    @State private var isLoading: Bool = true

    private let indexPageURL = URL(string: "https://www.donlope.net/fz/songs/index.html")!

    var body: some View {
        Group {
            switch lookupResult {
            case .none:
                lookingUpView
            case .found(let url):
                webContentView(url: url)
            case .noMatch(let attempted):
                noMatchView(attempted: attempted)
            case .fetchError:
                errorView
            }
        }
        .task(id: trackName) {
            isLoading = true
            lookupResult = nil
            lookupResult = await DonlopeIndexCache.shared.lookupURL(for: trackName)
        }
    }

    // MARK: - Subviews

    private var lookingUpView: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Looking up \"\(trackName)\"…")
                .scaledFont(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func webContentView(url: URL) -> some View {
        ZStack {
            TrackInfoWebView(url: url, colorScheme: colorScheme) {
                withAnimation(.easeIn(duration: 0.2)) { isLoading = false }
            }
            .opacity(isLoading ? 0 : 1)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func noMatchView(attempted: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("No info found for\n\"\(attempted)\"")
                .scaledFont(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button(action: { openURL(indexPageURL) }) {
                Text("Open Song Index →")
                    .scaledFont(.caption)
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 28))
                .foregroundColor(.secondary)
            Text("Couldn't load song index")
                .scaledFont(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
