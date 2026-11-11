/*
 * DongPianDi WebView — 广告清洗注入脚本
 * 注入点: WKUserScript .atDocumentStart / forMainFrameOnly:false
 * 依赖: window.__DPD_CONFIG__（原生层由 AdSelectors.json 序列化后拼在本文件之前）
 *
 * 三层清理:
 *   L1 数据层 — patch window.fetch，把 /v1/ 响应里的 placements.*.items 全部清空
 *   L2 样式层 — 注入 display:none 兜住残留容器
 *   L3 行为层 — 解锁开屏广告挂载后遗留的 body overflow 锁、拦截 window.open
 *
 * 成本: L1 只处理 content-type 含 json 且 URL 含 /v1/ 的响应，一次 JSON.parse
 *       + 递归 ≤6 层，单响应 O(n)。L2/L3 走 requestAnimationFrame 合并。
 */
(function () {
  'use strict';

  var W = window;
  if (W.__DPD_ADBLOCK__) { return; }
  W.__DPD_ADBLOCK__ = 1;

  var CFG = W.__DPD_CONFIG__ || {};

  var AD_LIST_KEYS = CFG.adListKeys || ['items', 'grid_items', 'banner_items'];
  var AD_BOOL_KEYS = CFG.adBoolKeys || ['enabled', 'search_enabled', 'calendar_enabled'];
  var AD_ZERO_KEYS = CFG.adZeroKeys || ['daily_impression_limit'];
  var HIDE_SELECTORS = CFG.hideSelectors || [];
  var SCROLL_HOST = CFG.scrollHostSelector || 'aside.app-startup-ad';
  var PREFILL_KEY = CFG.prefillStartupAdKey || 'movie-search:startup-ad-seen:v2';
  var MAX_DEPTH = CFG.scrubMaxDepth || 6;
  var STYLE_ID = 'dpd-adblock-style';
  var API_MARK = CFG.apiPathMark || '/v1/';

  /* ------------------------------------------------------------------ */
  /* L1  数据层: 清空 placements 里的广告条目                              */
  /* ------------------------------------------------------------------ */

  // 只动"开关"和"清单"，不动结构字段（layout / presentation_mode 等）。
  // 站点侧 fs() 对 placements 做结构校验，缺字段会导致整份体验配置被丢弃，
  // 那会连正常推荐位一起消失，所以这里做增量清空而不是重建对象。
  function scrubPlacement(p) {
    if (!p || typeof p !== 'object') { return false; }
    var changed = false;
    var i, k;

    for (i = 0; i < AD_LIST_KEYS.length; i++) {
      k = AD_LIST_KEYS[i];
      if (Array.isArray(p[k]) && p[k].length !== 0) {
        p[k] = [];
        changed = true;
      }
    }
    for (i = 0; i < AD_BOOL_KEYS.length; i++) {
      k = AD_BOOL_KEYS[i];
      if (typeof p[k] === 'boolean' && p[k]) {
        p[k] = false;
        changed = true;
      }
    }
    for (i = 0; i < AD_ZERO_KEYS.length; i++) {
      k = AD_ZERO_KEYS[i];
      if (typeof p[k] === 'number' && p[k] !== 0) {
        p[k] = 0;
        changed = true;
      }
    }
    return changed;
  }

  function scrubNode(node, depth) {
    if (!node || typeof node !== 'object' || depth > MAX_DEPTH) { return false; }
    var changed = false;
    var i, k, keys, v;

    var placements = node.placements;
    if (placements && typeof placements === 'object' && !Array.isArray(placements)) {
      for (k in placements) {
        if (Object.prototype.hasOwnProperty.call(placements, k)) {
          if (scrubPlacement(placements[k])) { changed = true; }
        }
      }
    }

    // placements 也可能被包在更深一层（bootstrap 里是 app_experience.placements）
    keys = Object.keys(node);
    for (i = 0; i < keys.length; i++) {
      if (keys[i] === 'placements') { continue; }
      v = node[keys[i]];
      if (v && typeof v === 'object') {
        if (scrubNode(v, depth + 1)) { changed = true; }
      }
    }
    return changed;
  }

  function rewriteBody(text) {
    if (typeof text !== 'string' || text.indexOf('placements') === -1) { return null; }
    var data;
    try { data = JSON.parse(text); } catch (e) { return null; }
    if (!scrubNode(data, 0)) { return null; }
    try { return JSON.stringify(data); } catch (e) { return null; }
  }

  var nativeFetch = W.fetch;
  if (typeof nativeFetch === 'function') {
    var patched = function (input, init) {
      var pending = nativeFetch.apply(this, arguments);
      if (!pending || typeof pending.then !== 'function') { return pending; }
      return pending.then(function (res) {
        try {
          if (!res || typeof res.clone !== 'function' || !res.ok) { return res; }

          var ct = '';
          try { ct = String(res.headers.get('content-type') || ''); } catch (e0) { ct = ''; }
          if (ct.indexOf('json') === -1) { return res; }

          var url = '';
          if (typeof input === 'string') { url = input; }
          else if (input && typeof input.url === 'string') { url = input.url; }
          else if (typeof res.url === 'string') { url = res.url; }
          if (url.indexOf(API_MARK) === -1) { return res; }

          return res.clone().text().then(function (body) {
            var out = rewriteBody(body);
            if (out === null) { return res; }
            return new Response(out, {
              status: res.status,
              statusText: res.statusText,
              headers: res.headers
            });
          }).catch(function () { return res; });
        } catch (e) {
          return res;
        }
      });
    };
    // 站点可能校验 fetch 是否被替换过，这里让 toString 返回原生实现
    try { patched.toString = nativeFetch.toString.bind(nativeFetch); } catch (e1) {}
    W.fetch = patched;
  }

  /* ------------------------------------------------------------------ */
  /* L2  样式层: 隐藏残留容器                                             */
  /* ------------------------------------------------------------------ */

  function injectStyle() {
    if (document.getElementById(STYLE_ID)) { return; }
    if (!HIDE_SELECTORS.length) { return; }
    var css = HIDE_SELECTORS.map(function (s) {
      return s + '{display:none!important;visibility:hidden!important;}';
    }).join('');
    var el = document.createElement('style');
    el.id = STYLE_ID;
    el.textContent = css;
    var host = document.head || document.documentElement;
    if (host) { host.appendChild(el); }
  }

  /* ------------------------------------------------------------------ */
  /* L3  行为层: 解滚动锁 + 拦弹窗                                        */
  /* ------------------------------------------------------------------ */

  var scrollUnlocked = false;

  // 开屏广告组件在 useEffect 里把 body.style.overflow 设成 hidden，
  // display:none 不会阻止那段 effect 执行，必须手动还原，否则整页滚不动。
  function unlockScroll() {
    var body = document.body;
    if (!body || body.style.overflow !== 'hidden') { return; }
    if (!document.querySelector(SCROLL_HOST)) { return; }
    body.style.overflow = '';
    var html = document.documentElement;
    if (html && html.style.overflow === 'hidden') { html.style.overflow = ''; }
    scrollUnlocked = true;
  }

  function prefillSeen() {
    try {
      var d = new Date();
      var day = d.getFullYear() + '-' +
        String(d.getMonth() + 1).padStart(2, '0') + '-' +
        String(d.getDate()).padStart(2, '0');
      var payload = JSON.stringify({
        itemId: 'dpd-seen',
        seenAt: Date.now(),
        day: day,
        dailyCount: 99
      });
      W.localStorage.setItem(PREFILL_KEY, payload);
    } catch (e) {}
  }

  var pending = false;
  function schedule() {
    if (pending) { return; }
    pending = true;
    var raf = W.requestAnimationFrame || function (fn) { return setTimeout(fn, 16); };
    raf(function () {
      pending = false;
      injectStyle();
      unlockScroll();
    });
  }

  function startDomWork() {
    injectStyle();
    scrollUnlocked = false;
    unlockScroll();

    try {
      var mo = new MutationObserver(schedule);
      mo.observe(document.documentElement, {
        childList: true,
        subtree: true,
        attributes: true,
        attributeFilter: ['style', 'class']
      });
    } catch (e) {}

    // 兜底：开屏广告在首屏渲染后 300~800ms 才挂载，观察器偶发漏报时用低频轮询补
    var ticks = 0;
    var timer = setInterval(function () {
      ticks++;
      schedule();
      if (ticks >= 40) { clearInterval(timer); }
    }, 500);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', startDomWork, { once: true });
    startDomWork();
  } else {
    startDomWork();
  }

  prefillSeen();

  // web 模式下没有原生壳接管外链，window.open 只会把广告页塞进新窗口
  if (CFG.blockWindowOpen !== false) {
    W.open = function () { return null; };
  }
})();
