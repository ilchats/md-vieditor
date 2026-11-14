// MD Vieditor — простая программа для просмотра и правки Markdown-файлов на macOS.
// Документ правится прямо в оформленном виде: внутри окна работает визуальный редактор Vditor.
// Сборка: bash build.sh (нужны Command Line Tools от Apple).

import Cocoa
import WebKit

// MARK: - Точка входа

@main
struct MDVieditorMain {
    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) {
                app.run()
            }
        }
    }
}

extension Notification.Name {
    static let mdDocumentDidRevert = Notification.Name("MDDocumentDidRevert")
    static let mdZoomDidChange = Notification.Name("MDZoomDidChange")
    static let mdColorsDidChange = Notification.Name("MDColorsDidChange")
}

// MARK: - Свои цвета фона и текста (окно Settings)

enum ColorSettings {
    static let backgroundKey = "CustomBackgroundColor"
    static let textKey = "CustomTextColor"

    static var background: String? { UserDefaults.standard.string(forKey: backgroundKey) }
    static var text: String? { UserDefaults.standard.string(forKey: textKey) }

    static func hex(from color: NSColor) -> String? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ value: CGFloat) -> Int { max(0, min(255, Int((value * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    static func color(fromHex hex: String?) -> NSColor? {
        guard var digits = hex?.trimmingCharacters(in: .whitespaces), digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }
}

// MARK: - Документ

@objc(MarkdownDocument)
final class MarkdownDocument: NSDocument {
    static let openableExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "txt", "text"]

    /// Текущий текст документа в Markdown. Редактор присылает его после каждой правки.
    var text = ""
    private var encoding: String.Encoding = .utf8
    private var hasUTF8BOM = false

    override class var autosavesInPlace: Bool { false }
    override var shouldRunSavePanelWithAccessoryView: Bool { false }

    override func makeWindowControllers() {
        MainActor.assumeIsolated {
            addWindowController(EditorWindowController(document: self))
        }
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let decoded = MarkdownDocument.decode(data)
        text = decoded.text
        encoding = decoded.encoding
        hasUTF8BOM = decoded.hasBOM
    }

    override func data(ofType typeName: String) throws -> Data {
        if encoding != .utf8, let data = text.data(using: encoding) {
            return data
        }
        // Всё, что нельзя записать в прежней кодировке, сохраняется в UTF-8.
        encoding = .utf8
        var data = Data(text.utf8)
        if hasUTF8BOM { data.insert(contentsOf: [0xEF, 0xBB, 0xBF], at: 0) }
        return data
    }

    /// Перед записью файла забираем из редактора самый свежий текст.
    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
                       completionHandler: @escaping (Error?) -> Void) {
        MainActor.assumeIsolated {
            guard let controller = windowControllers.first as? EditorWindowController else {
                super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
                return
            }
            controller.fetchMarkdown { markdown in
                if let markdown = markdown {
                    self.text = markdown
                }
                let savedText = self.text
                super.save(to: url, ofType: typeName, for: saveOperation) { error in
                    if error == nil {
                        MainActor.assumeIsolated {
                            controller.documentDidSave(savedText)
                        }
                    }
                    completionHandler(error)
                }
            }
        }
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        NotificationCenter.default.post(name: .mdDocumentDidRevert, object: self)
    }

    static func decode(_ data: Data) -> (text: String, encoding: String.Encoding, hasBOM: Bool) {
        let head = [UInt8](data.prefix(3))
        if head.count == 3, head[0] == 0xEF, head[1] == 0xBB, head[2] == 0xBF {
            return (String(decoding: data.dropFirst(3), as: UTF8.self), .utf8, true)
        }
        if head.count >= 2, (head[0] == 0xFF && head[1] == 0xFE) || (head[0] == 0xFE && head[1] == 0xFF),
           let text = String(data: data, encoding: .utf16) {
            return (text, .utf16, false)
        }
        if let text = String(data: data, encoding: .utf8) {
            return (text, .utf8, false)
        }
        if let text = String(data: data, encoding: .windowsCP1251) {
            return (text, .windowsCP1251, false)
        }
        return (String(decoding: data, as: UTF8.self), .utf8, false)
    }
}

// MARK: - Окно документа

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate,
                                    WKUIDelegate, WKScriptMessageHandler {

    /// Режимы Vditor: визуальный, «как в Typora», исходный текст.
    enum Mode: String {
        case wysiwyg, ir, sv
    }

    static let modeDefaultsKey = "EditorMode"
    static let zoomDefaultsKey = "Zoom"
    private static let pageURL = URL(string: "mdapp://app/web/editor.html")!
    private static let messageName = "mdEditor"
    private static var cascadePoint = NSPoint.zero

    private(set) var mode: Mode = .wysiwyg
    private(set) var editorReady = false
    private weak var markdownDocument: MarkdownDocument?
    private let webView: WKWebView
    private let pageUndoManager = UndoManager()
    private var pageLoaded = false
    private var readyHandlers: [([String: Any]) -> Void] = []

    init(document: MarkdownDocument) {
        markdownDocument = document

        let contentController = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.setURLSchemeHandler(AppResourceSchemeHandler(), forURLScheme: "mdapp")
        configuration.setURLSchemeHandler(DocumentImageSchemeHandler(), forURLScheme: "mdfile")
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 740), configuration: configuration)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 740),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        super.init(window: window)

        contentController.add(WeakScriptMessageProxy(target: self), name: Self.messageName)

        window.identifier = NSUserInterfaceItemIdentifier("MDVieditorDocumentWindow")
        window.delegate = self
        window.contentMinSize = NSSize(width: 560, height: 360)
        window.contentView = webView
        window.initialFirstResponder = webView

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsMagnification = true
        webView.pageZoom = Self.zoom
        webView.setAccessibilityLabel("Document")

        if let saved = UserDefaults.standard.string(forKey: Self.modeDefaultsKey), let savedMode = Mode(rawValue: saved) {
            mode = savedMode
        }
        placeWindow(window)

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(documentDidRevert(_:)), name: .mdDocumentDidRevert, object: document)
        center.addObserver(self, selector: #selector(zoomDidChange(_:)), name: .mdZoomDidChange, object: nil)
        center.addObserver(self, selector: #selector(colorsDidChange(_:)), name: .mdColorsDidChange, object: nil)

        webView.load(URLRequest(url: Self.pageURL))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не поддерживается")
    }

    private func placeWindow(_ window: NSWindow) {
        window.center()
        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
    }

    // MARK: Связь со страницей редактора

    static func baseHref(for fileURL: URL?) -> String {
        guard let directory = fileURL?.deletingLastPathComponent().path else { return "mdfile:///" }
        let path = directory.hasSuffix("/") ? directory : directory + "/"
        return "mdfile://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)
    }

    private func openInEditor() {
        guard let document = markdownDocument else { return }
        let arguments: [String: Any] = [
            "md": document.text,
            "base": Self.baseHref(for: document.fileURL),
            "mode": mode.rawValue,
        ]
        webView.callAsyncJavaScript("return await window.mdOpen(md, base, mode);", arguments: arguments,
                                    in: nil, in: .page) { [weak self] result in
            var stats: [String: Any] = [:]
            switch result {
            case .success(let value):
                stats = (value as? [String: Any]) ?? [:]
            case .failure(let error):
                stats = ["ошибка": error.localizedDescription]
            }
            let opened = stats
            MainActor.assumeIsolated {
                self?.editorDidOpen(opened)
            }
        }
    }

    private func editorDidOpen(_ stats: [String: Any]) {
        editorReady = stats["ошибка"] == nil
        applyColors()
        if let raw = stats["mode"] as? String, let openedMode = Mode(rawValue: raw) {
            mode = openedMode
        }
        let handlers = readyHandlers
        readyHandlers.removeAll()
        handlers.forEach { $0(stats) }
    }

    private func runEditorScript(_ body: String, _ arguments: [String: Any] = [:]) {
        guard editorReady else {
            NSSound.beep()
            return
        }
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    /// Самый свежий Markdown из редактора (nil, если редактор ещё не готов).
    func fetchMarkdown(_ completion: @escaping (String?) -> Void) {
        guard editorReady else {
            completion(nil)
            return
        }
        webView.callAsyncJavaScript("return window.mdGetMarkdown();", arguments: [:], in: nil, in: .page) { result in
            if case .success(let value) = result, let markdown = value as? String {
                completion(markdown)
            } else {
                completion(nil)
            }
        }
    }

    func documentDidSave(_ text: String) {
        guard editorReady else { return }
        runEditorScript("window.mdSetBase(base); window.mdMarkSaved(md);",
                        ["md": text, "base": Self.baseHref(for: markdownDocument?.fileURL)])
    }

    @objc private func documentDidRevert(_ notification: Notification) {
        guard let document = markdownDocument else { return }
        runEditorScript("window.mdSetMarkdown(md, base);",
                        ["md": document.text, "base": Self.baseHref(for: document.fileURL)])
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        switch type {
        case "changed":
            guard let document = markdownDocument, let markdown = body["markdown"] as? String else { return }
            document.text = markdown
            let dirty = (body["dirty"] as? Bool) ?? true
            document.updateChangeCount(dirty ? .changeDone : .changeCleared)
        case "openLink":
            if let href = body["href"] as? String {
                openHref(href)
            }
        case "mode":
            if let raw = body["mode"] as? String, let newMode = Mode(rawValue: raw) {
                mode = newMode
                if !SelfTestRunner.isRequested {
                    UserDefaults.standard.set(raw, forKey: Self.modeDefaultsKey)
                }
            }
        default:
            break
        }
    }

    // MARK: Команды меню

    @objc func mdUndo(_ sender: Any?) { runEditorScript("window.mdCommand('undo');") }
    @objc func mdRedo(_ sender: Any?) { runEditorScript("window.mdCommand('redo');") }

    @objc func mdFormat(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let name = item.representedObject as? String else { return }
        runEditorScript("window.mdCommand(name);", ["name": name])
    }

    @objc func mdHeading(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        runEditorScript("window.mdHeading(level);", ["level": item.tag])
    }

    @objc func mdModeWysiwyg(_ sender: Any?) { setMode(.wysiwyg) }
    @objc func mdModeInstant(_ sender: Any?) { setMode(.ir) }
    @objc func mdModeSource(_ sender: Any?) { setMode(.sv) }

    func setMode(_ newMode: Mode, persist: Bool = true) {
        mode = newMode
        if persist {
            UserDefaults.standard.set(newMode.rawValue, forKey: Self.modeDefaultsKey)
        }
        if editorReady {
            webView.callAsyncJavaScript("return window.mdSetMode(mode);", arguments: ["mode": newMode.rawValue],
                                        in: nil, in: .page, completionHandler: nil)
        }
    }

    @objc func mdRevealInFinder(_ sender: Any?) {
        guard let url = markdownDocument?.fileURL else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Размер шрифта

    static var zoom: CGFloat {
        let value = UserDefaults.standard.double(forKey: zoomDefaultsKey)
        return value > 0 ? CGFloat(value) : 1
    }

    private static func setZoom(_ value: CGFloat) {
        UserDefaults.standard.set(Double(min(max(value, 0.5), 3)), forKey: zoomDefaultsKey)
        NotificationCenter.default.post(name: .mdZoomDidChange, object: nil)
    }

    @objc func mdZoomIn(_ sender: Any?) { Self.setZoom(Self.zoom * 1.1) }
    @objc func mdZoomOut(_ sender: Any?) { Self.setZoom(Self.zoom / 1.1) }
    @objc func mdZoomReset(_ sender: Any?) { Self.setZoom(1) }

    @objc private func zoomDidChange(_ notification: Notification) {
        webView.pageZoom = Self.zoom
    }

    // MARK: Цвета

    @objc private func colorsDidChange(_ notification: Notification) {
        applyColors()
    }

    private func applyColors() {
        guard editorReady else { return }
        var arguments: [String: Any] = ["bg": NSNull(), "fg": NSNull()]
        if let background = ColorSettings.background {
            arguments["bg"] = background
        }
        if let text = ColorSettings.text {
            arguments["fg"] = text
        }
        webView.callAsyncJavaScript("window.mdSetColors(bg, fg);", arguments: arguments,
                                    in: nil, in: .page, completionHandler: nil)
    }

    // MARK: Окно

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        // Отмену правок ведёт сам редактор; общий список отмен документа не засоряем.
        pageUndoManager
    }

    func windowWillClose(_ notification: Notification) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.messageName)
    }

    // MARK: Загрузка страницы и ссылки

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !pageLoaded else { return }
        pageLoaded = true
        openInEditor()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pageLoaded = false
        editorReady = false
        webView.load(URLRequest(url: Self.pageURL))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Разрешена только загрузка самой страницы редактора. Ссылки открываются отдельно.
        if !pageLoaded, navigationAction.navigationType == .other {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            openLink(url)
        }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            openLink(url)
        }
        return nil
    }

    /// Ссылка из документа: адрес в интернете, почта или путь к файлу относительно документа.
    private func openHref(_ href: String) {
        if href.hasPrefix("#") {
            NSSound.beep()
            return
        }
        if let url = URL(string: href), let scheme = url.scheme, !scheme.isEmpty {
            openLink(url)
            return
        }
        guard let directory = markdownDocument?.fileURL?.deletingLastPathComponent() else {
            NSSound.beep()
            return
        }
        let decoded = href.removingPercentEncoding ?? href
        let path = decoded.components(separatedBy: "#").first ?? decoded
        openLink(URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL)
    }

    private func openLink(_ url: URL) {
        switch url.scheme?.lowercased() ?? "" {
        case "http", "https", "mailto":
            NSWorkspace.shared.open(url)
        case "mdfile", "file":
            let fileURL = URL(fileURLWithPath: url.path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
                NSSound.beep()
                return
            }
            if !isDirectory.boolValue,
               MarkdownDocument.openableExtensions.contains(fileURL.pathExtension.lowercased()) {
                NSDocumentController.shared.openDocument(withContentsOf: fileURL, display: true) { _, _, error in
                    if let error = error {
                        NSApp.presentError(error)
                    }
                }
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
        default:
            NSSound.beep()
        }
    }

    // MARK: Самопроверка после сборки

    var documentIsEdited: Bool {
        markdownDocument?.isDocumentEdited ?? false
    }

    func whenEditorReady(_ handler: @escaping ([String: Any]) -> Void) {
        if editorReady {
            handler([:])
        } else {
            readyHandlers.append(handler)
        }
    }

    func runScript(_ body: String, completion: @escaping (Any?) -> Void) {
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value):
                completion(value)
            case .failure(let error):
                completion("ошибка: \(error.localizedDescription)")
            }
        }
    }

    func snapshot(path: String, completion: @escaping (String) -> Void) {
        webView.takeSnapshot(with: nil) { image, error in
            var report = "снимок окна: не записан \(error.map { String(describing: $0) } ?? "")\n"
            if let image = image, let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]),
               (try? png.write(to: URL(fileURLWithPath: path))) != nil {
                report = "снимок окна: записан\n"
            }
            completion(report)
        }
    }
}

