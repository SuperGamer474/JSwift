// Sources/JSwift/JSwift.swift
import WebKit
import Foundation

/// JSwift – sync + async JavaScript execution with natural `returnToSwift value` syntax
public enum JSwift {
    private static let engine = JSEngine()

    // MARK: - Synchronous (blocks the thread)
    public static func execute<T>(_ js: String) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T!
        var thrownError: Error?

        Task {
            do {
                let value = try await engine.evaluate(js)
                result = value as? T ?? (value as! T)
            } catch {
                thrownError = error
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let error = thrownError {
            fatalError("JSwift JavaScript error: \(error.localizedDescription)")
        }
        return result
    }

    // MARK: - Async/Await
    public static func executeAsync<T: Decodable>(_ js: String) async throws -> T {
        let value = try await engine.evaluate(js)

        if let value = value as? T {
            return value
        }

        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Actor Engine (fixed initializer order)

private actor JSEngine {
    private let webView: WKWebView
    private let messageHandler: SwiftMessageHandler      // <-- stored reference so it lives

    private var pending: [UUID: CheckedContinuation<Any, Error>] = [:]

    init() {
        // 1. Create configuration & controller first
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()

        // 2. Inject the magic `returnToSwift` bridge
        let bridge = """
        (function() {
            const send = (value) => {
                webkit.messageHandlers.jswift.postMessage({
                    id: window.__jswift_id,
                    value: value
                });
            };
            Object.defineProperty(window, 'returnToSwift', {
                set: send,
                get: () => { throw new Error('returnToSwift is write-only') }
            });
        })();
        """

        controller.addUserScript(
            WKUserScript(source: bridge,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: true)
        )

        // 3. Create the hidden web view
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isHidden = true

        // 4. NOW we can safely create the message handler (uses `self`)
        let handler = SwiftMessageHandler(engine: self)
        controller.add(handler, name: "jswift")

        // 5. Assign all stored properties – order matters!
        self.webView = wv
        self.messageHandler = handler

        // 6. Load a tiny page so the JS context is ready
        wv.loadHTMLString("<script></script>", baseURL: nil)
    }

    func evaluate(_ js: String) async throws -> Any {
        try await withCheckedThrowingContinuation { cont in
            let id = UUID()
            pending[id] = cont

            let wrapped = """
            (function() {
                window.__jswift_id = '\(id.uuidString)';
                try {
                    \(js)
                } catch (e) {
                    webkit.messageHandlers.jswift.postMessage({
                        id: '\(id.uuidString)',
                        error: e.message || String(e)
                    });
                }
            })();
            """

            webView.evaluateJavaScript(wrapped) { _, error in
                if let error = error {
                    self.pending[id]?.resume(throwing: error)
                    self.pending.removeValue(forKey: id)
                }
            }
        }
    }

    func handle(id: UUID, value: Any?) {
        pending[id]?.resume(returning: value ?? NSNull())
        pending.removeValue(forKey: id)
    }

    func handle(id: UUID, error: String) {
        pending[id]?.resume(throwing: NSError(domain: "JSwift", code: -1,
                                              userInfo: [NSLocalizedDescriptionKey: error]))
        pending.removeValue(forKey: id)
    }
}

// MARK: - Message Handler

private class SwiftMessageHandler: NSObject, WKScriptMessageHandler {
    weak var engine: JSEngine?

    init(engine: JSEngine) {
        self.engine = engine
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let idStr = body["id"] as? String,
              let id = UUID(uuidString: idStr) else { return }

        if let err = body["error"] as? String {
            engine?.handle(id: id, error: err)
        } else {
            engine?.handle(id: id, value: body["value"])
        }
    }
}
