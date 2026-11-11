# 懂片帝 iOS 壳 + 去广告

把 `https://dongpian17.com` 封装成原生 iOS App，并在三层同时清掉站内广告位。

- 目标站: `https://dongpian17.com/`
- Bundle ID: `com.dongpian.dpd`
- 显示名: 懂片帝
- 最低系统: iOS 14.0
- 产物: 未签名 `DongPianDi.ipa`

## 目录

```
DongPianDi/
├── project.yml                          XcodeGen 工程定义
├── .github/workflows/build-ipa.yml      GitHub Actions 云构建（免 Mac）
├── web/adblock.user.js                  浏览器版同逻辑脚本，用来快速验效果
├── scripts/
│   ├── build-ipa.sh                     macOS 本地构建
│   ├── verify-adblock.py                数据层验证
│   ├── verify-render.py                 渲染对比 + 截图
│   └── verify-layers.py                 三层逻辑逐条断言
└── DongPianDi/
    ├── AppDelegate.swift                @main，方向锁
    ├── SceneDelegate.swift              UIWindow 装配
    ├── WebViewController.swift          WKWebView 主体 + 导航白名单 + 进度条 + 错误页
    ├── AdBlockConfig.swift              读 AdSelectors.json → JS 字面量
    ├── AdInject.js                      去广告注入脚本（三层）
    ├── AdSelectors.json                 选择器与清理键，改规则只改这里
    ├── ContentRules.json                WKContentRuleList 网络层拦截
    ├── Info.plist                       Scene 清单、方向、ATS、深色状态栏
    ├── Base.lproj/LaunchScreen.storyboard
    └── Assets.xcassets/AppIcon.appiconset/icon-1024.png
```

## 构建

### 路径 A — GitHub Actions（Windows 上就能出 IPA）

已建好的仓库: https://github.com/qingyi123778/dongpiandi-ipa

代码改动后同步:

```bash
python scripts/api_push.py qingyi123778/dongpiandi-ipa ../.dpd_token .
```

或者有可用代理时用 git:

```bash
cd DongPianDi
git add . && git commit -m "update"
git push origin main
```

push 后 **Actions → Build unsigned IPA → Artifacts → DongPianDi-ipa**，下载解压得到 `DongPianDi.ipa`。
或者命令行直接拉:

```bash
TOK=$(cat ../.dpd_token)
ART=$(curl -s -H "Authorization: token $TOK" \
  "https://api.github.com/repos/qingyi123778/dongpiandi-ipa/actions/runs?per_page=1" \
  | python -c "import sys,json;print(json.load(sys.stdin)['workflow_runs'][0]['id'])")
curl -sL -H "Authorization: token $TOK" \
  "https://api.github.com/repos/qingyi123778/dongpiandi-ipa/actions/runs/$ART/artifacts" \
  | python -c "import sys,json;print(json.load(sys.stdin)['artifacts'][0]['archive_download_url'])"
```

### 三个必须避开的坑

1. **`runs-on: macos-14` 在本账号不可用**，报 `The configuration 'macos-14-arm64-us-default' is not supported`，run 2 秒内被 cancelled、不分配 runner。用 **`macos-15`**（实测 95 秒出包）。`macos-13` 已退役，会一直 queued。
2. **`xcodebuild` 结尾必须是 `archive`，不是 `build`**。`-archivePath` 只在 `archive` 动作下生效，写成 `build` 不会有 `.xcarchive`，`Package IPA` 步骤的 `test -d` 直接失败。
3. **本机 `git push` 走不通**（`CONNECT tunnel failed, response 502`，代理劫持 443）。`api.github.com` 正常，所以提交走 Contents API，见 `scripts/api_push.py`。

### 路径 B — 有 Mac

```bash
brew install xcodegen
cd DongPianDi
chmod +x scripts/build-ipa.sh
./scripts/build-ipa.sh
# 产物: build/DongPianDi.ipa
```

脚本做四步: `xcodegen generate` → `xcodebuild archive`（`CODE_SIGNING_ALLOWED=NO`）→ 拷进 `Payload/` → `zip -r` 改名 `.ipa`。

## 安装

未签名 IPA 必须自签才能装。

| 工具 | 平台 | 有效期 | 说明 |
|---|---|---|---|
| Sideloadly | Windows / macOS | 7 天 | 普通 Apple ID 自签，免费，到期重签 |
| AltStore | Windows / macOS | 7 天 | 同上，需要 AltServer 常驻 |
| TrollStore | iOS 14.0–17.0 | 永久 | 依赖 CoreTrust 漏洞，免签直接装 |
| 开发者证书 | 任意 | 1 年 | 付费账号 $99/年，可上 TestFlight |

Sideloadly 流程: 插上 iPhone → 拖入 IPA → 填 Apple ID → 输密码（走 App 专用密码）→ Start。
首次运行去 **设置 → 通用 → VPN与设备管理** 信任证书。

## 去广告做了什么

站点广告全部由 `/v1/runtime/bootstrap` 下发的 `app_experience.placements` 驱动。三个层次分别处理:

**L1 数据层（主力）** — `AdInject.js` 在 `atDocumentStart` 劫持 `window.fetch`，把 `/v1/` JSON 响应里所有 `placements.*` 的 `items` / `grid_items` / `banner_items` 清空，`enabled` / `search_enabled` / `calendar_enabled` 置 `false`。组件拿到空数组走 `if (!items.length) return null`，广告位根本不进 DOM。

覆盖的广告位:

