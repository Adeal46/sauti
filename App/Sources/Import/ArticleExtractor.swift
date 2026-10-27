import Foundation
import WebKit

enum ArticleError: LocalizedError {
    case download(String)
    case noArticle

    var errorDescription: String? {
        switch self {
        case .download(let reason): return "Couldn't download the page: \(reason)"
        case .noArticle: return "Couldn't find readable article text on that page."
        }
    }
}

/// Downloads a page once, then runs Mozilla's Readability (the engine behind Firefox's
/// Reader View) in an off-screen web view to pull out the article text.
@MainActor
final class ArticleExtractor: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var loadToken = 0
    private var ruleList: WKContentRuleList?

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    private static let readabilitySource: String = {
        guard let url = Bundle.main.url(forResource: "Readability", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8)
        else { return "" }
        return source
    }()

    private struct Extracted: Decodable {
        let title: String?
        let text: String?
        let error: String?
    }

    func extract(from url: URL) async throws -> (title: String, text: String) {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ArticleError.download(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ArticleError.download("the site answered with error \(http.statusCode)")
        }
        let html = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let baseURL = response.url ?? url

        let webView = await makeWebView()
        self.webView = webView
        defer { self.webView = nil }

        await load(html: html, baseURL: baseURL, in: webView)

        let script = Self.readabilitySource + "\n" + Self.extractionScript
        let raw = try? await webView.evaluateJavaScript(script)
        guard let json = raw as? String,
              let jsonData = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(Extracted.self, from: jsonData),
              let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.count > 120
        else { throw ArticleError.noArticle }

        let title = result.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false ? title! : (baseURL.host ?? "Web article"), text)
    }

    // MARK: Web view

    private func makeWebView() async -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Page scripts stay off; only our own extraction script runs.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        if let rules = await blockingRules() {
            configuration.userContentController.add(rules)
        }
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        webView.navigationDelegate = self
        return webView
    }

    /// Blocks images, fonts, media and stylesheets so the page "loads" almost instantly.
    private func blockingRules() async -> WKContentRuleList? {
        if let ruleList { return ruleList }
        let json = """
        [{"trigger":{"url-filter":".*","resource-type":["image","style-sheet","script","font","media","raw","svg-document","popup"]},"action":{"type":"block"}}]
        """
        let list = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "sauti-reader-blocklist", encodedContentRuleList: json)
        ruleList = list
        return list
    }

    private func load(html: String, baseURL: URL, in webView: WKWebView) async {
        loadToken += 1
        let token = loadToken
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            loadContinuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
            // Don't wait forever on pages that never report "finished".
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.loadToken == token else { return }
                self.finishLoading()
            }
        }
    }

    private func finishLoading() {
        loadContinuation?.resume()
        loadContinuation = nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in self.finishLoading() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoading() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.finishLoading() }
    }

    // MARK: Script

    private static let extractionScript = """
    (function () {
      try {
        var article = null;
        if (typeof Readability === "function") {
          article = new Readability(document.cloneNode(true)).parse();
        }
        var title = (article && article.title) || document.title || "";
        var container = document.createElement("div");
        container.innerHTML = (article && article.content) ? article.content : (document.body ? document.body.innerHTML : "");
        var selector = "p, h1, h2, h3, h4, h5, h6, li, blockquote, pre";
        var blocks = container.querySelectorAll(selector);
        var parts = [];
        for (var i = 0; i < blocks.length; i++) {
          var block = blocks[i];
          if (block.parentElement && block.parentElement.closest(selector)) { continue; }
          var text = (block.textContent || "").replace(/\\s+/g, " ").trim();
          if (text.length) { parts.push(text); }
        }
        if (parts.length === 0) {
          parts = (container.textContent || "").split(/\\n+/)
            .map(function (s) { return s.replace(/\\s+/g, " ").trim(); })
            .filter(function (s) { return s.length > 0; });
        }
        return JSON.stringify({ title: title, text: parts.join("\\n") });
      } catch (e) {
        return JSON.stringify({ error: String(e) });
      }
    })();
    """
}
