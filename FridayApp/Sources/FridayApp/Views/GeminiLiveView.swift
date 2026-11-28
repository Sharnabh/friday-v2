import FridayCore
import SwiftUI
import WebKit

struct GeminiLiveView: NSViewRepresentable {
    let account: CloudAccount
    var autoStart=false
    let modelID:String
    let insert: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(account: account, insert: insert) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addScriptMessageHandler(context.coordinator, contentWorld: .page, name: "live")
        let web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = context.coordinator
        let source = Bundle.main.url(forResource: "gemini-live", withExtension: "js") ?? GeminiLiveResource.url
        guard let source, let script = try? String(contentsOf: source, encoding: .utf8) else {
            web.loadHTMLString("Gemini Live resources are unavailable.", baseURL: nil)
            return web
        }
        web.loadHTMLString("""
        <meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src wss://generativelanguage.googleapis.com">
        <style>:root{color-scheme:light dark;font:15px system-ui}body{padding:20px}main{display:grid;gap:10px}button,select,input,textarea{font:inherit;padding:8px;border-radius:8px}[hidden]{display:none}</style>
        <main id="panel"></main><script>\(script)
        const call=(action,data)=>webkit.messageHandlers.live.postMessage({action,data});
        mountGeminiLive(document.querySelector('main'),call,text=>call('draft',{text}),undefined,{modelID:\(String(decoding:(try? JSONEncoder().encode(modelID)) ?? Data(),as:UTF8.self)),autoStart:\(autoStart ? "true" : "false")});
        </script>
        """, baseURL: URL(string:"https://friday.local"))
        return web
    }
    func updateNSView(_ view: WKWebView, context: Context) {}
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.evaluateJavaScript("document.querySelector('main')?.fridayClose?.()")
        view.configuration.userContentController.removeScriptMessageHandler(forName:"live",contentWorld:.page)
        view.loadHTMLString("",baseURL:nil)
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandlerWithReply, WKUIDelegate {
        let account: CloudAccount
        let insert: (String) -> Void
        var target: [String: String]
        let identity: String
        init(account: CloudAccount, insert: @escaping (String) -> Void) {
            self.account=account; self.insert=insert; identity=account.token
            target=["bot":account.snapshot["bot"] as? String ?? "", "session":account.snapshot["session"] as? String ?? ""]
        }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping @MainActor (Any?, String?) -> Void) {
            guard message.frameInfo.isMainFrame, account.token == identity, !identity.isEmpty, let body=message.body as? [String:Any], let action=body["action"] as? String, let data=body["data"] as? [String:Any] else { replyHandler(nil,"Session unavailable.");return }
            if action=="draft", let text=data["text"] as? String {insert(text);replyHandler(true,nil);return}
            guard ["liveModels","liveToken","liveTurn","liveTasks"].contains(action) else {replyHandler(nil,"Unknown action.");return}
            Task {
                do {
                    if action=="liveModels",target["session"]?.isEmpty != false {
                        let snapshot=try await account.liveRequest("state",[:],[:])
                        target=["bot":snapshot["bot"] as? String ?? "", "session":snapshot["session"] as? String ?? ""]
                    }
                    let result=try await account.liveRequest(action,data,target);replyHandler(result,nil)
                }
                catch {replyHandler(nil,error.localizedDescription)}
            }
        }
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
            decisionHandler(frame.isMainFrame && origin.host=="friday.local" && type == .microphone ? .prompt : .deny)
        }
    }
}
