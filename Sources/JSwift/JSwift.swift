// Sources/JSwift/JSwift.swift
import WebKit
import Foundation

/// JSwift – sync + async JavaScript execution with natural `returnToSwift value` syntax
public enum JSwift {
    private static let engine = JSEngine()

    // MARK: - Synchronous (blocks until returnToSwift is called)
    public static func execute<T>(_ js: String) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T!
        var thrownError: Error?

        // Use Task + await to safely hop into the actor
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
        
        // If it's already the right type, return it
        if let value = value as? T {
            return value
        }
        
        // Otherwise, try JSON round-trip (for objects/arrays)
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Actor Engine

private actor JSEngine {
    private let webView: WKWebView
    private var pending: [UUID: CheckedContinuation<Any, Error>] = [:]

    init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()

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

        controller.addUserScript(WKUserScript(source: bridge,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        controller.add(SwiftMessageHandler(engine: self), name: "jswift")
        config.userContentController = controller

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isHidden = true
        self.webView = wv
        wv.loadHTMLString("<script> </script>", baseURL: nil)
    }

    func evaluate(_ js: String) async throws -> Any {
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            pending[id] = continuation

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

        if let error = body["error"] as? String {
            engine?.handle(id: id, error: error)
        } else {
            engine?.handle(id: id, value: body["value"])
        }
    }
}
