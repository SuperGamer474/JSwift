import WebKit
import Foundation

/// JSwift – run JavaScript with natural `returnToSwift value` syntax
/// Supports both synchronous and async/await!
public enum JSwift {
    private static let engine = JSEngine()
    
    // MARK: - Synchronous (blocks the thread until returnToSwift is called)
    public static func execute<T>(_ js: String) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        var result: T!
        var error: Error?
        
        engine.evaluate(js) { res in
            switch res {
            case .success(let value):
                result = value as? T ?? (value as! T) // force cast after type check
            case .failure(let err):
                error = err
            }
            semaphore.signal()
        }
        
        semaphore.wait()
        
        if let error = error {
            fatalError("JSwift JavaScript error: \(error.localizedDescription)")
        }
        return result
    }
    
    // MARK: - Async/Await (non-blocking, modern Swift)
    public static func executeAsync<T>(_ js: String) async -> T {
        await withCheckedContinuation { continuation in
            engine.evaluate(js) { result in
                switch result {
                case .success(let value):
                    if let value = value as? T {
                        continuation.resume(returning: value)
                    } else {
                        // Try JSON round-trip for complex objects
                        if let data = try? JSONSerialization.data(withJSONObject: value),
                           let decoded = try? JSONDecoder().decode(T.self, from: data) {
                            continuation.resume(returning: decoded)
                        } else {
                            continuation.resume(throwing: NSError(domain: "JSwift", code: 1,
                                                                  userInfo: [NSLocalizedDescriptionKey: "Type mismatch"]))
                        }
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - Shared Engine

private actor JSEngine {
    private let webView: WKWebView
    private var callbacks: [UUID: (Result<Any, Error>) -> Void] = [:]
    
    init() {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        
        let bridgeScript = """
        (function() {
            const send = (value) => {
                webkit.messageHandlers.jswift.postMessage({
                    id: window.__jswift_id,
                    value: value
                });
            };
            Object.defineProperty(window, 'returnToSwift', {
                set: send,
                get: () => { throw new Error('returnToSwift is write-only') },
                configurable: false
            });
        })();
        """
        
        controller.addUserScript(WKUserScript(source: bridgeScript,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: true))
        controller.add(SwiftMessageHandler(engine: self), name: "jswift")
        config.userContentController = controller
        
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.isHidden = true
        self.webView = wv
        wv.loadHTMLString("<html><body></body></html>", baseURL: nil)
    }
    
    func evaluate(_ js: String, completion: @escaping (Result<Any, Error>) -> Void) {
        let id = UUID()
        callbacks[id] = completion
        
        let wrappedJS = """
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
        
        webView.evaluateJavaScript(wrappedJS)
    }
    
    func handleMessage(id: UUID, value: Any?) {
        if let callback = callbacks.removeValue(forKey: id) {
            callback(.success(value ?? NSNull()))
        }
    }
    
    func handleError(id: UUID, message: String) {
        if let callback = callbacks.removeValue(forKey: id) {
            callback(.failure(NSError(domain: "JSwift", code: -1,
                                      userInfo: [NSLocalizedDescriptionKey: message])))
        }
    }
}

private class SwiftMessageHandler: NSObject, WKScriptMessageHandler {
    weak var engine: JSEngine?
    
    init(engine: JSEngine) {
        self.engine = engine
    }
    
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let idString = body["id"] as? String,
              let id = UUID(uuidString: idString) else { return }
        
        if let error = body["error"] as? String {
            engine?.handleError(id: id, message: error)
        } else if body["value"] != nil || body["error"] == nil {
            engine?.handleMessage(id: id, value: body["value"])
        }
    }
}