// MARK: - Окно Settings: цвет фона и текста

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let backgroundWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))
    private let textWell = NSColorWell(frame: NSRect(x: 0, y: 0, width: 64, height: 28))

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 180),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let backgroundLabel = NSTextField(labelWithString: "Background color:")
        let textLabel = NSTextField(labelWithString: "Text color:")
        let resetButton = NSButton(title: "Use Theme Colors", target: self, action: #selector(resetColors(_:)))

        for well in [backgroundWell, textWell] {
            well.target = self
            well.action = #selector(colorChanged(_:))
            well.translatesAutoresizingMaskIntoConstraints = false
            well.widthAnchor.constraint(equalToConstant: 64).isActive = true
            well.heightAnchor.constraint(equalToConstant: 28).isActive = true
        }
        refreshWells()

        let grid = NSGridView(views: [[backgroundLabel, backgroundWell], [textLabel, textWell]])
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.rowAlignment = .none
        grid.column(at: 0).xPlacement = .trailing
        for row in 0..<grid.numberOfRows {
            grid.row(at: row).yPlacement = .center
        }

        let stack = NSStackView(views: [grid, resetButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 24, right: 28)
        window.contentView = stack
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не поддерживается")
    }

    private func refreshWells() {
        backgroundWell.color = ColorSettings.color(fromHex: ColorSettings.background) ?? .textBackgroundColor
        textWell.color = ColorSettings.color(fromHex: ColorSettings.text) ?? .textColor
    }

    @objc private func colorChanged(_ sender: NSColorWell) {
        let key = (sender === backgroundWell) ? ColorSettings.backgroundKey : ColorSettings.textKey
        guard let hex = ColorSettings.hex(from: sender.color) else { return }
        UserDefaults.standard.set(hex, forKey: key)
        NotificationCenter.default.post(name: .mdColorsDidChange, object: nil)
    }

    @objc private func resetColors(_ sender: Any?) {
        backgroundWell.deactivate()
        textWell.deactivate()
        UserDefaults.standard.removeObject(forKey: ColorSettings.backgroundKey)
        UserDefaults.standard.removeObject(forKey: ColorSettings.textKey)
        refreshWells()
        NotificationCenter.default.post(name: .mdColorsDidChange, object: nil)
    }

    func windowWillClose(_ notification: Notification) {
        backgroundWell.deactivate()
        textWell.deactivate()
        NSColorPanel.shared.orderOut(nil)
    }
}

