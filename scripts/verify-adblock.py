"""验证 AdInject.js 对 dongpian17.com 的广告清洗效果。
基线（不注入） vs 注入后，对比 /v1/runtime/bootstrap 的 placements 与页面广告节点数。
"""
import json
import sys
from playwright.sync_api import sync_playwright

ROOT = "D:/work111/2026-11-11-21-34-28/DongPianDi/DongPianDi"
INJECT = open(f"{ROOT}/AdInject.js", encoding="utf-8").read()
CFG = json.load(open(f"{ROOT}/AdSelectors.json", encoding="utf-8"))

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1")

PROBE = """async () => {
  const out = { placements: null, ads: [], err: null };
  try {
    const r = await fetch('/v1/runtime/bootstrap', { headers: { accept: 'application/json' } });
    const j = await r.json();
    const pl = (j.app_experience && j.app_experience.placements) || {};
    out.placements = {};
    for (const k of Object.keys(pl)) {
      const p = pl[k] || {};
      out.placements[k] = {
        items: (p.items || []).length,
        grid_items: (p.grid_items || []).length,
        enabled: p.enabled === undefined ? null : p.enabled,
        search_enabled: p.search_enabled === undefined ? null : p.search_enabled,
        calendar_enabled: p.calendar_enabled === undefined ? null : p.calendar_enabled
      };
    }
  } catch (e) { out.err = String(e); }
  const sel = ['aside.app-startup-ad', '.movie-content-grid-ad',
               'section.movie-player-top-grid-ad', '[data-ad-slot]',
               '.react-player-ad-safety-notice'];
  for (const s of sel) {
    const n = document.querySelectorAll(s).length;
    if (n) out.ads.push(s + '=' + n);
  }
  return out;
}"""


def run(blocked: bool):
    with sync_playwright() as p:
        b = p.chromium.launch(args=["--disable-blink-features=AutomationControlled"])
        ctx = b.new_context(viewport={"width": 390, "height": 844},
                            user_agent=UA, is_mobile=True, has_touch=True,
                            device_scale_factor=3, locale="zh-CN")
        if blocked:
            ctx.add_init_script(
                "window.__DPD_CONFIG__ = " + json.dumps(CFG, ensure_ascii=False) + ";\n" + INJECT
            )
        page = ctx.new_page()
        page.goto("https://dongpian17.com/", wait_until="domcontentloaded", timeout=60000)
        page.wait_for_timeout(6000)
        result = page.evaluate(PROBE)
        title = page.title()
        token = page.evaluate("() => !!window.__DPD_ADBLOCK__")
        b.close()
        return {"blocked": blocked, "title": title, "injected": token, **result}


if __name__ == "__main__":
    base = run(False)
    print("=== 基线（不注入）===")
    print(json.dumps(base, ensure_ascii=False, indent=2))
    patched = run(True)
    print("=== 注入 AdInject.js ===")
    print(json.dumps(patched, ensure_ascii=False, indent=2))
