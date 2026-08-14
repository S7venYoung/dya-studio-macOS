import AppKit
import Foundation
import Network
import SwiftUI
import WebKit

@main
struct DYAStudioMacApp: App {
    var body: some Scene {
        WindowGroup {
            StudioWebView()
                .frame(minWidth: 1024, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct StudioWebView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.addScriptMessageHandler(
            context.coordinator,
            contentWorld: .page,
            name: "dyaNative"
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.bridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView

        guard let resourceURL = Bundle.main.resourceURL else {
            context.coordinator.showFatalError("App resources could not be found.")
            return webView
        }
        let distURL = resourceURL.appendingPathComponent("dist", isDirectory: true)
        do {
            let server = try LocalWebServer(rootURL: distURL)
            let baseURL = try server.start()
            context.coordinator.webServer = server
            webView.load(URLRequest(url: baseURL))
        } catch {
            context.coordinator.showFatalError(error.localizedDescription)
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    static let bridgeScript = #"""
    (() => {
      const listeners = new Map();
      window.dyaNative = {
        platform: "macOS",
        request(method, params = {}) {
          return window.webkit.messageHandlers.dyaNative.postMessage({ method, params });
        },
        addEventListener(type, listener) {
          const set = listeners.get(type) || new Set();
          set.add(listener);
          listeners.set(type, set);
        },
        removeEventListener(type, listener) {
          listeners.get(type)?.delete(listener);
        }
      };
      window.__dyaNativeEmit = (type, detail) => {
        for (const listener of listeners.get(type) || []) listener({ type, detail });
      };
      window.addEventListener("error", (event) => {
        alert(`JavaScript error: ${event.message}`);
      });
      window.addEventListener("unhandledrejection", (event) => {
        const message = event.reason?.message || String(event.reason);
        alert(`JavaScript error: ${message}`);
      });
    })();
    """#

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandlerWithReply {
        weak var webView: WKWebView?
        var webServer: LocalWebServer?
        private let serial = SerialPortController()

        override init() {
            super.init()
            serial.onData = { [weak self] data in
                self?.emit("serial-data", detail: ["base64": data.base64EncodedString()])
            }
            serial.onDisconnect = { [weak self] in
                self?.emit("serial-disconnect", detail: [:])
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping (Any?, String?) -> Void
        ) {
            guard let body = message.body as? [String: Any],
                  let method = body["method"] as? String else {
                replyHandler(nil, "Invalid native bridge request")
                return
            }
            let params = body["params"] as? [String: Any] ?? [:]

            do {
                switch method {
                case "serial.isAvailable":
                    replyHandler(true, nil)
                case "serial.list":
                    replyHandler(serial.availablePorts(), nil)
                case "serial.connect":
                    let port = try choosePort(from: serial.availablePorts())
                    try serial.connect(path: port)
                    replyHandler(["path": port, "label": URL(fileURLWithPath: port).lastPathComponent], nil)
                case "serial.write":
                    guard let base64 = params["base64"] as? String,
                          let data = Data(base64Encoded: base64) else {
                        throw BridgeError.message("Invalid serial data")
                    }
                    try serial.write(data)
                    replyHandler(true, nil)
                case "serial.disconnect":
                    serial.disconnect(notify: false)
                    replyHandler(true, nil)
                default:
                    replyHandler(nil, "Unsupported native method: \(method)")
                }
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }

        private func choosePort(from ports: [String]) throws -> String {
            guard !ports.isEmpty else {
                throw BridgeError.message("No USB serial device was found. Connect the keyboard and try again.")
            }
            if ports.count == 1 { return ports[0] }

            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
            picker.addItems(withTitles: ports)
            let alert = NSAlert()
            alert.messageText = "Choose a keyboard"
            alert.informativeText = "Select the USB serial device used by ZMK Studio."
            alert.accessoryView = picker
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else {
                throw BridgeError.message("Connection cancelled")
            }
            return ports[picker.indexOfSelectedItem]
        }

        private func emit(_ type: String, detail: [String: Any]) {
            guard let payload = try? JSONSerialization.data(withJSONObject: ["type": type, "detail": detail]),
                  let json = String(data: payload, encoding: .utf8) else { return }
            DispatchQueue.main.async { [weak self] in
                self?.webView?.evaluateJavaScript("window.__dyaNativeEmit(\(json).type, \(json).detail)")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            showFatalError(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            showFatalError(error.localizedDescription)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = "DYA Studio"
            alert.informativeText = message
            alert.runModal()
            completionHandler()
        }

        func showFatalError(_ message: String) {
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "DYA Studio could not start"
                alert.informativeText = message
                alert.runModal()
            }
        }
    }
}

final class LocalWebServer {
    private let rootURL: URL
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.s7venyoung.dya-studio.web-server")

    init(rootURL: URL) throws {
        guard FileManager.default.fileExists(atPath: rootURL.appendingPathComponent("index.html").path) else {
            throw BridgeError.message("The React application bundle is missing.")
        }
        self.rootURL = rootURL.standardizedFileURL
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() throws -> URL {
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startupError = error
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw BridgeError.message("The local web server timed out while starting.")
        }
        if let startupError {
            throw startupError
        }
        guard let port = listener.port else {
            throw BridgeError.message("The local web server did not allocate a port.")
        }
        return URL(string: "http://127.0.0.1:\(port.rawValue)/")!
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data,
                  let request = String(data: data, encoding: .utf8),
                  let firstLine = request.components(separatedBy: "\r\n").first else {
                connection.cancel()
                return
            }
            let components = firstLine.split(separator: " ")
            guard components.count >= 2, components[0] == "GET" else {
                self.respond(connection, status: "405 Method Not Allowed", body: Data(), mimeType: "text/plain")
                return
            }

            let rawPath = String(components[1]).split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
            let decodedPath = rawPath.removingPercentEncoding ?? rawPath
            let relativePath = decodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var fileURL = self.rootURL.appendingPathComponent(relativePath.isEmpty ? "index.html" : relativePath)
                .standardizedFileURL

            if !fileURL.path.hasPrefix(self.rootURL.path) || !FileManager.default.fileExists(atPath: fileURL.path) {
                fileURL = self.rootURL.appendingPathComponent("index.html")
            }

            do {
                let body = try Data(contentsOf: fileURL)
                self.respond(connection, status: "200 OK", body: body, mimeType: Self.mimeType(for: fileURL))
            } catch {
                self.respond(connection, status: "500 Internal Server Error", body: Data(), mimeType: "text/plain")
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: Data, mimeType: String) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(mimeType)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "map": return "application/json"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        default: return "application/octet-stream"
        }
    }

    deinit { listener.cancel() }
}

final class SerialPortController {
    var onData: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?
    private var handle: FileHandle?

    func availablePorts() -> [String] {
        let deviceDirectory = URL(fileURLWithPath: "/dev")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: deviceDirectory.path)) ?? []
        return names
            .filter { $0.hasPrefix("cu.usbmodem") || $0.hasPrefix("cu.usbserial") || $0.hasPrefix("cu.SLAB_USBtoUART") }
            .sorted()
            .map { deviceDirectory.appendingPathComponent($0).path }
    }

    func connect(path: String) throws {
        disconnect(notify: false)
        guard let nextHandle = FileHandle(forUpdatingAtPath: path) else {
            throw BridgeError.message("Unable to open \(path)")
        }
        handle = nextHandle
        nextHandle.readabilityHandler = { [weak self] file in
            let data = file.availableData
            guard !data.isEmpty else {
                self?.disconnect(notify: true)
                return
            }
            self?.onData?(data)
        }
    }

    func write(_ data: Data) throws {
        guard let handle else { throw BridgeError.message("Serial device is not connected") }
        try handle.write(contentsOf: data)
    }

    func disconnect(notify: Bool) {
        guard let current = handle else { return }
        handle = nil
        current.readabilityHandler = nil
        try? current.close()
        if notify { onDisconnect?() }
    }

    deinit { disconnect(notify: false) }
}

enum BridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}
