import AppKit
import Foundation
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
        context.coordinator.webView = webView

        guard let resourceURL = Bundle.main.resourceURL else {
            context.coordinator.showFatalError("App resources could not be found.")
            return webView
        }
        let indexURL = resourceURL.appendingPathComponent("dist/index.html")
        webView.loadFileURL(indexURL, allowingReadAccessTo: resourceURL)
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
    })();
    """#

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
        weak var webView: WKWebView?
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
