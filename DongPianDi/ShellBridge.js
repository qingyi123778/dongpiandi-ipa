/*
 * DongPianDi Shell — 原生能力桥
 *
 * 两件事:
 *   1. 全屏状态同步。站点播放器是 ArtPlayer，点全屏只加 CSS 类
 *      （art-fullscreen-web / art-fullscreen），iOS Safari 不支持
 *      Element.requestFullscreen，所以系统不会转屏，必须由 App 主动转。
 *   2. 长按倍速。按住播放区 accelerare，松手回到原速率（不是固定 1.0，
 *      用户可能自己设过 1.5x 常速）。
 *
 * 配置来源: window.__DPD_SETTINGS__（原生注入）
 * 运行时更新: window.__DPD_APPLY_SETTINGS__({longPressRate, autoRotate})
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

  /* ---------------------------------------------------------------- */
  /* 长按不弹系统菜单/放大镜                                            */
  /* ---------------------------------------------------------------- */

  function injectStyle() {
    if (document.getElementById('dpd-shell-style')) { return; }
    var el = document.createElement('style');
    el.id = 'dpd-shell-style';
    el.textContent =
      '.art-video-player,.art-video-player *{-webkit-touch-callout:none!important;' +
      '-webkit-user-select:none!important;user-select:none!important;}';
    (document.head || document.documentElement).appendChild(el);
  }

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

  function syncFullscreen() {
    var on = isFullscreenOn(document.querySelector(PLAYER_SELECTOR));
    // 关掉自动横屏时不上报 true，保持竖屏
    var report = on && settings.autoRotate !== false;
    if (report !== lastFullscreen) {
      lastFullscreen = report;
      sendFullscreen(report);
    }
  }

  /* ---------------------------------------------------------------- */
  /* 长按倍速                                                           */
  /* ---------------------------------------------------------------- */

  var press = null;

  function currentVideo() {
    var host = document.querySelector(PLAYER_SELECTOR);
    if (host) {
      var v = host.querySelector('video');
      if (v) { return v; }
    }
    return document.querySelector('video');
  }

  // 只排除真正的可交互控件。
  // 注意不能排除 .art-controls —— 全屏时它是铺满整屏的容器，长按空白处的
  // target 就是它，一并排掉的话全屏状态下永远触发不了倍速。
  function isInteractive(target) {
    if (!target || !target.closest) { return false; }
    var hit = target.closest(
      'button, input, textarea, select, a, [role="button"], [role="slider"], ' +
      '.art-setting, .art-contextmenus, .art-notice, ' +
      '.art-progress, .art-volume'
    );
    return !!hit;
  }

  function showBadge(rate) {
    var el = document.getElementById(BADGE_ID);
    if (!el) {
      el = document.createElement('div');
      el.id = BADGE_ID;
      el.style.cssText =
        'position:fixed;left:50%;top:18%;transform:translateX(-50%);' +
        'z-index:2147483001;pointer-events:none;display:none;' +
        'padding:7px 15px;border-radius:999px;' +
        'background:rgba(13,14,16,.82);color:#ffcf32;' +
        'font:700 14px/1.2 -apple-system,BlinkMacSystemFont,sans-serif;' +
        'letter-spacing:.02em;backdrop-filter:blur(10px);' +
        '-webkit-backdrop-filter:blur(10px);';
      (document.body || document.documentElement).appendChild(el);
    }
    el.textContent = rate.toFixed(1) + 'x 倍速播放中';
    el.style.display = 'block';
  }

  function hideBadge() {
    var el = document.getElementById(BADGE_ID);
    if (el) { el.style.display = 'none'; }
  }

  function releasePress(restore) {
    var s = press;
    if (!s) { return; }
    press = null;
    if (s.timer) { clearTimeout(s.timer); }
    if (s.active) {
      if (restore) {
        try { s.video.playbackRate = s.before; } catch (e) {}
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
    s.active = true;
    s.before = s.video.playbackRate || 1;
    try { s.video.playbackRate = rate; } catch (e) {}
    // iOS 上 playbackRate > 2 会被系统静音，这是 AVPlayer 的行为，改不了
    showBadge(rate);
  }

  function onTouchStart(e) {
    if (!settings.longPressRate || settings.longPressRate <= 0) { return; }
    if (e.touches.length !== 1) { return; }
    if (isInteractive(e.target)) { return; }
    var video = currentVideo();
    if (!video) { return; }

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
  /* 启动                                                              */
  /* ---------------------------------------------------------------- */

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

  setInterval(syncFullscreen, POLL_MS);
  syncFullscreen();

  W.addEventListener('popstate', function () {
    releasePress(true);
    setTimeout(syncFullscreen, 400);
  });

  function bootStyle() { injectStyle(); }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', bootStyle, { once: true });
  }
  bootStyle();

  // 原生改设置后即时生效，不用刷新页面
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
})();
