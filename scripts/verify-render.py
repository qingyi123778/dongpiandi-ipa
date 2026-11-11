"""二次验证: 页面功能未被破坏 + 广告位在真实页面上消失。
指标: 卡片数 / 正文长度 / 广告节点数 / 首屏截图。
"""
import json
from playwright.sync_api import sync_playwright

ROOT = "D:/work111/2026-11-11-21-34-28/DongPianDi/DongPianDi"
OUT = "D:/work111/2026-11-11-21-34-28/DongPianDi/build/verify"
INJECT = open(f"{ROOT}/AdInject.js", encoding="utf-8").read()
CFG = json.load(open(f"{ROOT}/AdSelectors.json", encoding="utf-8"))

UA = ("Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) "
      "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1")

METRICS = """() => {
  const q = s => document.querySelectorAll(s).length;
  return {
    cards: q('a[href*="/player/"], a[href*="/short-drama/"]'),
    bodyLen: (document.body.innerText || '').length,
    rootChildren: document.getElementById('root') ? document.getElementById('root').children.length : -1,
    adStartup: q('aside.app-startup-ad'),
    adContentGrid: q('.movie-content-grid-ad'),
    adPlayerTop: q('.movie-player-top-grid-ad'),
    adSlots: q('[data-ad-slot]'),
    bodyOverflow: document.body.style.overflow || '(empty)'
  };
}"""


def shot(page, name):
    import os
    os.makedirs(OUT, exist_ok=True)
    page.screenshot(path=f"{OUT}/{name}.png", full_page=False)


def run(blocked: bool, url: str, tag: str):
    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx = b.new_context(viewport={"width": 390, "height": 844}, user_agent=UA,
                            is_mobile=True, has_touch=True, device_scale_factor=2, locale="zh-CN")
        if blocked:
            ctx.add_init_script(
                "window.__DPD_CONFIG__ = " + json.dumps(CFG, ensure_ascii=False) + ";\n" + INJECT)
        page = ctx.new_page()
        page.goto(url, wait_until="domcontentloaded", timeout=60000)
        page.wait_for_timeout(7000)
        data = page.evaluate(METRICS)
        shot(page, tag)
        b.close()
        return data


if __name__ == "__main__":
    targets = [
        ("首页", "https://dongpian17.com/"),
        ("搜索页", "https://dongpian17.com/s?q=%E5%A4%8D%E4%BB%87%E8%80%85%E8%81%94%E7%9B%9F"),
    ]
    for name, url in targets:
        print(f"\n===== {name} =====")
        before = run(False, url, f"{name}-before")
        print("基线 :", json.dumps(before, ensure_ascii=False))
        after = run(True, url, f"{name}-after")
        print("注入后:", json.dumps(after, ensure_ascii=False))
