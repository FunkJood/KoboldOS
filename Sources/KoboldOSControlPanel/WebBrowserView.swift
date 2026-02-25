import SwiftUI
import WebKit
import AppKit

// MARK: - Browser Tab Model

final class BrowserTab: ObservableObject, Identifiable, @unchecked Sendable {
    let id = UUID()
    @Published var title: String = "Neuer Tab"
    @Published var urlString: String = ""
    @Published var isLoading: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false

    var webView: WKWebView?

    func ensureWebView() {
        guard webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.websiteDataStore = WKWebsiteDataStore.default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        webView = WKWebView(frame: .zero, configuration: config)
    }

    func navigate(to urlString: String) {
        ensureWebView()
        var urlStr = urlString
        if !urlStr.contains("://") {
            if urlStr.contains(".") && !urlStr.contains(" ") {
                urlStr = "https://\(urlStr)"
            } else {
                let encoded = urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlStr
                urlStr = "https://www.google.com/search?q=\(encoded)"
            }
        }
        guard let url = URL(string: urlStr) else { return }
        webView?.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
}

// MARK: - Shared Browser Manager (Singleton für Agent-Zugriff)

@MainActor
final class SharedBrowserManager: ObservableObject {
    static let shared = SharedBrowserManager()

    @Published var tabs: [BrowserTab] = []
    @Published var activeTabId: UUID?

    /// Serialisiert Browser-Aktionen um Crashes bei parallelen JS-Aufrufen zu vermeiden
    private var actionQueue: [() -> Void] = []
    private var isProcessingAction = false

    var activeTab: BrowserTab? {
        tabs.first { $0.id == activeTabId }
    }

    func newTab(url: String = "") -> UUID {
        let tab = BrowserTab()
        tabs.append(tab)
        activeTabId = tab.id
        if !url.isEmpty {
            tab.navigate(to: url)
        }
        return tab.id
    }

    func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if activeTabId == id {
            activeTabId = tabs.last?.id
        }
    }

    func tab(for id: UUID?) -> BrowserTab? {
        if let id = id {
            return tabs.first { $0.id == id }
        }
        return activeTab
    }

    /// Navigiert zu URL im aktiven oder spezifischen Tab
    func navigate(url: String, tabId: UUID? = nil) -> [String: String] {
        let tab: BrowserTab
        if let existing = self.tab(for: tabId) {
            tab = existing
        } else {
            // Neuen Tab anlegen falls keiner existiert
            let newId = newTab(url: url)
            return ["tab_id": newId.uuidString, "url": url, "status": "navigating"]
        }
        tab.navigate(to: url)
        return ["tab_id": tab.id.uuidString, "url": url, "status": "navigating"]
    }