| placement | 位置 | 组件 |
|---|---|---|
| `splash_screen` | 开屏全屏遮罩（240 分钟冷却 / 每日 3 次） | `aside.app-startup-ad` |
| `showcase_grid` | 搜索页 / 日历页「官方靠谱推荐」 | `aside.movie-content-grid-ad` |
| `player_info` | 播放器顶部网格 + 选集区翻转卡 | `section.movie-player-top-grid-ad` / `[data-ad-slot]` |
| `home_top_carousel` | 首页顶部轮播 | 首页组件 |

**L2 样式层（兜底）** — 注入 `display:none !important` 覆盖残留容器。选择器列表在 `AdSelectors.json` 的 `hideSelectors`。

**L3 行为层** —
- 开屏广告组件会执行 `document.body.style.overflow = 'hidden'` 锁滚动，`display:none` 拦不住那段 effect，必须监听 DOM 变更手动还原，否则整页滚不动。
- `window.open` 置为返回 `null`，配合原生 `createWebViewWith` 返回 `nil`，双击广告不会弹窗。
- 预置 `localStorage['movie-search:startup-ad-seen:v2']`，`dailyCount: 99`，绕开冷却判断。
- 导航白名单只放行 `dongpian17.com` 及子域，其余外链在 `decidePolicyFor` 里 `.cancel`，广告 `target_url`（如 `30868739.com`）点不出去。

**网络层** — `ContentRules.json` 编译成 `WKContentRuleList`，拦 `googletagmanager` / `doubleclick` / 30 个广告联盟域名。

**不去的东西** — `.react-player-ad-safety-notice`（平台自己的防骗滚动提示）保留，它不是广告。

## 实测

### 去广告（Chromium + Playwright，真实站点）

`python scripts/verify-layers.py`，2026-11-12:

```
[PASS] L1 广告条目清零  (36 -> 0)
[PASS] L2 广告容器隐藏  (display=none)
[PASS] L2 基线对照未隐藏  (display=block)
[PASS] L3a 滚动锁解除  (overflow=(empty))
[PASS] L3b window.open 拦截  ({'returnedNull': True})
[PASS] 页面主体未破坏  (cards 46 -> 46)
RESULT: ALL PASS
```

基线 `player_info` 有 12 条 `items` + 12 条 `grid_items`（共 24），`showcase_grid` 12 条，合计 36 条广告素材，注入后全部 0。

### 出包（GitHub Actions macos-15，run 43122644582）

```
Set up job                success
Checkout                  success
Install XcodeGen          success    xcodegen 2.46.0
Show toolchain            success
Generate Xcode project    success
Build archive (unsigned)  success
Package IPA               success
Upload artifact           success    963,140 bytes
```

产物:

```
文件   DongPianDi.ipa
大小   965,044 bytes (0.92 MB)
SHA256 3c0b212b88afcd589d4870a1aaeeb23e5a3fd119589063a75f125f772bf3ef28
架构   Mach-O arm64 (cputype 0x0100000C)  单个 slice，无 x86_64
SDK    iphoneos18.5 / Xcode 16.4
最低   MinimumOSVersion 14.0
Bundle com.dongpian.dpd / 显示名 懂片帝
载荷   DongPianDi 132,456 B · Assets.car 928,543 B · AdInject.js · AdSelectors.json · ContentRules.json · LaunchScreen.storyboardc
```

Info.plist 关键项已核对: `UIApplicationSceneManifest` ✓ `UISupportedInterfaceOrientations` ✓ `UIStatusBarStyle=LightContent` ✓ `UIUserInterfaceStyle=Dark` ✓ `UIDeviceFamily=[1,2]` ✓ `UIRequiredDeviceCapabilities=[arm64]` ✓

浏览器里想自己看: 装 Tampermonkey → 新建脚本 → 粘贴 `web/adblock.user.js` → 打开站点。

## 改配置

| 想改什么 | 改哪里 |
|---|---|
| 站点地址 | `WebViewController.swift` 的 `Cfg.homeURL` + `Cfg.allowedHosts` |
| Bundle ID | `project.yml` 的 `PRODUCT_BUNDLE_IDENTIFIER` |
| App 名称 | `Info.plist` 的 `CFBundleDisplayName` |
| 图标 | 替换 `AppIcon.appiconset/icon-1024.png`（1024×1024，无 alpha 通道） |
| 新增要隐藏的广告元素 | `AdSelectors.json` 的 `hideSelectors` |
| 新增要清零的字段名 | `AdSelectors.json` 的 `adListKeys` / `adBoolKeys` |
| 拦更多域名 | `ContentRules.json` 追加 `if-domain` |

改完 `hideSelectors` 不用动 Swift，重启 App 即生效。

## 边界

**片源内嵌贴片去不掉。** 播放走的是第三方线路解析出的直链（`resolve_mode: parse` 那批「普通线路」），广告已经烧进视频像素里。DOM 层和网络层都摸不到 `<video>` 内部。要去只能重新编码切片，那是另一件事。

**站点改版会失效。** `AdSelectors.json` 里的字段名跟着 `fs()` 校验逻辑走，站点把 `placements` 重命名或换接口路径就得同步更新。挂了的表现是开屏广告重新出现，届时抓一次 `/v1/runtime/bootstrap` 对比字段即可。

**未签名 IPA 不能上架、不能推送。** 自签 7 天到期要重签，App 内的登录态会随重装丢失（Cookie 存在 App 沙盒里）。
