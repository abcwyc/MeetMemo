import SwiftUI
import WebKit

struct DiagramWebView: NSViewRepresentable {
    let htmlContent: String
    @Binding var contentHeight: CGFloat

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(wrappedHTML, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        var parent: DiagramWebView

        init(_ parent: DiagramWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { result, _ in
                if let height = result as? CGFloat, height > 0 {
                    DispatchQueue.main.async {
                        self.parent.contentHeight = height + 16
                    }
                }
            }
        }
    }

    private var wrappedHTML: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta name='viewport' content='width=device-width, initial-scale=1'>
        <style>
        :root {
          --bg: #F7F6F3;
          --bg-card: #FFFFFF;
          --bg-secondary: #F1F0ED;
          --bg-info: #E6F1FB;
          --bg-success: #EAF3DE;
          --bg-warning: #FAEEDA;
          --bg-danger: #FCEBEB;
          --bg-purple: #EEEDFE;
          --text: #1A1A18;
          --text-secondary: #5F5E5A;
          --text-muted: #888780;
          --text-info: #185FA5;
          --text-success: #3B6D11;
          --text-warning: #633806;
          --text-danger: #791F1F;
          --text-purple: #26215C;
          --border: rgba(0,0,0,0.10);
          --border-info: #B5D4F4;
          --border-success: #C0DD97;
          --border-warning: #FAC775;
          --border-danger: #F7C1C1;
          --border-purple: #CECBF6;
          --radius: 8px;
          --radius-sm: 6px;
        }
        @media (prefers-color-scheme: dark) {
          :root {
            --bg: #1C1C1A;
            --bg-card: #242422;
            --bg-secondary: #2C2C2A;
            --bg-info: #0C2D4A;
            --bg-success: #17340A;
            --bg-warning: #412402;
            --bg-danger: #2D0A0A;
            --bg-purple: #1A1929;
            --text: #EEECEA;
            --text-secondary: #A8A7A3;
            --text-muted: #6A6966;
            --text-info: #85B7EB;
            --text-success: #97C459;
            --text-warning: #EF9F27;
            --text-danger: #F09595;
            --text-purple: #B8B3F5;
            --border: rgba(255,255,255,0.10);
            --border-info: #185FA5;
            --border-success: #3B6D11;
            --border-warning: #854F0B;
            --border-danger: #A32D2D;
            --border-purple: #3D3A7A;
          }
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          padding: 8px;
          font-family: 'PingFang SC', 'Hiragino Sans GB', -apple-system, 'Helvetica Neue', sans-serif;
          font-size: 13px;
          line-height: 1.6;
          color: var(--text);
          background: transparent;
        }
        /* Cards */
        .card {
          background: var(--bg-card);
          border: 0.5px solid var(--border);
          border-radius: var(--radius);
          padding: 12px 16px;
        }
        /* Badges */
        .badge {
          display: inline-block;
          font-size: 11px;
          padding: 2px 8px;
          border-radius: 4px;
          font-weight: 500;
          line-height: 1.6;
        }
        .badge-info    { background: var(--bg-info);    color: var(--text-info);    border: 0.5px solid var(--border-info); }
        .badge-success { background: var(--bg-success); color: var(--text-success); border: 0.5px solid var(--border-success); }
        .badge-warning { background: var(--bg-warning); color: var(--text-warning); border: 0.5px solid var(--border-warning); }
        .badge-danger  { background: var(--bg-danger);  color: var(--text-danger);  border: 0.5px solid var(--border-danger); }
        .badge-purple  { background: var(--bg-purple);  color: var(--text-purple);  border: 0.5px solid var(--border-purple); }
        /* Timeline */
        .timeline { display: flex; flex-direction: column; gap: 0; }
        .timeline-item { display: flex; gap: 12px; padding-bottom: 16px; position: relative; }
        .timeline-item:not(:last-child)::before {
          content: '';
          position: absolute;
          left: 4px; top: 14px; bottom: 0;
          width: 1px; background: var(--border);
        }
        .timeline-dot { width: 10px; height: 10px; border-radius: 50%; margin-top: 4px; flex-shrink: 0; }
        .dot-green { background: #639922; }
        .dot-amber { background: #BA7517; }
        .dot-red   { background: #E24B4A; }
        .dot-blue  { background: #378ADD; }
        /* Flow */
        .flow { display: flex; flex-direction: column; gap: 4px; }
        .flow-node {
          background: var(--bg-info); color: var(--text-info);
          border: 0.5px solid var(--border-info);
          border-radius: var(--radius); padding: 8px 12px;
          font-size: 12px; text-align: center;
        }
        .flow-arrow { text-align: center; color: var(--text-muted); font-size: 14px; line-height: 1.2; }
        /* Grids */
        .grid-2    { display: grid; grid-template-columns: repeat(2, 1fr); gap: 8px; }
        .grid-3    { display: grid; grid-template-columns: repeat(3, 1fr); gap: 8px; }
        .grid-auto { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 8px; }
        /* Section label */
        .label {
          font-size: 11px; font-weight: 500; letter-spacing: 0.06em;
          text-transform: uppercase; color: var(--text-muted); margin-bottom: 8px;
        }
        /* Table */
        table { border-collapse: collapse; width: 100%; font-size: 12px; }
        th {
          background: var(--bg-secondary); color: var(--text-secondary);
          font-size: 11px; font-weight: 500; padding: 6px 10px;
          text-align: left; border-bottom: 0.5px solid var(--border);
        }
        td { padding: 8px 10px; border-bottom: 0.5px solid var(--border); color: var(--text); vertical-align: top; }
        tr:last-child td { border-bottom: none; }
        </style>
        </head>
        <body>\(htmlContent)</body>
        </html>
        """
    }
}