    /// Wartet bis der aktive Tab fertig geladen hat (max timeout Sekunden)
    func waitForLoad(tabId: UUID? = nil, timeout: TimeInterval = 10) async -> Bool {
        guard let tab = self.tab(for: tabId) else { return false }
        let start = Date()
        while tab.isLoading && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
        }
        // Kurze Pause damit JS fertig rendern kann
        try? await Task.sleep(nanoseconds: 300_000_000)
        return !tab.isLoading
    }

    /// Ko-Nutzung: Letzte User-Aktion Timestamp (Agent wartet 1s nach User-Aktion)
    var lastUserAction: Date = .distantPast

    func recordUserAction() {
        lastUserAction = Date()
    }

    /// Agent sollte kurz warten wenn User gerade aktiv ist
    func waitForUserIdle() async {
        while Date().timeIntervalSince(lastUserAction) < 1.0 {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    /// Liest Seitentext + interaktive Elemente via JavaScript
    /// Enthält detaillierte Formular-Informationen für mehrstufige Logins
    func readPage(tabId: UUID? = nil, completion: @escaping @Sendable (String) -> Void) {
        guard let tab = self.tab(for: tabId) else {
            completion("[Kein Browser-Tab aktiv]")
            return
        }
        guard let wv = tab.webView else {
            completion("[WebView nicht bereit — Tab existiert aber WebView fehlt]")
            return
        }
        let js = """
        (() => {
            const text = document.body.innerText.substring(0, 3000);
            const url = location.href;
            const title = document.title;
            const elements = [];
            const forms = [];

            // Alle Formulare mit ihren Feldern sammeln
            document.querySelectorAll('form').forEach((form, fi) => {
                if (fi >= 10) return;
                const fields = [];
                form.querySelectorAll('input, select, textarea, button').forEach(el => {
                    const tag = el.tagName.toLowerCase();
                    const type = el.type || '';
                    const name = el.name || '';
                    const id = el.id || '';
                    const placeholder = el.placeholder || '';
                    const value = (type === 'password') ? '***' : (el.value || '').substring(0, 30);
                    const required = el.required;
                    let sel = id ? '#' + id : (name ? tag + '[name="' + name + '"]' : '');
                    if (!sel && el.className && typeof el.className === 'string') {
                        sel = tag + '.' + el.className.trim().split(/\\s+/).slice(0,2).join('.');
                    }
                    fields.push({tag, type, name, id, placeholder, value, required, selector: sel});
                });
                const action = form.action || '';
                const method = form.method || 'get';
                forms.push({index: fi+1, action: action.substring(0,80), method, fields});
            });

            // Interaktive Elemente
            document.querySelectorAll('a, button, input, select, textarea, [role=button], [onclick]').forEach((el, i) => {
                if (i >= 50) return;
                const tag = el.tagName.toLowerCase();
                const type = el.type || '';
                const txt = (el.innerText || el.value || el.placeholder || el.alt || el.title || el.ariaLabel || '').substring(0, 60).trim();
                if (!txt && tag !== 'input') return;
                let sel = '';
                if (el.id) sel = '#' + el.id;
                else if (el.name) sel = tag + '[name="' + el.name + '"]';
                else if (el.className && typeof el.className === 'string') {
                    const cls = el.className.trim().split(/\\s+/).slice(0,2).join('.');
                    if (cls) sel = tag + '.' + cls;
                }
                if (!sel) sel = tag + ':nth-of-type(' + (Array.from(el.parentElement.querySelectorAll(tag)).indexOf(el)+1) + ')';
                const r = el.getBoundingClientRect();
                if (r.width === 0 && r.height === 0) return;
                elements.push({tag, type, text: txt, selector: sel, x: Math.round(r.x + r.width/2), y: Math.round(r.y + r.height/2)});
            });
            return JSON.stringify({text, url, title, elements, forms});
        })()
        """
        wv.evaluateJavaScript(js) { result, error in
            if let json = result as? String, let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let pageText = obj["text"] as? String ?? ""
                let pageUrl = obj["url"] as? String ?? ""
                let pageTitle = obj["title"] as? String ?? ""
                var output = "=== Seite: \(pageTitle) ===\nURL: \(pageUrl)\n\n\(pageText)\n"

                // Formular-Details
                if let formsList = obj["forms"] as? [[String: Any]], !formsList.isEmpty {
                    output += "\n=== Formulare ===\n"
                    for form in formsList {
                        let idx = form["index"] as? Int ?? 0
                        let method = form["method"] as? String ?? ""
                        output += "Formular \(idx) (\(method.uppercased())):\n"
                        if let fields = form["fields"] as? [[String: Any]] {
                            for field in fields {
                                let tag = field["tag"] as? String ?? ""
                                let type = field["type"] as? String ?? ""
                                let name = field["name"] as? String ?? ""
                                let placeholder = field["placeholder"] as? String ?? ""
                                let sel = field["selector"] as? String ?? ""
                                let required = field["required"] as? Bool ?? false
                                let reqStr = required ? " (PFLICHT)" : ""
                                let desc = !placeholder.isEmpty ? placeholder : (!name.isEmpty ? name : type)
                                output += "  \(tag)[\(type)] \"\(desc)\"\(reqStr) → selector: \(sel)\n"
                            }
                        }
                    }
                }

                if let elements = obj["elements"] as? [[String: Any]], !elements.isEmpty {
                    output += "\n=== Interaktive Elemente ===\n"
                    for el in elements {
                        let tag = el["tag"] as? String ?? ""
                        let type = el["type"] as? String ?? ""
                        let text = el["text"] as? String ?? ""
                        let sel = el["selector"] as? String ?? ""
                        let x = el["x"] as? Int ?? 0
                        let y = el["y"] as? Int ?? 0
                        let typeStr = type.isEmpty ? tag : "\(tag)[\(type)]"
                        output += "  [\(typeStr)] \"\(text)\" → selector: \(sel) (pos: \(x),\(y))\n"
                    }
                }
                completion(output)
            } else {
                completion("[Fehler: \(error?.localizedDescription ?? "Unbekannt")]")
            }
        }
    }

    /// Inspiziert alle interaktiven Elemente auf der Seite
    func inspect(tabId: UUID? = nil, completion: @escaping @Sendable (String) -> Void) {
        guard let tab = self.tab(for: tabId) else {
            completion("[Kein Browser-Tab aktiv]")
            return
        }
        guard let wv = tab.webView else {
            completion("[WebView nicht bereit]")
            return
        }
        let js = """
        (() => {
            const results = [];
            const selectors = 'a[href], button, input, select, textarea, [role=button], [role=link], [onclick], [tabindex]';
            document.querySelectorAll(selectors).forEach((el, i) => {
                if (i >= 80) return;
                const r = el.getBoundingClientRect();
                if (r.width === 0 && r.height === 0) return;
                const tag = el.tagName.toLowerCase();
                const type = el.type || '';
                const txt = (el.innerText || el.value || el.placeholder || el.alt || el.title || el.ariaLabel || '').substring(0, 80).trim();
                const href = el.href || '';
                let sel = '';
                if (el.id) sel = '#' + el.id;
                else if (el.name) sel = tag + '[name="' + el.name + '"]';
                else if (tag === 'a' && txt) sel = 'a:has-text("' + txt.substring(0,30) + '")';
                else {
                    const cls = (typeof el.className === 'string') ? el.className.trim().split(/\\s+/).slice(0,2).join('.') : '';
                    if (cls) sel = tag + '.' + cls;
                    else sel = tag + ':nth-of-type(' + (Array.from(el.parentElement.querySelectorAll(tag)).indexOf(el)+1) + ')';
                }
                results.push({i: i+1, tag, type, text: txt, href: href.substring(0,80), selector: sel, x: Math.round(r.x+r.width/2), y: Math.round(r.y+r.height/2), w: Math.round(r.width), h: Math.round(r.height)});
            });
            return JSON.stringify(results);
        })()
        """
        wv.evaluateJavaScript(js) { result, error in
            if let json = result as? String, let data = json.data(using: .utf8),
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                var output = "=== \(arr.count) Interaktive Elemente ===\n"
                for el in arr {
                    let i = el["i"] as? Int ?? 0
                    let tag = el["tag"] as? String ?? ""
                    let type = el["type"] as? String ?? ""
                    let text = el["text"] as? String ?? ""
                    let href = el["href"] as? String ?? ""
                    let sel = el["selector"] as? String ?? ""
                    let x = el["x"] as? Int ?? 0
                    let y = el["y"] as? Int ?? 0
                    let typeStr = type.isEmpty ? tag : "\(tag)[\(type)]"
                    var line = "\(i). [\(typeStr)] \"\(text)\""
                    if !href.isEmpty { line += " → \(href)" }
                    line += "\n   selector: \(sel) | pos: (\(x),\(y))"
                    output += line + "\n"
                }
                completion(output)
            } else {
                completion("[Fehler: \(error?.localizedDescription ?? "Unbekannt")]")
            }
        }
    }

    /// Klickt auf Element via CSS-Selector — gibt Position zurück für virtuelle Maus
    /// Unterstützt mehrstufige Anmeldungen: wartet nach Klick auf Seitenänderung
    func click(selector: String, tabId: UUID? = nil, completion: @escaping @Sendable (String, CGPoint?) -> Void) {
        guard let tab = self.tab(for: tabId) else {
            completion("[Kein Browser-Tab aktiv]", nil)
            return
        }
        guard let wv = tab.webView else {
            completion("[WebView nicht bereit]", nil)
            return
        }

        let escaped = selector.replacingOccurrences(of: "'", with: "\\'")
        let urlBefore = wv.url?.absoluteString ?? ""
        let tabIdForWait = tabId

        let js = """
        (() => {
            let el = document.querySelector('\(escaped)');
            if (!el) {
                const text = '\(escaped)'.replace(/^[^"]*"/, '').replace(/"[^"]*$/, '');
                if (text) {
                    const all = document.querySelectorAll('a, button, input[type=submit], [role=button], [onclick]');
                    // Exact match hat Prioritaet
                    for (const e of all) {
                        const t = (e.innerText || e.value || '').trim();
                        if (t.toLowerCase() === text.toLowerCase()) { el = e; break; }
                    }
                    // Partial match als Fallback
                    if (!el) {
                        for (const e of all) {
                            if ((e.innerText || e.value || '').trim().toLowerCase().includes(text.toLowerCase())) {
                                el = e; break;
                            }
                        }
                    }
                }
            }
            if (!el) return JSON.stringify({status: 'element not found', hint: 'Use inspect action to see available elements'});

            // Position VOR dem Click messen
            const r = el.getBoundingClientRect();
            const pos = {x: r.x + r.width/2, y: r.y + r.height/2};
            el.scrollIntoView({behavior:'smooth', block:'center'});

            return new Promise(resolve => {
                setTimeout(() => {
                    try {
                        el.focus();
                        // KORREKTE Event-Reihenfolge: mousedown -> mouseup -> click
                        const opts = {bubbles: true, cancelable: true, view: window,
                                      clientX: pos.x, clientY: pos.y};
                        el.dispatchEvent(new MouseEvent('mousedown', opts));
                        el.dispatchEvent(new MouseEvent('mouseup', opts));
                        el.dispatchEvent(new MouseEvent('click', opts));
                        resolve(JSON.stringify({status:'clicked', x: pos.x, y: pos.y,
                                text: (el.innerText||el.value||'').substring(0,50)}));
                    } catch(e) {
                        resolve(JSON.stringify({status:'click error: ' + e.message, x: pos.x, y: pos.y}));
                    }
                }, 300);
            });
        })()
        """
        wv.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { [weak self] result in
            switch result {
            case .success(let value):
                if let json = value as? String, let data = json.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let status = obj["status"] as? String ?? "unknown"
                    let x = obj["x"] as? CGFloat
                    let y = obj["y"] as? CGFloat
                    let point = (x != nil && y != nil) ? CGPoint(x: x!, y: y!) : nil

                    if status == "clicked" {
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(nanoseconds: 300_000_000)
                            guard let self = self else {
                                completion("clicked", point)
                                return
                            }
                            guard let currentTab = self.tab(for: tabIdForWait) else {
                                completion("clicked (tab closed)", point)
                                return
                            }
                            let urlAfter = currentTab.webView?.url?.absoluteString ?? ""
                            if urlAfter != urlBefore || currentTab.isLoading {
                                let _ = await self.waitForLoad(tabId: tabIdForWait, timeout: 10)
                                let finalUrl = currentTab.webView?.url?.absoluteString ?? urlAfter
                                completion("clicked (navigated to: \(finalUrl))", point)
                            } else {
                                completion("clicked", point)
                            }
                        }
                    } else {
                        completion(status, point)
                    }
                } else {
                    completion("clicked (no position)", nil)
                }
            case .failure(let error):
                completion("[Click-Fehler: \(error.localizedDescription)]", nil)
            }
        }
    }

    /// Tippt Text in Element via CSS-Selector — gibt Position zurück für virtuelle Maus
    /// Simuliert echtes Tippen mit Input-Events für React/Angular/Vue-Kompatibilität
    /// Hat eingebaute Retry-Loop (max 3s) falls Element noch nicht existiert (z.B. nach Navigation)
    func type(selector: String, text: String, tabId: UUID? = nil, completion: @escaping @Sendable (String, CGPoint?) -> Void) {
        guard let tab = self.tab(for: tabId) else {
            completion("[Kein Browser-Tab aktiv]", nil)
            return
        }
        guard let wv = tab.webView else {
            completion("[WebView nicht bereit]", nil)
            return
        }
        let escapedSel = selector.replacingOccurrences(of: "'", with: "\\'")
        let escapedText = text.replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: "\n", with: "\\n")
        // JS mit eingebauter Retry-Loop
        let js = """
        (async () => {
            let el = null;
            // Retry bis zu 3 Sekunden, falls Element nach Navigation noch nicht da
            for (let attempt = 0; attempt < 6; attempt++) {
                el = document.querySelector('\(escapedSel)');
                if (!el) {
                    // Fallback: Suche input/textarea per placeholder oder name
                    const inputs = document.querySelectorAll('input, textarea');
                    for (const inp of inputs) {
                        if ((inp.placeholder || inp.ariaLabel || inp.name || '').toLowerCase().includes('\(escapedSel)'.toLowerCase())) {
                            el = inp; break;
                        }
                    }
                }
                if (el) break;
                await new Promise(r => setTimeout(r, 500));
            }
            if (!el) return JSON.stringify({status: 'element not found after 3s retry'});
            el.scrollIntoView({block:'center'});
            el.focus();
            // React-compatible: Native setter + Input Events
            const nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')?.set
                || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value')?.set;
            if (nativeSetter) nativeSetter.call(el, '\(escapedText)');
            else el.value = '\(escapedText)';
            el.dispatchEvent(new Event('input', {bubbles:true}));
            el.dispatchEvent(new Event('change', {bubbles:true}));
            el.dispatchEvent(new KeyboardEvent('keyup', {bubbles:true}));
            const r = el.getBoundingClientRect();
            return JSON.stringify({status:'typed', x: r.x + r.width/2, y: r.y + r.height/2});
        })()
        """
        wv.callAsyncJavaScript(js, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                if let json = value as? String, let data = json.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let status = obj["status"] as? String ?? "unknown"
                    let x = obj["x"] as? CGFloat
                    let y = obj["y"] as? CGFloat
                    let point = (x != nil && y != nil) ? CGPoint(x: x!, y: y!) : nil
                    completion(status, point)
                } else {
                    completion("typed (no position)", nil)
                }
            case .failure(let error):
                completion(error.localizedDescription, nil)
            }
        }
    }

    /// Führt beliebiges JavaScript aus
    func executeJS(_ js: String, tabId: UUID? = nil, completion: @escaping @Sendable (String) -> Void) {
        guard let tab = self.tab(for: tabId) else {
            completion("[Kein Browser-Tab aktiv]")
            return
        }
        guard let wv = tab.webView else {
            completion("[WebView nicht bereit]")
            return
        }
        wv.evaluateJavaScript(js) { result, error in
            if let error = error {
                completion("[JS Error: \(error.localizedDescription)]")
            } else if let result = result {
                completion(String(describing: result))
            } else {
                completion("undefined")
            }
        }
    }

    /// Screenshot des aktiven Tabs
    func screenshot(tabId: UUID? = nil, completion: @escaping @Sendable (String) -> Void) {
        guard let tab = self.tab(for: tabId) else {
            completion("[Kein Browser-Tab aktiv]")
            return
        }
        guard let wv = tab.webView else {
            completion("[WebView nicht bereit]")
            return
        }
        let config = WKSnapshotConfiguration()
        wv.takeSnapshot(with: config) { image, error in
            guard let image = image else {
                completion("[Screenshot fehlgeschlagen: \(error?.localizedDescription ?? "")]")
                return
            }
            let tiffData = image.tiffRepresentation
            guard let bitmap = tiffData.flatMap({ NSBitmapImageRep(data: $0) }),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                completion("[PNG-Konvertierung fehlgeschlagen]")
                return
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kobold_screenshots")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent("\(UUID().uuidString).png")
            do {
                try pngData.write(to: path)
                completion(path.path)
            } catch {
                completion("[Speichern fehlgeschlagen: \(error.localizedDescription)]")
            }
        }
    }

    /// Popup/Dialog/Overlay schließen via JavaScript
    func dismissPopup(tabId: UUID? = nil, completion: @escaping @Sendable (String) -> Void) {
        guard let tab = self.tab(for: tabId) else {
            completion("[Kein Browser-Tab aktiv]")
            return
        }
        guard let wv = tab.webView else {
            completion("[WebView nicht bereit]")
            return
        }
        let js = """
        (() => {
            let dismissed = [];
            // Cookie-Banner und typische Overlay-Selektoren
            const popupSelectors = [
                '[class*=cookie] button', '[id*=cookie] button',
                '[class*=consent] button', '[id*=consent] button',
                '[class*=popup] [class*=close]', '[class*=modal] [class*=close]',
                '[class*=overlay] [class*=close]', '[class*=banner] [class*=close]',
                '[aria-label*=close]', '[aria-label*=Close]', '[aria-label*=Schließen]',
                '[aria-label*=dismiss]', '[aria-label*=Dismiss]',
                'button[class*=close]', '.close-button', '#close-button',
                '[class*=dialog] button:first-of-type',
                '[role=dialog] button', '[role=alertdialog] button'
            ];
            for (const sel of popupSelectors) {
                const els = document.querySelectorAll(sel);
                for (const el of els) {
                    const r = el.getBoundingClientRect();
                    if (r.width > 0 && r.height > 0) {
                        const txt = (el.innerText || el.ariaLabel || '').substring(0, 30);
                        el.click();
                        dismissed.push(sel + ' ("' + txt + '")');
                    }
                }
            }
            // Auch versteckte Overlays per Style entfernen
            document.querySelectorAll('[class*=overlay], [class*=backdrop], [class*=modal-bg]').forEach(el => {
                if (getComputedStyle(el).position === 'fixed' || getComputedStyle(el).position === 'absolute') {
                    el.style.display = 'none';
                    dismissed.push('hidden overlay: ' + el.className.substring(0, 40));
                }
            });
            if (dismissed.length === 0) return 'Keine Popups gefunden';
            return 'Geschlossen: ' + dismissed.join(', ');
        })()
        """
        wv.evaluateJavaScript(js) { result, error in
            completion((result as? String) ?? error?.localizedDescription ?? "unknown")
        }
    }

    /// Snapshot für Agent-Kontext
    func getSnapshot(tabId: UUID? = nil) -> [String: String] {
        guard let tab = self.tab(for: tabId) else {
            return ["error": "Kein Browser-Tab aktiv"]
        }
        return [
            "tab_id": tab.id.uuidString,
            "title": tab.title,
            "url": tab.urlString,
            "is_loading": tab.isLoading ? "true" : "false"
        ]
    }
}

