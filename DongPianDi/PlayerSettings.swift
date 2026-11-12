import Foundation

/// 播放行为配置，落 UserDefaults，改动后即时下发给网页。
final class PlayerSettings {

    static let shared = PlayerSettings()

    private enum Key {
        static let longPressRate = "dpd.longPressRate"
        static let autoRotate = "dpd.autoRotateFullscreen"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.longPressRate: 2.0,
            Key.autoRotate: true
        ])
    }

    /// 长按播放倍率，0 表示关闭该手势
    var longPressRate: Double {
        get { defaults.double(forKey: Key.longPressRate) }
        set { defaults.set(newValue, forKey: Key.longPressRate) }
    }

    /// 网页全屏时是否让 App 主动转横屏
    var autoRotate: Bool {
        get { defaults.bool(forKey: Key.autoRotate) }
        set { defaults.set(newValue, forKey: Key.autoRotate) }
    }

    var rateLabel: String {
        let r = longPressRate
        return r > 0 ? String(format: "%.1fx", r) : "已关闭"
    }

    /// 一次性下发给网页的 JSON
    var json: String {
        let payload: [String: Any] = [
            "longPressRate": longPressRate,
            "autoRotate": autoRotate
        ]
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{\"longPressRate\":2,\"autoRotate\":true}"
        }
        return text
    }
}
