import UIKit
import WebKit

/// 单页壳：WKWebView 承载 dongpian17.com，启动前装好去广告注入与内容规则。
final class WebViewController: UIViewController {

    // MARK: - 参数

    private enum Cfg {
        static let homeURL = URL(string: "https://dongpian17.com/")!
        // 主域白名单，子域自动放行；其余导航一律丢弃
        static let allowedHosts: Set<String> = ["dongpian17.com"]
        static let accent = UIColor(red: 1.00, green: 0.812, blue: 0.196, alpha: 1.0)
        static let background = UIColor(red: 0.051, green: 0.055, blue: 0.063, alpha: 1.0)
        static let progressHeight: CGFloat = 2.0
        static let ruleListID = "dpd-adblock-v3"
    }

    // MARK: - 视图

    private var webView: WKWebView!
    private let progressBar = UIView()
    private var progressWidth: NSLayoutConstraint!
    private let refresh = UIRefreshControl()
    private let errorView = UIView()
    private let errorLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private var progressObservation: NSKeyValueObservation?

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Cfg.background
        buildWebView()
        buildProgressBar()
        buildErrorView()
        installUserScripts()
        installContentRulesThenLoad()
    }

    deinit {
        progressObservation?.invalidate()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        .allButUpsideDown
    }


    // MARK: - 组装

    private func buildWebView() {
        let conf = WKWebViewConfiguration()
        conf.allowsInlineMediaPlayback = true
        conf.mediaTypesRequiringUserActionForPlayback = []
        conf.websiteDataStore = .default()
        conf.preferences.javaScriptCanOpenWindowsAutomatically = false
        if #available(iOS 15.4, *) {
            conf.preferences.isElementFullscreenEnabled = true
        }
        // 追加自有标识，站点只识别 AIMovieAndroid 前缀，不会误判成原生壳而走 App 分支
        conf.applicationNameForUserAgent = "DongPianDiShell/1.0"

        webView = WKWebView(frame: .zero, configuration: conf)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.backgroundColor = Cfg.background
        webView.isOpaque = false
        webView.backgroundColor = Cfg.background
        webView.scrollView.refreshControl = refresh

        refresh.tintColor = Cfg.accent
        refresh.addTarget(self, action: #selector(onPullRefresh), for: .valueChanged)

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            self?.applyProgress(CGFloat(wv.estimatedProgress))
        }
    }

    private func buildProgressBar() {
        progressBar.backgroundColor = Cfg.accent
        progressBar.alpha = 0
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressBar)
        progressWidth = progressBar.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            progressBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            progressBar.heightAnchor.constraint(equalToConstant: Cfg.progressHeight),
            progressWidth
        ])
    }

    private func buildErrorView() {
        errorView.translatesAutoresizingMaskIntoConstraints = false
        errorView.backgroundColor = Cfg.background
        errorView.isHidden = true

        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        errorLabel.textColor = UIColor(white: 0.72, alpha: 1)
        errorLabel.font = .systemFont(ofSize: 15, weight: .medium)
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 0
        errorLabel.text = "页面加载失败\n检查网络后重试"

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.setTitle("重新加载", for: .normal)
        retryButton.setTitleColor(Cfg.accent, for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        retryButton.addTarget(self, action: #selector(onRetry), for: .touchUpInside)

        errorView.addSubview(errorLabel)
        errorView.addSubview(retryButton)
        view.addSubview(errorView)

        NSLayoutConstraint.activate([
            errorView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            errorView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            errorView.topAnchor.constraint(equalTo: view.topAnchor),
            errorView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            errorLabel.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            errorLabel.centerYAnchor.constraint(equalTo: errorView.centerYAnchor, constant: -24),
            errorLabel.leadingAnchor.constraint(greaterThanOrEqualTo: errorView.leadingAnchor, constant: 32),

            retryButton.centerXAnchor.constraint(equalTo: errorView.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 18)
        ])
    }

    // MARK: - 注入

    private func installUserScripts() {
        guard
            let url = Bundle.main.url(forResource: "AdInject", withExtension: "js"),
            let body = try? String(contentsOf: url, encoding: .utf8)
        else {
            return
        }
        // 配置拼在脚本前，AdInject.js 从 window.__DPD_CONFIG__ 取
        let source = "window.__DPD_CONFIG__ = \(AdBlockConfig.shared.injectConfigJSON);\n" + body
        let script = WKUserScript(source: source,
                                  injectionTime: .atDocumentStart,
                                  forMainFrameOnly: false)
        webView.configuration.userContentController.addUserScript(script)
    }

    private func installContentRulesThenLoad() {
        guard
            let url = Bundle.main.url(forResource: "ContentRules", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let json = String(data: data, encoding: .utf8)
        else {
            loadHome()
            return
        }

        guard let store = WKContentRuleListStore.default() else {
            loadHome()
            return
        }
        store.compileContentRuleList(forIdentifier: Cfg.ruleListID, encodedContentRuleList: json) { [weak self] list, error in
            guard let self = self else { return }
            DispatchQueue.main.async {
                if let list = list {
                    self.webView.configuration.userContentController.add(list)
                } else if let error = error {
                    // 编译失败不阻断启动，只是少了网络层拦截
                    NSLog("[DPD] content rule list failed: \(error.localizedDescription)")
                }
                self.loadHome()
            }
        }
    }

    // MARK: - 加载

    private func loadHome() {
        guard webView.url == nil else { return }
        errorView.isHidden = true
        webView.load(URLRequest(url: Cfg.homeURL,
                                cachePolicy: .useProtocolCachePolicy,
                                timeoutInterval: 25))
    }

    @objc private func onRetry() {
        errorView.isHidden = true
        let target = webView.url ?? Cfg.homeURL
        webView.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25))
    }

    @objc private func onPullRefresh() {
        webView.reload()
    }

    private func applyProgress(_ value: CGFloat) {
        let clamped = max(0, min(1, value))
        let target = view.bounds.width * clamped

        if clamped >= 1 {
            progressWidth.constant = target
            UIView.animate(withDuration: 0.18, animations: {
                self.progressBar.alpha = 0
                self.view.layoutIfNeeded()
            }, completion: { _ in
                self.progressWidth.constant = 0
                self.view.layoutIfNeeded()
            })
        } else {
            progressBar.alpha = 1
            progressWidth.constant = target
            UIView.animate(withDuration: 0.12) {
                self.view.layoutIfNeeded()
            }
        }
    }

    // MARK: - 导航判定

    private func isAllowed(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if Cfg.allowedHosts.contains(host) { return true }
        for base in Cfg.allowedHosts where host.hasSuffix("." + base) {
            return true
        }
        return false
    }
}

