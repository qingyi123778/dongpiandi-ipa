"""第三层验证: 逐条断言去广告的三层逻辑在真实页面上生效。
L1 数据层  — bootstrap 响应 placements.items 被清空
L2 样式层  — 注入的广告容器被 display:none
L3 行为层  — body 滚动锁被解除 / window.open 被拦截
另外验证页面主体未被破坏（卡片数、正文长度）。
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
  const out = {};
  // --- L1: 数据层 ---
  try {
    const r = await fetch('/v1/runtime/bootstrap', { headers: { accept: 'application/json' } });
    const j = await r.json();
    const pl = (j.app_experience && j.app_experience.placements) || {};
    out.l1 = {};
    for (const k of Object.keys(pl)) {
      out.l1[k] = {
        items: (pl[k].items || []).length,
        grid: (pl[k].grid_items || []).length,
        enabled: pl[k].enabled
      };
    }
  } catch (e) { out.l1 = 'ERR ' + e; }

  // --- L2: 样式层 — 手工挂一个广告容器，看是否被隐藏 ---
  const probe = document.createElement('aside');
  probe.className = 'app-startup-ad app-startup-ad-ready';
  probe.id = 'dpd-probe';
  probe.style.cssText = 'position:fixed;inset:0;background:red;z-index:2147483000';
  document.body.appendChild(probe);
  await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)));
  const cs = getComputedStyle(probe);
  out.l2 = { display: cs.display, visibility: cs.visibility, hidden: cs.display === 'none' };

  // --- L3a: 滚动锁 ---
  document.body.style.overflow = 'hidden';
  await new Promise(r => setTimeout(r, 260));
  out.l3a = { overflowAfter: document.body.style.overflow || '(empty)', unlocked: document.body.style.overflow !== 'hidden' };

  // --- L3b: window.open ---
  let opened = 'threw';
  try { opened = window.open('https://30868739.com', '_blank'); } catch (e) { opened = 'threw'; }
  out.l3b = { returnedNull: opened === null };

  // --- 页面完整度 ---
  out.page = {
    cards: document.querySelectorAll('a[href*="/player/"], a[href*="/short-drama/"]').length,
    bodyLen: (document.body.innerText || '').length,
    rootChildren: document.getElementById('root') ? document.getElementById('root').children.length : -1
  };
  probe.remove();
  document.body.style.overflow = '';
  return out;
}"""


def run(blocked):
    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx = b.new_context(viewport={"width": 390, "height": 844}, user_agent=UA,
                            is_mobile=True, has_touch=True, device_scale_factor=2, locale="zh-CN")
        if blocked:
            ctx.add_init_script(
                "window.__DPD_CONFIG__ = " + json.dumps(CFG, ensure_ascii=False) + ";\n" + INJECT)
        page = ctx.new_page()
        page.goto("https://dongpian17.com/", wait_until="domcontentloaded", timeout=60000)
        page.wait_for_timeout(6000)
        data = page.evaluate(PROBE)
        b.close()
        return data


if __name__ == "__main__":
    base = run(False)
    after = run(True)

    print("=== 基线（无注入）===")
    print(json.dumps(base, ensure_ascii=False, indent=2))
    print("\n=== 注入后 ===")
    print(json.dumps(after, ensure_ascii=False, indent=2))

    print("\n=== 判定 ===")
    checks = []
    b_l1 = base.get("l1") or {}
    a_l1 = after.get("l1") or {}
    total_before = sum(v["items"] + v["grid"] for v in b_l1.values() if isinstance(v, dict))
    total_after = sum(v["items"] + v["grid"] for v in a_l1.values() if isinstance(v, dict))
    checks.append(("L1 广告条目清零", total_before > 0 and total_after == 0,
                   f"{total_before} -> {total_after}"))
    checks.append(("L2 广告容器隐藏", after["l2"]["hidden"] is True,
                   f"display={after['l2']['display']}"))
    checks.append(("L2 基线对照未隐藏", base["l2"]["hidden"] is False,
                   f"display={base['l2']['display']}"))
    checks.append(("L3a 滚动锁解除", after["l3a"]["unlocked"] is True,
                   f"overflow={after['l3a']['overflowAfter']}"))
    checks.append(("L3b window.open 拦截", after["l3b"]["returnedNull"] is True,
                   str(after["l3b"])))
    same_cards = abs(base["page"]["cards"] - after["page"]["cards"]) <= 2
    checks.append(("页面主体未破坏", same_cards,
                   f"cards {base['page']['cards']} -> {after['page']['cards']}"))

    ok = True
    for name, passed, detail in checks:
        print(f"[{'PASS' if passed else 'FAIL'}] {name}  ({detail})")
        ok = ok and passed
    print("\nRESULT:", "ALL PASS" if ok else "HAS FAILURE")
    sys.exit(0 if ok else 1)