// MARK: - Вспомогательные классы

/// Передаёт сообщения страницы окну, не удерживая окно в памяти.
final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    private weak var target: (any WKScriptMessageHandler)?

    init(target: any WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

/// Файлы самой программы для страницы редактора: mdapp://app/web/… → Contents/Resources/web/…
final class AppResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "json": "application/json", "svg": "image/svg+xml",
        "png": "image/png", "jpg": "image/jpeg", "gif": "image/gif", "woff2": "font/woff2",
        "woff": "font/woff", "ttf": "font/ttf", "otf": "font/otf",
    ]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let resources = Bundle.main.resourceURL?.standardizedFileURL else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let root = resources.appendingPathComponent("web", isDirectory: true).standardizedFileURL
        let relative = url.path.hasPrefix("/web/") ? String(url.path.dropFirst("/web/".count)) : ""
        let fileURL = root.appendingPathComponent(relative).standardizedFileURL
        let fileExtension = fileURL.pathExtension.lowercased()
        guard !relative.isEmpty,
              fileURL.path.hasPrefix(root.path + "/"),
              let mimeType = Self.mimeTypes[fileExtension],
              let data = try? Data(contentsOf: fileURL),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": mimeType,
                                                            "Content-Length": String(data.count)]) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

/// Картинки, лежащие рядом с документом (адреса вида mdfile:///путь/к/картинке.png).
/// Другие файлы через этот адрес не читаются.
final class DocumentImageSchemeHandler: NSObject, WKURLSchemeHandler {
    private static let imageTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "webp": "image/webp", "svg": "image/svg+xml", "bmp": "image/bmp", "ico": "image/x-icon",
        "tif": "image/tiff", "tiff": "image/tiff", "heic": "image/heic", "avif": "image/avif",
    ]

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        let path = url.path
        let fileExtension = (path as NSString).pathExtension.lowercased()
        guard let mimeType = Self.imageTypes[fileExtension],
              let data = FileManager.default.contents(atPath: path),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": mimeType,
                                                            "Content-Length": String(data.count),
                                                            "Cache-Control": "max-age=30"]) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

