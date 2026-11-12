/*
 * DongPianDi Shell — 原生能力桥
 *
 * 1. 全屏状态同步。站点播放器是 ArtPlayer，点全屏只加 CSS 类
 *    （art-fullscreen-web / art-fullscreen），iOS Safari 不支持
 *    Element.requestFullscreen，所以系统不会转屏，必须由 App 主动转。
 * 2. 长按倍速。按住播放区加速，松手回到原速率。
 * 3. 在 /me 的服务列表里插入「播放设置」入口，点开走原生面板。
 *
 * 速率切换处理:
 *   - 角标在页面加载时预创建并提升为合成层，长按时只切 opacity，绝不 appendChild
 *     —— 全屏是 fixed 铺满布局，中途插节点会触发整页重排。
 *   - playbackRate 同步赋值。之前用 requestAnimationFrame 躲站点的 ratechange
 *     渲染，会留出延迟窗口导致位置抖动，得不偿失。
 *   - preservesPitch 保持浏览器默认（开启）。关掉能省一次音频 time-pitch 管线
 *     重建，但 2x 会变成尖声，不可接受。
 *   - 改速率后 280ms 检查一次位置，只纠正「倒退超过 0.5 秒」的情况。
 *     WebKit 重整音频管线时偶尔会把播放位置往回带。
 */
