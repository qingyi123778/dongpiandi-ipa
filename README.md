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

## 全屏与横屏

站点播放器是 **ArtPlayer**，点全屏只做 CSS 层的事:

| class | 含义 | iOS 表现 |
|---|---|---|
| `art-fullscreen-web` | 网页全屏，容器 `position:fixed` 铺满视口 | 铺满了，但系统不转屏、状态栏还在 |
| `art-fullscreen` | 系统级 Fullscreen API | iOS Safari 不支持 `Element.requestFullscreen`，走不到 |

所以纯 WKWebView 壳会出现「点了全屏，画面占满但还竖着」——这不是 App 没做旋转支持，是网页本身就没请求转屏。

修法是把全屏状态交给原生处理:

1. `ShellBridge.js` 用 MutationObserver 盯 `.art-video-player` 的 class，命中 `art-fullscreen-web` / `art-fullscreen` 就通过 `window.webkit.messageHandlers.dpdShell` 上报
2. `WebViewController` 收到后置 `playerFullscreen`，`didSet` 里调 `requestGeometryUpdate(.iOS(interfaceOrientations: .landscape))` 主动转横屏
3. 同时 `prefersStatusBarHidden` / `prefersHomeIndicatorAutoHidden` 返回 true，藏掉状态栏和小白条
4. 退出全屏 class 移除 → 转回竖屏

保留站点自己的播放器 UI（弹幕、选集、倍速、投屏都还在），只补系统层行为。

实测（真实播放页 `/player/av_OysjC...`，注入桥接 + 手动切换 class）:

```
A 初始              [{type: fullscreen, value: false}]
B 加 art-fullscreen-web  [..., {value: true}]     ← 进入全屏，已上报
C 移除              [..., {value: false}]         ← 退出全屏，已上报
D 加 art-fullscreen      [..., {value: true}]
```

**已知限制** — 开着系统「竖屏锁定」时 `requestGeometryUpdate` 会失败（系统策略，任何 App 都绕不过），此时 App 只能走 `UIDevice.setValue` 老接口，成功率不保证。看片前把控制中心的竖屏锁关掉。

`supportedInterfaceOrientations` 故意保持 `.allButUpsideDown` 不做限制：万一站点改类名导致全屏状态漏检，用户至少还能手动转屏，不会彻底锁死。

## 长按倍速

全屏和竖屏都生效。按住播放区 420ms 进入加速，松手回到**原速率**（不是固定 1.0，你如果自己在站点里设过 1.5x 常速，松手还是 1.5x）。

改动落在 `ShellBridge.js`：

```js
document.addEventListener('touchstart', onTouchStart, { passive: true });
// 420ms 后 video.playbackRate = settings.longPressRate
// 移动超过 12px 视为滑动手势，取消
// touchend / touchcancel 恢复 s.before
```

**不触发长按的区域**：进度条、音量条、设置面板、按钮、链接。注意**不能**把 `.art-controls` 整个排除——全屏时它是铺满整屏的容器，一并排掉的话全屏状态下永远触发不了。

加速时屏幕上方弹一个角标 `2.0x 倍速播放中`，松手消失。

### 设置入口

在站点自己的「我的」页面里，`设置` 那一行下面插一行 `播放设置`，用同一套 `dpd-me-service-row` 样式，图标换成 sliders、右侧 chevron 照抄，视觉上和原生列表项一致。

```js
// ShellBridge.js
document.querySelector('.dpd-me-service-list')
  .querySelectorAll('.dpd-me-service-row')  // 找到文字含「设置」的那行
  .insertAdjacentElement('afterend', btn)   // 插在它后面
```

点这行 → `postMessage({type:'openSettings'})` → 原生弹 `UIAlertController`：

- **长按倍速** — 关闭 / 1.5x / 2.0x / 2.5x / 3.0x，当前项带 ✓
- **全屏自动横屏** — 关掉后全屏不再转横屏

配置存 `UserDefaults`（`PlayerSettings.swift`），改完立刻通过 `window.__DPD_APPLY_SETTINGS__()` 下发，不用刷新。

React 重渲染会把插入的节点冲掉，所以有 500ms 轮询复查（`injectSettingsRow` 里先判断是否已存在，不会重复插）。

**iOS 上超过 2x 会被系统静音**，这是 AVPlayer 的行为，`playbackRate` 设得上去但没声音。

### 卡顿处理

第一版长按和松手各卡一下，三个原因叠在一起：

1. **角标是运行时 `appendChild` 进去的** — 全屏是 `position:fixed` 铺满布局，中途插入节点触发整页重排。改成页面加载时预创建，只切 `opacity`，元素本身带 `will-change:opacity` + `contain:layout style` 提前进合成层。
2. **`preservesPitch` 在进和出时各改一次** — WebKit 要重建音频 time-pitch 管线，两个方向都卡。改成常驻 `false`（`v.preservesPitch = false` + `v.webkitPreservesPitch = false`），只在拿到 video 元素时设一次。代价是加速时声音变调，但 2x 下不明显。
3. **`playbackRate` 赋值和站点的 `ratechange` 渲染撞在同一帧** — 赋值包进 `requestAnimationFrame`，让站点的重渲染先跑完。

实测（真实播放页，播放中 + 模拟全屏）:

```
preservesPitch 属性存在 : true（可写）
角标已预建              : true
长按中 rate=2  opacity=1
松手后 rate=1  opacity=0
角标 top                : calc(env(safe-area-inset-top, 0px) + 26px)
```

角标从 `top:18%` 改到固定 26px + 安全区，不再贴近画面中线；横屏时由 `env(safe-area-inset-top)` 避开刘海。

### 一个必须避开的坑

`atDocumentStart` 阶段 `document.documentElement` 可能还是 `null`，`appendChild` 会抛异常。异常一抛，IIFE 后半段的赋值全部跳过——表现为「设置改了没反应」，而且页面其他功能完全正常，极难定位。

所以 `__DPD_APPLY_SETTINGS__` 的赋值放在 IIFE 最前面（`__DPD_SHELL__ = 1` 之后立刻挂），后续所有 DOM 操作包 try。这个 bug 第一次构建就踩了，验证脚本报 `__DPD_APPLY_SETTINGS__ is not a function` 才抓到。

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
