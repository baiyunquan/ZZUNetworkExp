#!/usr/bin/env python3
"""实验2 Firefox 自动化截图（Playwright 驱动真实 Firefox）。

分工:
- https://www.zzu.edu.cn 访问截图 -> 本脚本无头完成（步骤2(4)）
- about:networking#dnslookuptool 内部页 -> Firefox 安全模型禁止内容级
  跳转，须用 shell/screenshot_toolkit.sh firefox 启动时传 URL（步骤1(4)）
  DNS 解析数据的 CLI 证据已由 step1_check_env.sh 的 getent 输出提供。

用法:
    .venv/bin/python firefox_screenshot.py [输出目录，默认 /tmp/exp2_shots]
"""

import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/exp2_shots")
SITE = "www.zzu.edu.cn"


def shot_site(browser) -> None:
    """步骤2(4): 访问 https://www.zzu.edu.cn。"""
    page = browser.new_page(viewport={"width": 1280, "height": 800})
    page.goto(f"https://{SITE}", wait_until="domcontentloaded", timeout=30000)
    page.wait_for_timeout(3000)
    out = OUT / "exp2_step2_site.png"
    page.screenshot(path=str(out), full_page=False)
    print(f"  [截图] {out}")
    page.close()


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        browser = p.firefox.launch(headless=True)
        print("==> 步骤2(4): 访问 https://www.zzu.edu.cn")
        shot_site(browser)
        browser.close()
    print(f"\n完成，截图目录: {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