// MARK: - WebView Representable

struct WebViewRepresentable: NSViewRepresentable {
    let tab: BrowserTab

    func makeNSView(context: Context) -> WKWebView {
        tab.ensureWebView()
        guard let wv = tab.webView else {
            // Fallback: create minimal webview if ensureWebView failed
            let fallback = WKWebView(frame: .zero)
            fallback.navigationDelegate = context.coordinator
            fallback.uiDelegate = context.coordinator
            return fallback
        }
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab)
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var tab: BrowserTab?
        private var observations: [NSKeyValueObservation] = []

        deinit {
            // Invalidate all KVO observations to prevent leaks
            observations.removeAll()
        }

        init(tab: BrowserTab) {
            self.tab = tab
            super.init()

            guard let wv = tab.webView else { return }

            observations.append(wv.observe(\.title) { [weak self] webView, _ in
                DispatchQueue.main.async { self?.tab?.title = webView.title ?? "Neuer Tab" }
            })
            observations.append(wv.observe(\.url) { [weak self] webView, _ in
                DispatchQueue.main.async { self?.tab?.urlString = webView.url?.absoluteString ?? "" }
            })
            observations.append(wv.observe(\.isLoading) { [weak self] webView, _ in
                DispatchQueue.main.async { self?.tab?.isLoading = webView.isLoading }
            })
            observations.append(wv.observe(\.canGoBack) { [weak self] webView, _ in
                DispatchQueue.main.async { self?.tab?.canGoBack = webView.canGoBack }
            })
            observations.append(wv.observe(\.canGoForward) { [weak self] webView, _ in
                DispatchQueue.main.async { self?.tab?.canGoForward = webView.canGoForward }
            })
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            DispatchQueue.main.async { [weak self] in
                self?.tab?.title = webView.title ?? "Neuer Tab"
                self?.tab?.urlString = webView.url?.absoluteString ?? ""
                self?.tab?.isLoading = false
            }
        }