(function () {
  'use strict';

  var W = window;
  if (W.__DPD_SHELL__) { return; }
  W.__DPD_SHELL__ = 1;

  var native = W.webkit && W.webkit.messageHandlers && W.webkit.messageHandlers.dpdShell;

  var settings = W.__DPD_SETTINGS__ || {};
  if (typeof settings.longPressRate !== 'number') { settings.longPressRate = 2.0; }
  if (typeof settings.autoRotate !== 'boolean') { settings.autoRotate = true; }
  W.__DPD_SETTINGS__ = settings;

  var PLAYER_SELECTOR = '.art-video-player';
  var FULL_CLASSES = ['art-fullscreen-web', 'art-fullscreen'];
  var POLL_MS = 500;
  var LONG_PRESS_MS = 420;
  var MOVE_TOLERANCE = 12;
  var BADGE_ID = 'dpd-rate-badge';
  var ROW_FLAG = 'dpdSettingsRow';

  /* ---------------------------------------------------------------- */
  /* 对外入口先挂上：atDocumentStart 时 DOM 还没成形，后面任何一步抛异常 */
  /* 都不能让这个入口缺失，否则原生改设置会静默失效                      */
  /* ---------------------------------------------------------------- */

  W.__DPD_APPLY_SETTINGS__ = function (next) {
    if (!next || typeof next !== 'object') { return; }
    if (typeof next.longPressRate === 'number') { settings.longPressRate = next.longPressRate; }
    if (typeof next.autoRotate === 'boolean') { settings.autoRotate = next.autoRotate; }
    if (settings.autoRotate === false && lastFullscreen === true) {
      lastFullscreen = false;
      sendFullscreen(false);
    } else {
      syncFullscreen();
    }
    if (!settings.longPressRate) { releasePress(true); }
  };

  /* ---------------------------------------------------------------- */
  /* 全屏状态 → 原生                                                    */
  /* ---------------------------------------------------------------- */

  var lastFullscreen = null;

  function isFullscreenOn(el) {
    if (!el || !el.classList) { return false; }
    for (var i = 0; i < FULL_CLASSES.length; i++) {
      if (el.classList.contains(FULL_CLASSES[i])) { return true; }
    }
    return false;
  }

  function sendFullscreen(on) {
    if (!native) { return; }
    try { native.postMessage({ type: 'fullscreen', value: on }); } catch (e) {}
  }

  function requestNativeSettings() {
    if (!native) { return; }
    try { native.postMessage({ type: 'openSettings' }); } catch (e) {}
  }

  function syncFullscreen() {
    var on = isFullscreenOn(document.querySelector(PLAYER_SELECTOR));
    var report = on && settings.autoRotate !== false;
    if (report !== lastFullscreen) {
      lastFullscreen = report;
      sendFullscreen(report);
    }
  }

  /* ---------------------------------------------------------------- */
  /* 样式                                                              */
  /* ---------------------------------------------------------------- */

  function injectStyle() {
    if (!document.documentElement) { return; }
    if (document.getElementById('dpd-shell-style')) { return; }
    var el = document.createElement('style');
    el.id = 'dpd-shell-style';
    el.textContent =
      '.art-video-player,.art-video-player *{-webkit-touch-callout:none!important;' +
      '-webkit-user-select:none!important;user-select:none!important;}';
    var host = document.head || document.documentElement;
    if (host) { host.appendChild(el); }
  }

  /* ---------------------------------------------------------------- */
  /* 倍速角标：预创建，只切 opacity                                     */
  /* ---------------------------------------------------------------- */

  var badgeEl = null;

  function ensureBadge() {
    if (badgeEl && badgeEl.parentNode) { return badgeEl; }
    var host = document.body || document.documentElement;
    if (!host) { return null; }
    var el = document.getElementById(BADGE_ID);
    if (!el) {
      el = document.createElement('div');
      el.id = BADGE_ID;
      el.style.cssText =
        'position:fixed;left:50%;' +
        'top:calc(env(safe-area-inset-top, 0px) + 26px);' +
        'transform:translate3d(-50%,0,0);' +
        'z-index:2147483001;pointer-events:none;opacity:0;' +
        'padding:7px 15px;border-radius:999px;' +
        'background:rgba(13,14,16,.82);color:#ffcf32;' +
        'font:700 14px/1.2 -apple-system,BlinkMacSystemFont,sans-serif;' +
        'letter-spacing:.02em;' +
        'backdrop-filter:blur(10px);-webkit-backdrop-filter:blur(10px);' +
        'transition:opacity .12s linear;' +
        'will-change:opacity;contain:layout style;';
      host.appendChild(el);
    }
    badgeEl = el;
    return el;
  }

  function showBadge(rate) {
    var el = ensureBadge();
    if (!el) { return; }
    el.textContent = rate.toFixed(1) + 'x 倍速播放中';
    el.style.opacity = '1';
  }

  function hideBadge() {
    if (badgeEl) { badgeEl.style.opacity = '0'; }
  }

  /* ---------------------------------------------------------------- */
  /* 长按倍速                                                           */
  /* ---------------------------------------------------------------- */

  var press = null;
  var guardSeq = 0;

  function currentVideo() {
    var host = document.querySelector(PLAYER_SELECTOR);
    if (host) {
      var v = host.querySelector('video');
      if (v) { return v; }
    }
    return document.querySelector('video');
  }

  // 只排除真正的可交互控件。不能排除 .art-controls —— 全屏时它铺满整屏，
  // 一并排掉的话全屏状态下永远触发不了。
  function isInteractive(target) {
    if (!target || !target.closest) { return false; }
    return !!target.closest(
      'button, input, textarea, select, a, [role="button"], [role="slider"], ' +
      '.art-setting, .art-contextmenus, .art-notice, ' +
      '.art-progress, .art-volume'
    );
  }

  // 同步赋值。之前走 requestAnimationFrame 是为了躲站点的 ratechange 渲染，
  // 但那样长按/松手会有一个延迟窗口，期间位置状态对不上，反而放大抖动。
  // 音调校正保持浏览器默认（开），关掉会让 2x 变成尖声。
  function applyRate(video, rate) {
    try { video.playbackRate = rate; } catch (e) {}
  }

  // 改速率后 WebKit 偶尔会把播放位置往回带一点（音频管线重整）。
  // 只认「倒退」且幅度超过 0.5s 的情况，往前正常播不动它。
  function guardPosition(video, expected) {
    var seq = ++guardSeq;
    setTimeout(function () {
      if (seq !== guardSeq) { return; }
      try {
        if (video.currentTime < expected - 0.5) {
          video.currentTime = expected;
        }
      } catch (e) {}
    }, 280);
  }

  function applyRate(video, rate) {
    try { video.playbackRate = rate; } catch (e) {}
  }

  function releasePress(restore) {
    var s = press;
    if (!s) { return; }
    press = null;
    if (s.timer) { clearTimeout(s.timer); }
    if (s.active) {
      if (restore) {
        var pos = 0;
        try { pos = s.video.currentTime; } catch (e) {}
        applyRate(s.video, s.before);
        guardPosition(s.video, pos);
      }
      hideBadge();
    }
  }

  function activatePress() {
    var s = press;
    if (!s) { return; }
    var rate = Number(settings.longPressRate);
    if (!isFinite(rate) || rate <= 0) { return; }
    if (s.video.paused) { return; }

    var pos = 0;
    try { pos = s.video.currentTime; } catch (e) {}

    s.active = true;
    s.before = s.video.playbackRate || 1;
    applyRate(s.video, rate);
    guardPosition(s.video, pos);
    showBadge(rate);
  }

  function onTouchStart(e) {
    if (!settings.longPressRate || settings.longPressRate <= 0) { return; }
    if (e.touches.length !== 1) { return; }
    if (isInteractive(e.target)) { return; }
    var video = currentVideo();
    if (!video || video.paused) { return; }

    var t = e.touches[0];
    press = {
      video: video,
      x: t.clientX,
      y: t.clientY,
      before: video.playbackRate || 1,
      active: false,
      timer: setTimeout(activatePress, LONG_PRESS_MS)
    };
  }

  function onTouchMove(e) {
    var s = press;
    if (!s || s.active || !e.touches.length) { return; }
    var t = e.touches[0];
    if (Math.abs(t.clientX - s.x) > MOVE_TOLERANCE ||
        Math.abs(t.clientY - s.y) > MOVE_TOLERANCE) {
      releasePress(false);
    }
  }

  function onTouchEnd() {
    releasePress(true);
  }

  document.addEventListener('touchstart', onTouchStart, { passive: true });
  document.addEventListener('touchmove', onTouchMove, { passive: true });
  document.addEventListener('touchend', onTouchEnd, { passive: true });
  document.addEventListener('touchcancel', onTouchEnd, { passive: true });

  /* ---------------------------------------------------------------- */
  /* /me 页面注入「播放设置」入口                                       */
  /* ---------------------------------------------------------------- */

  var GEAR =
    '<span class="dpd-me-service-icon" aria-hidden="true">' +
    '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" ' +
    'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
    'stroke-linejoin="round" aria-hidden="true">' +
    '<line x1="21" x2="14" y1="4" y2="4"></line>' +
    '<line x1="10" x2="3" y1="4" y2="4"></line>' +
    '<line x1="21" x2="12" y1="12" y2="12"></line>' +
    '<line x1="8" x2="3" y1="12" y2="12"></line>' +
    '<line x1="21" x2="16" y1="20" y2="20"></line>' +
    '<line x1="12" x2="3" y1="20" y2="20"></line>' +
    '<line x1="14" x2="14" y1="2" y2="6"></line>' +
    '<line x1="8" x2="8" y1="10" y2="14"></line>' +
    '<line x1="16" x2="16" y1="18" y2="22"></line>' +
    '</svg></span>';

  var CHEVRON =
    '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" ' +
    'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" ' +
    'stroke-linejoin="round" aria-hidden="true"><path d="m9 18 6-6-6-6"></path></svg>';

  function injectSettingsRow() {
    if (location.pathname !== '/me') { return; }
    var list = document.querySelector('.dpd-me-service-list');
    if (!list) { return; }
    if (list.querySelector('[' + 'data-dpd="settings-row"' + ']')) { return; }

    var rows = list.querySelectorAll('.dpd-me-service-row');
    var anchor = null;
    for (var i = 0; i < rows.length; i++) {
      if ((rows[i].textContent || '').trim().indexOf('设置') === 0 ||
          (rows[i].textContent || '').indexOf('设置') >= 0) {
        anchor = rows[i];
        break;
      }
    }
    if (!anchor) { return; }

    var btn = document.createElement('button');
    btn.type = 'button';
    btn.className = 'dpd-me-service-row';
    btn.setAttribute('data-dpd', 'settings-row');
    btn.innerHTML = GEAR + '<strong>播放设置</strong>' + CHEVRON;
    btn.addEventListener('click', function (ev) {
      ev.preventDefault();
      ev.stopPropagation();
      requestNativeSettings();
    }, true);

    anchor.insertAdjacentElement('afterend', btn);
  }

  /* ---------------------------------------------------------------- */
  /* 启动                                                              */
  /* ---------------------------------------------------------------- */

  function tick() {
    try { syncFullscreen(); } catch (e) {}
    try { injectSettingsRow(); } catch (e) {}
    try { ensureBadge(); } catch (e) {}
  }

  // 切线路/切集时 ArtPlayer 会重建节点，只认 target 是 art-video-player 的 class 变更
  try {
    new MutationObserver(function (records) {
      for (var i = 0; i < records.length; i++) {
        var t = records[i].target;
        if (t && t.classList && t.classList.contains('art-video-player')) {
          syncFullscreen();
          return;
        }
      }
    }).observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['class'],
      subtree: true
    });
  } catch (e) {}

  // /me 页面由 React 渲染，节点插入后可能被重渲染冲掉，靠低频轮询补回来
  setInterval(tick, POLL_MS);

  function boot() {
    try { injectStyle(); } catch (e) {}
    tick();
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
  }
  boot();

  W.addEventListener('popstate', function () {
    releasePress(true);
    setTimeout(tick, 400);
  });
})();
