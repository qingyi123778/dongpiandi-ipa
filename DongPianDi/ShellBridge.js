/*
 * DongPianDi Shell — 原生能力桥
 *
 * 站点播放器是 ArtPlayer。它点全屏只做两层 CSS：
 *   .art-fullscreen-web   网页全屏（容器 fixed 铺满视口）
 *   .art-fullscreen       系统级全屏（iOS Safari 不支持 Element.requestFullscreen，走不到）
 * 两条路都不触发设备旋转，所以 iOS 上表现为"铺满了但还是竖屏、状态栏还在"。
 *
 * 这里把全屏类名变化同步给原生，由 App 主动 requestGeometryUpdate 转横屏。
 * 保留站点自己的播放器 UI（弹幕/选集/倍速），只补系统层行为。
 */
(function () {
  'use strict';

  var W = window;
  if (W.__DPD_SHELL__) { return; }
  W.__DPD_SHELL__ = 1;

  var native = W.webkit && W.webkit.messageHandlers && W.webkit.messageHandlers.dpdShell;
  if (!native) { return; }

  var PLAYER_SELECTOR = '.art-video-player';
  var FULL_CLASSES = ['art-fullscreen-web', 'art-fullscreen'];
  var POLL_MS = 500;
  var last = null;

  function isOn(el) {
    if (!el || !el.classList) { return false; }
    for (var i = 0; i < FULL_CLASSES.length; i++) {
      if (el.classList.contains(FULL_CLASSES[i])) { return true; }
    }
    return false;
  }

  function send(on) {
    try { native.postMessage({ type: 'fullscreen', value: on }); } catch (e) {}
  }

  function sync() {
    var on = isOn(document.querySelector(PLAYER_SELECTOR));
    if (on !== last) {
      last = on;
      send(on);
    }
  }

  // 切线路/切集时 ArtPlayer 会重建节点，只认 target 是 art-video-player 的 class 变更
  try {
    new MutationObserver(function (records) {
      for (var i = 0; i < records.length; i++) {
        var t = records[i].target;
        if (t && t.classList && t.classList.contains('art-video-player')) {
          sync();
          return;
        }
      }
    }).observe(document.documentElement, {
      attributes: true,
      attributeFilter: ['class'],
      subtree: true
    });
  } catch (e) {}

  // 节点重建后 observer 丢掉目标的情况，靠低频轮询兜
  setInterval(sync, POLL_MS);
  sync();

  // SPA 路由切走时全屏类不会留，但组件可能整块卸载，补一次
  W.addEventListener('popstate', function () { setTimeout(sync, 400); });
})();
