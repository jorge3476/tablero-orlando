import UIKit
import WebKit

/// Muestra el tablero (index.html) y conecta la página con las funciones nativas.
///
/// Cómo se actualiza: la app abre siempre la última copia guardada del tablero
/// (o la que viene dentro de la app la primera vez) y, si hay internet, descarga
/// en segundo plano la versión de GitHub para usarla la próxima vez que se abra.
final class WebViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    static let remoteURL = URL(string: "https://jorge3476.github.io/tablero-orlando/")!
    /// Sitios que se abren dentro de la app. Todo lo demás (Waze, Google Maps…) se abre en su propia app.
    static let insideHosts = ["jorge3476.github.io", "spotify.com"]

    private var web: WKWebView!
    private let radio = RadioPlayer()
    private let obd = OBDManager()
    private let location = LocationBridge()
    private let background = UIColor(red: 11 / 255, green: 13 / 255, blue: 16 / 255, alpha: 1)
    private var lastFallback = Date.distantPast

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = background

        let content = WKUserContentController()
        content.add(WeakScriptHandler(self), name: "native")
        content.addUserScript(WKUserScript(source: Self.bootScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))

        let config = WKWebViewConfiguration()
        config.userContentController = content
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []

        web = WKWebView(frame: view.bounds, configuration: config)
        web.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        web.isOpaque = false
        web.backgroundColor = background
        web.scrollView.backgroundColor = background
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.scrollView.bounces = false
        web.allowsLinkPreview = false
        web.navigationDelegate = self
        web.uiDelegate = self
        if #available(iOS 16.4, *) { web.isInspectable = true }
        view.addSubview(web)

        wireBridges()
        loadDashboard()
        refreshSavedCopy()
    }

    // MARK: - Carga del tablero

    private var savedCopyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.html")
    }

    private func loadDashboard() {
        var html: String?
        if let saved = try? String(contentsOf: savedCopyURL, encoding: .utf8), saved.contains("</html>") {
            html = saved
        } else if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "www") {
            html = try? String(contentsOf: url, encoding: .utf8)
        }
        guard var page = html else { return }

        // La foto del carro va incrustada para que se vea aunque no haya internet.
        if let img = Bundle.main.url(forResource: "orlando-principal", withExtension: "webp", subdirectory: "www/cars"),
           let data = try? Data(contentsOf: img) {
            page = page.replacingOccurrences(of: "src=\"cars/orlando-principal.webp\"",
                                             with: "src=\"data:image/webp;base64,\(data.base64EncodedString())\"")
        }
        // La dirección base es la de GitHub: así los datos guardados y el enlace de Spotify siguen igual.
        web.loadHTMLString(page, baseURL: Self.remoteURL)
    }

    private func refreshSavedCopy() {
        var comps = URLComponents(url: Self.remoteURL.appendingPathComponent("index.html"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
        var request = URLRequest(url: comps.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let target = savedCopyURL
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data, let text = String(data: data, encoding: .utf8),
                  text.contains("Tablero"), text.contains("</html>") else { return }
            try? data.write(to: target, options: .atomic)
        }.resume()
    }

    // MARK: - Puente con la página

    private func js(_ code: String) {
        web.evaluateJavaScript(code, completionHandler: nil)
    }

    private func wireBridges() {
        radio.onEvent = { [weak self] event in
            self?.js("window.__nativeAudioEvent&&window.__nativeAudioEvent('\(event)')")
        }
        radio.onStation = { [weak self] id in
            self?.js("window.__nativeStation&&window.__nativeStation(\(Self.jsString(id)))")
        }
        radio.onStopped = { [weak self] in
            self?.js("window.__nativeRadioStopped&&window.__nativeRadioStopped()")
        }
        obd.onUpdate = { [weak self] json in
            self?.js("window.__obd&&window.__obd(\(json))")
        }
        location.onFix = { [weak self] json in
            self?.js("window.__nativeGeo&&window.__nativeGeo(\(json))")
        }
        location.onDenied = { [weak self] in
            self?.js("window.__nativeGeoErr&&window.__nativeGeoErr(1)")
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let cmd = body["cmd"] as? String else { return }
        switch cmd {
        case "radio.play":
            guard let raw = body["url"] as? String, let url = URL(string: raw) else { return }
            var list: [RadioPlayer.Station] = []
            for item in body["list"] as? [[String: Any]] ?? [] {
                if let id = item["id"] as? String, let name = item["name"] as? String,
                   let u = item["url"] as? String, let su = URL(string: u) {
                    list.append(RadioPlayer.Station(id: id, name: name, url: su))
                }
            }
            radio.play(url: url, title: body["title"] as? String ?? "Radio", list: list, index: body["index"] as? Int ?? 0)
        case "radio.stop":
            radio.stop()
        case "geo.start":
            location.start()
        case "geo.stop":
            location.stop()
        case "obd.start":
            obd.start()
        case "obd.scan":
            obd.scan()
        case "obd.connect":
            if let id = body["id"] as? String { obd.connect(id: id) }
        case "obd.forget":
            obd.forget()
        case "open":
            if let raw = body["url"] as? String, let url = URL(string: raw) { UIApplication.shared.open(url) }
        case "share":
            if let name = body["name"] as? String, let text = body["text"] as? String { share(name: name, text: text) }
        default:
            break
        }
    }

    private func share(name: String, text: String) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            pop.permittedArrowDirections = []
        }
        present(sheet, animated: true)
    }

    // MARK: - Navegación

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if ["about", "data", "blob"].contains(scheme) { decisionHandler(.allow); return }

        if scheme == "http" || scheme == "https" {
            // Cuadros internos (iframes) se permiten.
            if let frame = action.targetFrame, !frame.isMainFrame { decisionHandler(.allow); return }
            let host = url.host?.lowercased() ?? ""
            let inside = Self.insideHosts.contains { host == $0 || host.hasSuffix("." + $0) }
            if inside && action.targetFrame != nil { decisionHandler(.allow); return }
        }
        // Cualquier otro enlace se abre en su app (Waze, Google Maps, Safari…).
        UIApplication.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { UIApplication.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fallBackIfNeeded(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fallBackIfNeeded(error)
    }

    /// Sin internet (por ejemplo al recargar), vuelve a la copia guardada.
    private func fallBackIfNeeded(_ error: Error) {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        guard Date().timeIntervalSince(lastFallback) > 5 else { return }
        lastFallback = Date()
        loadDashboard()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadDashboard()
    }

    // Ventanas de aviso de la página (por si alguna vez se usan).
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancelar", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    // MARK: - Utilidades

    static func jsString(_ s: String) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [s]),
           let text = String(data: data, encoding: .utf8) {
            return String(text.dropFirst().dropLast())
        }
        return "''"
    }

    /// Se ejecuta antes que la página: avisa que está en la app y cambia el GPS de la web por el del iPad.
    static let bootScript = """
    (function(){
      window.NATIVE = true;
      var W = {}, n = 0, last = null;
      function post(o){ try{ window.webkit.messageHandlers.native.postMessage(o); }catch(e){} }
      function toPos(p){ return {coords:{latitude:p.lat, longitude:p.lon, accuracy:p.acc, speed:p.speed, heading:p.heading, altitude:null, altitudeAccuracy:null}, timestamp:p.t}; }
      window.__nativeGeo = function(p){ last = p; var pos = toPos(p); for (var k in W) { try{ W[k].ok(pos); }catch(e){} } };
      window.__nativeGeoErr = function(code){ for (var k in W) { if (W[k].err) { try{ W[k].err({code:code, message:'Sin permiso de ubicación'}); }catch(e){} } } };
      var geo = {
        watchPosition: function(ok, err){ var id = ++n; W[id] = {ok:ok, err:err}; post({cmd:'geo.start'}); if (last) { setTimeout(function(){ try{ ok(toPos(last)); }catch(e){} }, 0); } return id; },
        clearWatch: function(id){ delete W[id]; if (!Object.keys(W).length) post({cmd:'geo.stop'}); },
        getCurrentPosition: function(ok, err){ if (last) { ok(toPos(last)); return; } var id = geo.watchPosition(function(p){ geo.clearWatch(id); ok(p); }, err); }
      };
      try { Object.defineProperty(navigator, 'geolocation', {value: geo, configurable: true}); } catch(e) {}
    })();
    """
}

/// Evita que la página y la app se retengan entre sí en memoria.
final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}
