// ==UserScript==
// @name         懂片帝 · 去广告
// @namespace    dpd.adblock
// @version      3.0
// @description  清空 dongpian17.com 的 placements 广告配置，隐藏残留广告容器
// @match        https://dongpian17.com/*
// @match        https://*.dongpian17.com/*
// @run-at       document-start
// @grant        none
// ==/UserScript==

/*
 * 与 iOS 工程里的 AdInject.js 同一套逻辑，用于桌面浏览器验证效果。
 * 差异: 不劫持 window.open（浏览器里会误伤正常外链），其余一致。
 */
(function () {
  'use strict';
  if (window.__DPD_ADBLOCK__) { return; }
  window.__DPD_ADBLOCK__ = 1;

  var AD_LIST_KEYS = ['items', 'grid_items', 'banner_items'];
  var AD_BOOL_KEYS = ['enabled', 'search_enabled', 'calendar_enabled'];
  var AD_ZERO_KEYS = ['daily_impression_limit'];

  var HIDE_SELECTORS = [
    'aside.app-startup-ad',
    '.app-startup-ad',
    '.app-startup-ad-link',
    'section.movie-player-top-grid-ad',
    'aside.movie-content-grid-ad',
    '.movie-content-grid-ad-heading'
  ];

  var MAX_DEPTH = 6;
  var STYLE_ID = 'dpd-adblock-style';

  function scrubPlacement(p) {
    if (!p || typeof p !== 'object') { return false; }
    var changed = false, i, k;
    for (i = 0; i < AD_LIST_KEYS.length; i++) {
      k = AD_LIST_KEYS[i];
      if (Array.isArray(p[k]) && p[k].length !== 0) { p[k] = []; changed = true; }
    }
    for (i = 0; i < AD_BOOL_KEYS.length; i++) {
      k = AD_BOOL_KEYS[i];
      if (typeof p[k] === 'boolean' && p[k]) { p[k] = false; changed = true; }
    }
    for (i = 0; i < AD_ZERO_KEYS.length; i++) {
      k = AD_ZERO_KEYS[i];
      if (typeof p[k] === 'number' && p[k] !== 0) { p[k] = 0; changed = true; }
    }
    return changed;
  }

  function scrubNode(node, depth) {
    if (!node || typeof node !== 'object' || depth > MAX_DEPTH) { return false; }
    var changed = false, i, k, keys, v;
    var pl = node.placements;
    if (pl && typeof pl === 'object' && !Array.isArray(pl)) {
      for (k in pl) {
        if (Object.prototype.hasOwnProperty.call(pl, k) && scrubPlacement(pl[k])) { changed = true; }
      }
    }
    keys = Object.keys(node);
    for (i = 0; i < keys.length; i++) {
      if (keys[i] === 'placements') { continue; }
      v = node[keys[i]];
      if (v && typeof v === 'object' && scrubNode(v, depth + 1)) { changed = true; }
    }
    return changed;
  }

  function rewrite(text) {
    if (typeof text !== 'string' || text.indexOf('placements') === -1) { return null; }
    var data;
    try { data = JSON.parse(text); } catch (e) { return null; }
    if (!scrubNode(data, 0)) { return null; }
    return JSON.stringify(data);
  }

  var nativeFetch = window.fetch;
  if (typeof nativeFetch === 'function') {
    var patched = function (input) {
      var pending = nativeFetch.apply(this, arguments);
      if (!pending || typeof pending.then !== 'function') { return pending; }
      return pending.then(function (res) {
        try {
          if (!res || typeof res.clone !== 'function' || !res.ok) { return res; }
          var ct = '';
          try { ct = String(res.headers.get('content-type') || ''); } catch (e0) { ct = ''; }
          if (ct.indexOf('json') === -1) { return res; }
          var url = typeof input === 'string' ? input
            : (input && typeof input.url === 'string' ? input.url : (res.url || ''));
          if (url.indexOf('/v1/') === -1) { return res; }
          return res.clone().text().then(function (body) {
            var out = rewrite(body);
            if (out === null) { return res; }
            return new Response(out, { status: res.status, statusText: res.statusText, headers: res.headers });
          }).catch(function () { return res; });
        } catch (e) { return res; }
      });
    };
    try { patched.toString = nativeFetch.toString.bind(nativeFetch); } catch (e1) {}
    window.fetch = patched;
  }

  function style() {
    if (document.getElementById(STYLE_ID)) { return; }
    var css = HIDE_SELECTORS.map(function (s) {
      return s + '{display:none!important;visibility:hidden!important;}';
    }).join('');
    var el = document.createElement('style');
    el.id = STYLE_ID;
    el.textContent = css;
    (document.head || document.documentElement).appendChild(el);
  }

  function unlock() {
    var body = document.body;
    if (!body || body.style.overflow !== 'hidden') { return; }
    if (!document.querySelector('aside.app-startup-ad')) { return; }
    body.style.overflow = '';
    if (document.documentElement.style.overflow === 'hidden') {
      document.documentElement.style.overflow = '';
    }
  }

  function seen() {
    try {
      var d = new Date();
      var day = d.getFullYear() + '-' + String(d.getMonth() + 1).padStart(2, '0') + '-' +
        String(d.getDate()).padStart(2, '0');
      localStorage.setItem('movie-search:startup-ad-seen:v2', JSON.stringify({
        itemId: 'dpd-seen', seenAt: Date.now(), day: day, dailyCount: 99
      }));
    } catch (e) {}
  }

  var queued = false;
  function tick() {
    if (queued) { return; }
    queued = true;
    requestAnimationFrame(function () { queued = false; style(); unlock(); });
  }

  function boot() {
    style(); unlock();
    try {
      new MutationObserver(tick).observe(document.documentElement, {
        childList: true, subtree: true, attributes: true, attributeFilter: ['style', 'class']
      });
    } catch (e) {}
    var n = 0;
    var t = setInterval(function () { tick(); if (++n >= 40) { clearInterval(t); } }, 500);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
    boot();
  } else {
    boot();
  }
  seen();
})();