// MARK: - Приложение и меню

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var recentMenu: NSMenu?
    private var viewMenu: NSMenu?
    private var selfTest: SelfTestRunner?
    private var settingsWindowController: SettingsWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        _ = NSDocumentController.shared
        NSApp.mainMenu = makeMainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTestRunner.isRequested {
            let runner = SelfTestRunner(arguments: CommandLine.arguments)
            selfTest = runner
            runner.start()
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !SelfTestRunner.isRequested
    }

    /// При запуске без файла (и при щелчке по значку в Dock без открытых окон) показываем окно выбора файла.
    func applicationOpenUntitledFile(_ sender: NSApplication) -> Bool {
        NSDocumentController.shared.perform(#selector(NSDocumentController.openDocument(_:)), with: nil, afterDelay: 0)
        return true
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Меню

    private func makeMainMenu() -> NSMenu {
        let appName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "MD Vieditor"
        let main = NSMenu(title: "Main Menu")

        let app = NSMenu(title: appName)
        app.addItem(withTitle: "About \(appName)",
                    action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        let settingsItem = app.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settingsItem.target = self
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others",
                    action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        add(app, to: main)

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        let recent = NSMenu(title: "Open Recent")
        recent.delegate = self
        recent.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        recentMenu = recent
        file.addItem(withTitle: "Open Recent", action: nil, keyEquivalent: "").submenu = recent
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        file.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
            .keyEquivalentModifierMask = [.command, .shift]
        file.addItem(withTitle: "Revert to Saved", action: #selector(NSDocument.revertToSaved(_:)), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Show in Finder",
                     action: #selector(EditorWindowController.mdRevealInFinder(_:)), keyEquivalent: "")
        add(file, to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(EditorWindowController.mdUndo(_:)), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: #selector(EditorWindowController.mdRedo(_:)), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        addFinderItem(to: find, "Find…", .showFindInterface, "f")
        addFinderItem(to: find, "Find Next", .nextMatch, "g")
        addFinderItem(to: find, "Find Previous", .previousMatch, "g", [.command, .shift])
        addFinderItem(to: find, "Use Selection for Find", .setSearchString, "e")
        edit.addItem(withTitle: "Find", action: nil, keyEquivalent: "").submenu = find
        add(edit, to: main)

        // Пункты дублируют кнопки панели редактора. Их сочетания клавиш работают и в русской раскладке.
        let format = NSMenu(title: "Format")
        for level in 1...3 {
            let item = format.addItem(withTitle: "Heading \(level)",
                                      action: #selector(EditorWindowController.mdHeading(_:)), keyEquivalent: "\(level)")
            item.tag = level
            item.keyEquivalentModifierMask = [.command, .option]
        }
        format.addItem(.separator())
        addFormatItem(to: format, "Bold", "bold", "b")
        addFormatItem(to: format, "Italic", "italic", "i")
        addFormatItem(to: format, "Strikethrough", "strike", "d")
        addFormatItem(to: format, "Inline Code", "inline-code", "c", [.command, .option])
        addFormatItem(to: format, "Link", "link", "k")
        format.addItem(.separator())
        addFormatItem(to: format, "Bulleted List", "list", "l")
        addFormatItem(to: format, "Numbered List", "ordered-list", "l", [.command, .shift])
        addFormatItem(to: format, "Task List", "check", "j")
        addFormatItem(to: format, "Quote", "quote", "")
        addFormatItem(to: format, "Code Block", "code", "u")
        addFormatItem(to: format, "Table", "table", "t", [.command, .option])
        addFormatItem(to: format, "Horizontal Rule", "line", "h", [.command, .shift])
        add(format, to: main)

        let view = NSMenu(title: "View")
        view.delegate = self
        viewMenu = view
        view.addItem(withTitle: "Visual Editor", action: #selector(EditorWindowController.mdModeWysiwyg(_:)), keyEquivalent: "1")
        view.addItem(withTitle: "Instant Rendering (like Typora)",
                     action: #selector(EditorWindowController.mdModeInstant(_:)), keyEquivalent: "2")
        view.addItem(withTitle: "Markdown Source", action: #selector(EditorWindowController.mdModeSource(_:)), keyEquivalent: "3")
        view.addItem(.separator())
        view.addItem(withTitle: "Zoom In", action: #selector(EditorWindowController.mdZoomIn(_:)), keyEquivalent: "+")
        let zoomInAlternate = view.addItem(withTitle: "Zoom In",
                                           action: #selector(EditorWindowController.mdZoomIn(_:)), keyEquivalent: "=")
        zoomInAlternate.isHidden = true
        zoomInAlternate.allowsKeyEquivalentWhenHidden = true
        view.addItem(withTitle: "Zoom Out", action: #selector(EditorWindowController.mdZoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(EditorWindowController.mdZoomReset(_:)), keyEquivalent: "0")
        add(view, to: main)

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front",
                       action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        add(window, to: main)

        return main
    }

    private func add(_ submenu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }

    private func addFinderItem(to menu: NSMenu, _ title: String, _ action: NSTextFinder.Action,
                               _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = menu.addItem(withTitle: title, action: #selector(NSResponder.performTextFinderAction(_:)),
                                keyEquivalent: key)
        item.tag = action.rawValue
        item.keyEquivalentModifierMask = modifiers
    }

    private func addFormatItem(to menu: NSMenu, _ title: String, _ command: String, _ key: String,
                               _ modifiers: NSEvent.ModifierFlags = [.command]) {
        let item = menu.addItem(withTitle: title, action: #selector(EditorWindowController.mdFormat(_:)),
                                keyEquivalent: key)
        item.representedObject = command
        item.keyEquivalentModifierMask = modifiers
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === recentMenu {
            rebuildRecentMenu(menu)
        } else if menu === viewMenu {
            updateViewMenu(menu)
        }
    }

    private func rebuildRecentMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let urls = NSDocumentController.shared.recentDocumentURLs
        for url in urls {
            let item = NSMenuItem(title: url.lastPathComponent, action: #selector(openRecentDocument(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        if !urls.isEmpty {
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
    }

    private func updateViewMenu(_ menu: NSMenu) {
        let window = NSApp.mainWindow ?? NSApp.keyWindow
        let mode = (window?.windowController as? EditorWindowController)?.mode
        for item in menu.items {
            if item.action == #selector(EditorWindowController.mdModeWysiwyg(_:)) {
                item.state = mode == .wysiwyg ? .on : .off
            } else if item.action == #selector(EditorWindowController.mdModeInstant(_:)) {
                item.state = mode == .ir ? .on : .off
            } else if item.action == #selector(EditorWindowController.mdModeSource(_:)) {
                item.state = mode == .sv ? .on : .off
            }
        }
    }

    @objc private func showSettings(_ sender: Any?) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func openRecentDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error = error {
                NSApp.presentError(error)
            }
        }
    }
}

// MARK: - Самопроверка: build.sh запускает программу с --selftest и получает снимок окна

@MainActor
final class SelfTestRunner: NSObject {
    nonisolated static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    private let inputPath: String
    private let outputPrefix: String
    private var log = ""
    private var document: MarkdownDocument?
    private var controller: EditorWindowController?

    init(arguments: [String]) {
        if let index = arguments.firstIndex(of: "--selftest"), arguments.count > index + 2 {
            inputPath = arguments[index + 1]
            outputPrefix = arguments[index + 2]
        } else {
            inputPath = ""
            outputPrefix = ""
        }
        super.init()
    }

    func start() {
        guard !inputPath.isEmpty else { exit(64) }
        log += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
        perform(#selector(timedOut), with: nil, afterDelay: 30)
        do {
            let document = try MarkdownDocument(contentsOf: URL(fileURLWithPath: inputPath),
                                                ofType: "net.daringfireball.markdown")
            self.document = document
            log += "документ прочитан: \(document.text.count) символов\n"
            document.makeWindowControllers()
            guard let controller = document.windowControllers.first as? EditorWindowController else {
                finish(2, "окно не создано")
                return
            }
            self.controller = controller
            controller.setMode(.wysiwyg, persist: false)
            controller.showWindow(nil)
            NSApp.activate()
            controller.whenEditorReady { [weak self] stats in
                guard let self = self else { return }
                self.log += "редактор: \(stats)\n"
                self.perform(#selector(SelfTestRunner.checkImagesAndEdit), with: nil, afterDelay: 1.5)
            }
        } catch {
            finish(1, "ошибка открытия: \(error)")
        }
    }

    @objc private func checkImagesAndEdit() {
        guard let controller = controller else { return }
        let script = "return Array.from(document.querySelectorAll('#editor img')).map(function (i) { "
            + "return i.getAttribute('src') + ' -> ' + (i.complete && i.naturalWidth ? i.naturalWidth + 'px' : 'не загрузилась'); "
            + "}).join('; ');"
        controller.runScript(script) { [weak self] value in
            guard let self = self else { return }
            let images = value.map { String(describing: $0) } ?? "нет"
            self.log += "картинки: " + images + "\n"
            self.log += "признак «изменено» до правки: \(controller.documentIsEdited)\n"
            controller.runScript("return window.mdSelfTestEdit();") { _ in
                self.perform(#selector(SelfTestRunner.checkEdit), with: nil, afterDelay: 1.5)
            }
        }
    }

    @objc private func checkEdit() {
        guard let controller = controller else { return }
        log += "признак «изменено» после правки: \(controller.documentIsEdited)\n"
        controller.fetchMarkdown { [weak self] markdown in
            guard let self = self else { return }
            let hasEdit = markdown?.contains("Самопроверка ввода") ?? false
            self.log += "правка дошла до программы: \(hasEdit)\n"
            controller.snapshot(path: self.outputPrefix + "-window.png") { report in
                self.log += report
                self.finish(0, "самопроверка завершена")
            }
        }
    }

    @objc private func timedOut() {
        finish(3, "превышено время ожидания")
    }

    private func finish(_ code: Int32, _ message: String) {
        log += message + "\n"
        try? log.write(toFile: outputPrefix + "-log.txt", atomically: true, encoding: .utf8)
        exit(code)
    }
}