        // MARK: - WKUIDelegate: JavaScript Alerts, Confirms, Prompts

        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable () -> Void) {
            let alert = NSAlert()
            alert.messageText = "Webseite sagt:"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
            completionHandler()
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (Bool) -> Void) {
            let alert = NSAlert()
            alert.messageText = "Webseite fragt:"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Abbrechen")
            let response = alert.runModal()
            completionHandler(response == .alertFirstButtonReturn)
        }

        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor @Sendable (String?) -> Void) {
            let alert = NSAlert()
            alert.messageText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Abbrechen")
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            input.stringValue = defaultText ?? ""
            alert.accessoryView = input
            let response = alert.runModal()
            completionHandler(response == .alertFirstButtonReturn ? input.stringValue : nil)
        }

        // MARK: - WKUIDelegate: window.open → neuer Tab

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Popup öffnet neuen Tab statt neues Fenster
            if let url = navigationAction.request.url {
                DispatchQueue.main.async {
                    let _ = SharedBrowserManager.shared.newTab(url: url.absoluteString)
                }
            }
            return nil
        }
    }
}

// MARK: - Web Browser Container View

struct WebBrowserContainerView: View {
    @ObservedObject var manager = SharedBrowserManager.shared
    @State private var urlBarText = ""

    var body: some View {
        VStack(spacing: 0) {
            browserTabBar
            if let tab = manager.activeTab {
                browserToolbar(tab: tab)
                Divider().opacity(0.3)
                WebViewRepresentable(tab: tab)
                    .id(tab.id) // Erzwingt neue View pro Tab — verhindert WKWebView-Sharing
            } else {
                browserEmptyState
            }
        }
    }

