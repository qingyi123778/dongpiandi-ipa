import Foundation

/// 从 AdSelectors.json 读取去广告配置，序列化成 JS 字面量供 AdInject.js 消费。
/// 加选择器时只改 JSON，不动 Swift。
final class AdBlockConfig {

    static let shared = AdBlockConfig()

    private let raw: [String: Any]

    private init() {
        guard
            let url = Bundle.main.url(forResource: "AdSelectors", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            raw = [:]
            return
        }
        raw = obj
    }

    var hideSelectors: [String] { raw["hideSelectors"] as? [String] ?? [] }
    var adListKeys: [String] { raw["adListKeys"] as? [String] ?? ["items", "grid_items", "banner_items"] }
    var adBoolKeys: [String] { raw["adBoolKeys"] as? [String] ?? ["enabled", "search_enabled", "calendar_enabled"] }
    var adZeroKeys: [String] { raw["adZeroKeys"] as? [String] ?? ["daily_impression_limit"] }
    var scrubMaxDepth: Int { raw["scrubMaxDepth"] as? Int ?? 6 }
    var apiPathMark: String { raw["apiPathMark"] as? String ?? "/v1/" }
    var scrollHostSelector: String { raw["scrollHostSelector"] as? String ?? "aside.app-startup-ad" }
    var prefillStartupAdKey: String { raw["prefillStartupAdKey"] as? String ?? "movie-search:startup-ad-seen:v2" }
    var blockWindowOpen: Bool { raw["blockWindowOpen"] as? Bool ?? true }

    /// JS 侧需要的字段，不含 target 之类的元数据
    private var payload: [String: Any] {
        [
            "hideSelectors": hideSelectors,
            "adListKeys": adListKeys,
            "adBoolKeys": adBoolKeys,
            "adZeroKeys": adZeroKeys,
            "scrubMaxDepth": scrubMaxDepth,
            "apiPathMark": apiPathMark,
            "scrollHostSelector": scrollHostSelector,
            "prefillStartupAdKey": prefillStartupAdKey,
            "blockWindowOpen": blockWindowOpen
        ]
    }

    /// 序列化成 JS 对象字面量，非法时退化为 {}
    var injectConfigJSON: String {
        guard
            JSONSerialization.isValidJSONObject(payload),
            let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
            let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }
}
