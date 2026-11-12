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
        static let shellChannel = "dpdShell"
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

    /// 设置入口，可拖动，全屏时自动隐藏
    private let fab = UIButton(type: .system)
    private var fabLaidOut = false

    /// 播放器是否处于全屏（由网页侧 .art-video-player 的 class 驱动）
    private var playerFullscreen = false {
        didSet {
            guard playerFullscreen != oldValue else { return }
            setNeedsStatusBarAppearanceUpdate()
            setNeedsUpdateOfHomeIndicatorAutoHidden()
            applyOrientation(landscape: playerFullscreen)
            fab.isHidden = playerFullscreen
        }
    }

    private lazy var scriptBridge = ScriptBridge(target: self)

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Cfg.background
        buildWebView()
        buildProgressBar()
        buildErrorView()
        buildFab()
        installUserScripts()
        installContentRulesThenLoad()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !fabLaidOut, view.bounds.width > 0 else { return }
        fabLaidOut = true
        fab.frame = CGRect(x: view.bounds.width - 18 - 44,
                           y: view.bounds.height * 0.62,
                           width: 44, height: 44)
    }

    deinit {
        progressObservation?.invalidate()
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    // 播放器全屏时铺满，隐藏状态栏与小白条
    override var prefersStatusBarHidden: Bool { playerFullscreen }
    override var prefersHomeIndicatorAutoHidden: Bool { playerFullscreen }

    // 不用限制方向：限定死会导致全屏状态漏检时用户连手动转屏都做不到。
    // 让四个方向都可用，横屏靠 applyOrientation 主动请求。
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

        // ShellBridge.js 通过这个通道回传播放器全屏状态
        webView.configuration.userContentController.add(scriptBridge, name: Cfg.shellChannel)

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

    private func buildFab() {
        fab.frame = CGRect(x: view.bounds.width - 62, y: view.bounds.height * 0.62,
                           width: 44, height: 44)
        fab.backgroundColor = UIColor(white: 0.12, alpha: 0.62)
        fab.layer.cornerRadius = 22
        fab.layer.borderWidth = 1
        fab.layer.borderColor = Cfg.accent.withAlphaComponent(0.5).cgColor
        fab.tintColor = Cfg.accent
        let conf = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        fab.setImage(UIImage(systemName: "slider.horizontal.3", withConfiguration: conf), for: .normal)
        fab.addTarget(self, action: #selector(onFabTap), for: .touchUpInside)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(onFabPan(_:)))
        pan.delegate = self
        fab.addGestureRecognizer(pan)

        view.addSubview(fab)
    }

    @objc private func onFabTap() {
        showSettings()
    }

    @objc private func onFabPan(_ gesture: UIPanGestureRecognizer) {
        let delta = gesture.translation(in: view)
        fab.center = CGPoint(x: fab.center.x + delta.x, y: fab.center.y + delta.y)
        gesture.setTranslation(.zero, in: view)

        guard gesture.state == .ended || gesture.state == .cancelled else { return }
        let safe = view.safeAreaInsets
        let half: CGFloat = 22
        let minX = half + 8
        let maxX = view.bounds.width - half - 8
        let minY = safe.top + half + 8
        let maxY = view.bounds.height - safe.bottom - half - 8
        var center = fab.center
        center.x = min(max(center.x, minX), maxX)
        center.y = min(max(center.y, minY), maxY)
        UIView.animate(withDuration: 0.2) { self.fab.center = center }
    }

    // MARK: - 设置面板

    private func showSettings() {
        guard presentedViewController == nil else { return }
        let s = PlayerSettings.shared
        let sheet = UIAlertController(title: "播放设置", message: nil, preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: "长按倍速　\(s.rateLabel)", style: .default) { [weak self] _ in
            self?.pickRate()
        })
        sheet.addAction(UIAlertAction(title: "全屏自动横屏　\(s.autoRotate ? "开" : "关")",
                                      style: .default) { [weak self] _ in
            PlayerSettings.shared.autoRotate.toggle()
            self?.applySettingsToWeb()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))

        if let pop = sheet.popoverPresentationController {
            pop.sourceView = fab
            pop.sourceRect = fab.bounds
        }
        present(sheet, animated: true)
    }

    private func pickRate() {
        let s = PlayerSettings.shared
        let sheet = UIAlertController(title: "长按倍速",
                                      message: "按住播放区生效，松手还原。iOS 上超过 2x 可能没有声音。",
                                      preferredStyle: .actionSheet)
        for rate in [0.0, 1.5, 2.0, 2.5, 3.0] {
            let title = rate == 0 ? "关闭" : String(format: "%.1fx", rate)
            let mark = abs(s.longPressRate - rate) < 0.001 ? "　✓" : ""
            sheet.addAction(UIAlertAction(title: title + mark, style: .default) { [weak self] _ in
                PlayerSettings.shared.longPressRate = rate
                self?.applySettingsToWeb()
            })
        }
        sheet.addAction(UIAlertAction(title: "返回", style: .cancel) { [weak self] _ in
            self?.showSettings()
        })
        if let pop = sheet.popoverPresentationController {
            pop.sourceView = fab
            pop.sourceRect = fab.bounds
        }
        present(sheet, animated: true)
    }

    private func applySettingsToWeb() {
        let json = PlayerSettings.shared.json
        webView.evaluateJavaScript("window.__DPD_APPLY_SETTINGS__ && window.__DPD_APPLY_SETTINGS__(\(json));")
    }

    private func installUserScripts() {
        // 去广告脚本
        if let url = Bundle.main.url(forResource: "AdInject", withExtension: "js"),
           let body = try? String(contentsOf: url, encoding: .utf8) {
            // 配置拼在脚本前，AdInject.js 从 window.__DPD_CONFIG__ 取
            let source = "window.__DPD_CONFIG__ = \(AdBlockConfig.shared.injectConfigJSON);\n" + body
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            )
        }

        // 全屏状态桥 + 长按倍速，配置拼在脚本前
        if let url = Bundle.main.url(forResource: "ShellBridge", withExtension: "js"),
           let body = try? String(contentsOf: url, encoding: .utf8) {
            let source = "window.__DPD_SETTINGS__ = \(PlayerSettings.shared.json);\n" + body
            webView.configuration.userContentController.addUserScript(
                WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }
    }

    // MARK: - 屏幕方向

    fileprivate func handleShellMessage(_ body: [String: Any]) {
        guard let type = body["type"] as? String, type == "fullscreen",
              let on = body["value"] as? Bool else { return }
        if Thread.isMainThread {
            playerFullscreen = on
        } else {
            DispatchQueue.main.async { [weak self] in self?.playerFullscreen = on }
        }
    }

    /// 网页全屏只是 CSS 铺满，不会让系统转屏，这里由 App 主动转
    private func applyOrientation(landscape: Bool) {
        let mask: UIInterfaceOrientationMask = landscape ? .landscape : .portrait

        if #available(iOS 16.0, *) {
            setNeedsUpdateOfSupportedInterfaceOrientations()
            guard let scene = view.window?.windowScene else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                // 用户开了竖屏锁定、或处于 iPad 分屏时这里会失败，退回老接口再试一次
                NSLog("[DPD] geometry update failed: \(error)")
                DispatchQueue.main.async {
                    let target: UIInterfaceOrientation = landscape ? .landscapeRight : .portrait
                    UIDevice.current.setValue(target.rawValue, forKey: "orientation")
                    UIViewController.attemptRotationToDeviceOrientation()
                }
            }
        } else {
            let target: UIInterfaceOrientation = landscape ? .landscapeRight : .portrait
            UIDevice.current.setValue(target.rawValue, forKey: "orientation")
            UIViewController.attemptRotationToDeviceOrientation()
        }
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

// MARK: - 手势

extension WebViewController: UIGestureRecognizerDelegate {

    /// 位移太小当作点击，交给 button 的 touchUpInside
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: view)
        return abs(v.x) > 80 || abs(v.y) > 80
    }
}

// MARK: - JS → 原生

/// 弱引用转发，避免 userContentController 强持有 VC 造成循环引用
private final class ScriptBridge: NSObject, WKScriptMessageHandler {

    weak var target: WebViewController?

    init(target: WebViewController) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        target?.handleShellMessage(body)
    }
}