    // MARK: - Sub-Views

    private var browserTabBar: some View {
        HStack(spacing: 0) {
            ForEach(manager.tabs) { tab in
                browserTabButton(tab: tab)
            }

            Button(action: { let _ = manager.newTab() }) {
                Image(systemName: "plus").font(.system(size: 12)).foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.15))
    }

    private func browserTabButton(tab: BrowserTab) -> some View {
        let isActive = manager.activeTabId == tab.id
        return Button(action: { manager.activeTabId = tab.id }) {
            HStack(spacing: 6) {
                if tab.isLoading {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                } else {
                    Image(systemName: "globe").font(.system(size: 10))
                }
                Text(tab.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .frame(maxWidth: 120)
                Button(action: { manager.closeTab(tab.id) }) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .foregroundColor(isActive ? .koboldEmerald : .secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                isActive
                    ? AnyView(RoundedRectangle(cornerRadius: 6).fill(Color.koboldEmerald.opacity(0.1)))
                    : AnyView(Color.clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func browserToolbar(tab: BrowserTab) -> some View {
        HStack(spacing: 8) {
            Button(action: { manager.activeTab?.goBack() }) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .disabled(!tab.canGoBack)
            .buttonStyle(.plain)
            .foregroundColor(tab.canGoBack ? .primary : .secondary.opacity(0.4))

            Button(action: { manager.activeTab?.goForward() }) {
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
            }
            .disabled(!tab.canGoForward)
            .buttonStyle(.plain)
            .foregroundColor(tab.canGoForward ? .primary : .secondary.opacity(0.4))

            Button(action: { manager.activeTab?.reload() }) {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise").font(.system(size: 12))
            }
            .buttonStyle(.plain)

            TextField("URL oder Suchbegriff eingeben...", text: $urlBarText, onCommit: {
                manager.activeTab?.navigate(to: urlBarText)
            })
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12.5))
            .onAppear { urlBarText = tab.urlString }
            .onChange(of: tab.urlString) { newValue in
                // Nur aktualisieren wenn es der aktive Tab ist
                if tab.id == manager.activeTabId { urlBarText = newValue }
            }
            .onChange(of: manager.activeTabId) { _ in
                urlBarText = manager.activeTab?.urlString ?? ""
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.1))
    }

    private var browserEmptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Neuen Tab öffnen")
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Button(action: { let _ = manager.newTab(url: "https://www.google.com") }) {
                Label("Browser öffnen", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent).tint(.koboldEmerald)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Program Runner View (mit Debounced Output)

struct ProgramRunnerView: View {
    @State private var selectedFile: String = ""
    @State private var language: ProgramLanguage = .auto
    @State private var output: String = ""
    @State private var isRunning = false
    @State private var currentProcess: Process?

    // Phase 1: Debounced output für ProgramRunner
    private let outputBuffer = ProgramOutputBuffer()

    enum ProgramLanguage: String, CaseIterable {
        case auto = "Auto"
        case python = "Python"
        case node = "Node.js"
        case bash = "Bash"
        case swift = "Swift"
    }

    var body: some View {
        VStack(spacing: 0) {
            programToolbar
            Divider().opacity(0.3)
            programOutput
        }
    }

    private var programToolbar: some View {
        HStack(spacing: 12) {
            Button(action: pickFile) {
                Label("Datei auswählen...", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.bordered)

            if !selectedFile.isEmpty {
                Text(selectedFile)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Picker("Sprache", selection: $language) {
                ForEach(ProgramLanguage.allCases, id: \.self) { lang in
                    Text(lang.rawValue).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)

            if isRunning {
                Button(action: stopProgram) {
                    Label("Stoppen", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent).tint(.red)
            } else {
                Button(action: runProgram) {
                    Label("Ausführen", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent).tint(.koboldEmerald)
                .disabled(selectedFile.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.1))
    }

    private var programOutput: some View {
        ScrollView {
            ScrollViewReader { proxy in
                Text(output.isEmpty ? "Wähle eine Datei aus und klicke auf Ausführen..." : output)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(output.isEmpty ? .secondary : .white)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .id("output-bottom")
                    .onChange(of: output) { _ in
                        proxy.scrollTo("output-bottom", anchor: .bottom)
                    }
            }
        }
        .background(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.1, alpha: 1)))
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            selectedFile = url.path
            if language == .auto {
                let ext = url.pathExtension.lowercased()
                switch ext {
                case "py": language = .python
                case "js", "mjs": language = .node
                case "sh", "bash": language = .bash
                case "swift": language = .swift
                default: language = .bash
                }
            }
        }
    }

    private func executableForLanguage() -> (String, [String]) {
        let ext = URL(fileURLWithPath: selectedFile).pathExtension.lowercased()

        switch language {
        case .python: return ("/usr/bin/python3", [selectedFile])
        case .node: return ("/usr/local/bin/node", [selectedFile])
        case .bash: return ("/bin/bash", [selectedFile])
        case .swift: return ("/usr/bin/swift", [selectedFile])
        case .auto:
            switch ext {
            case "py": return ("/usr/bin/python3", [selectedFile])
            case "js", "mjs": return ("/usr/local/bin/node", [selectedFile])
            case "swift": return ("/usr/bin/swift", [selectedFile])
            default: return ("/bin/bash", [selectedFile])
            }
        }
    }

    private func runProgram() {
        guard !selectedFile.isEmpty else { return }
        output = ""
        isRunning = true

        let (executable, args) = executableForLanguage()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: NSString(string: selectedFile).deletingLastPathComponent)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        // Debounced output (gleicher Pattern wie TerminalSession)
        outputBuffer.start { [self] text in
            DispatchQueue.main.async { output += text }
        }

        stdout.fileHandleForReading.readabilityHandler = { [outputBuffer] handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                outputBuffer.append(text)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [outputBuffer] handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                outputBuffer.append("[stderr] \(text)")
            }
        }

        process.terminationHandler = { [self, outputBuffer] proc in
            outputBuffer.flush()
            outputBuffer.stop()
            DispatchQueue.main.async {
                isRunning = false
                output += "\n--- Beendet (Exit Code: \(proc.terminationStatus)) ---\n"
                currentProcess = nil
            }
        }

        do {
            try process.run()
            currentProcess = process
        } catch {
            output = "Error: \(error.localizedDescription)"
            isRunning = false
            outputBuffer.stop()
        }
    }

    private func stopProgram() {
        currentProcess?.terminate()
        currentProcess = nil
        isRunning = false
        outputBuffer.stop()
        output += "\n--- Abgebrochen ---\n"
    }
}

// MARK: - Program Output Buffer (Debounced)

final class ProgramOutputBuffer: @unchecked Sendable {
    private var buffer: String = ""
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var onFlush: ((String) -> Void)?

    func start(onFlush: @escaping (String) -> Void) {
        self.onFlush = onFlush
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in
            self?.flush()
        }
        t.resume()
        timer = t
    }

    func append(_ text: String) {
        lock.lock()
        buffer += text
        lock.unlock()
    }

    func flush() {
        lock.lock()
        guard !buffer.isEmpty else {
            lock.unlock()
            return
        }
        let chunk = buffer
        buffer = ""
        lock.unlock()
        onFlush?(chunk)
    }

    func stop() {
        timer?.cancel()
        timer = nil
        onFlush = nil
    }
}