// MARK: - WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {

        guard let url = navigationAction.request.url else {
            decisionHandler(.cancel)
            return
        }

        let scheme = (url.scheme ?? "").lowercased()
        // about/data/blob 是 WKWebView 内部页面，放行
        if scheme == "about" || scheme == "data" || scheme == "blob" {
            decisionHandler(.allow)
            return
        }
        // itms-apps / tel / mailto / 自定义 scheme 一律丢弃（App Store 跳转与广告唤起都走这里）
        if scheme != "http" && scheme != "https" {
            decisionHandler(.cancel)
            return
        }
        if isAllowed(url) {
            decisionHandler(.allow)
            return
        }

        // 非白名单外链：广告 target_url 落点。丢弃，不进浏览器。
        NSLog("[DPD] blocked navigation: \(url.absoluteString)")
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refresh.endRefreshing()
        errorView.isHidden = true
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        refresh.endRefreshing()
        handleLoadFailure(error)
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        refresh.endRefreshing()
        handleLoadFailure(error)
    }

    private func handleLoadFailure(_ error: Error) {
        let ns = error as NSError
        // -999 是主动取消（重定向/并发请求打断），不弹错误页
        if ns.code == NSURLErrorCancelled { return }
        if webView.url == nil {
            errorView.isHidden = false
        } else {
            let toast = UILabel()
            toast.text = " 网络异常 "
            toast.font = .systemFont(ofSize: 13, weight: .medium)
            toast.textColor = .white
            toast.backgroundColor = UIColor(white: 0.18, alpha: 0.95)
            toast.layer.cornerRadius = 12
            toast.clipsToBounds = true
            toast.sizeToFit()
            toast.frame.size.width += 24
            toast.frame.size.height += 12
            toast.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            toast.alpha = 0
            view.addSubview(toast)
            UIView.animate(withDuration: 0.2, animations: { toast.alpha = 1 }) { _ in
                UIView.animate(withDuration: 0.3, delay: 1.2, animations: { toast.alpha = 0 }) { _ in
                    toast.removeFromSuperview()
                }
            }
        }
    }
}

// MARK: - WKUIDelegate

extension WebViewController: WKUIDelegate {

    /// target=_blank / window.open 的落点，直接拒绝，不产生新窗口
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        return nil
    }

    /// 长按链接预览也走白名单，避免预览面板加载广告页
    func webView(_ webView: WKWebView,
                 contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL, isAllowed(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let open = UIAction(title: "打开") { _ in
                webView.load(URLRequest(url: url))
            }
            return UIMenu(title: "", children: [open])
        })
    }
}
