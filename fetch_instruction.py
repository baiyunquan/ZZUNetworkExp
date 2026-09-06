"""抓取 WorkBuddy 上的《计算机网络实验指导书（2026版）》全部实验内容（含图片），
原样输出到 instruction/ 文件夹。

实现思路:
1. 用 Playwright 打开分享页，拿到内容 iframe 的真实静态 HTML 地址（CDN）。
2. 用 requests 下载该 HTML 原样保存，并解析其中所有 <img>，下载到 instruction/images/。
   （HTML 中图片本来就是相对路径 images/xxx.png，保存到同级目录即可原样显示）
3. 用 BeautifulSoup 按一级标题切分出「实验基础知识 + 实验1~实验6」共 7 个分节 HTML，
   并生成 index.html 导航页。

用法:
    .venv/bin/python fetch_instruction.py
"""

import hashlib
import re
import sys
from pathlib import Path
from urllib.parse import urljoin, urlparse, unquote

import requests
from bs4 import BeautifulSoup
from playwright.sync_api import sync_playwright

SHARE_URL = "https://www.workbuddy.link/p/t4izYyxPCawf5yOOUbH09N?source=2"
ROOT = Path(__file__).resolve().parent
OUT_DIR = ROOT / "instruction"
IMG_DIR = OUT_DIR / "images"

# 分节标题关键字 -> 输出文件名
SECTIONS = [
    ("实验基础知识", "00_实验基础知识"),
    ("实验1", "01_实验1"),
    ("实验2", "02_实验2"),
    ("实验3", "03_实验3"),
    ("实验4", "04_实验4"),
    ("实验5", "05_实验5"),
    ("实验6", "06_实验6"),
]

PAGE_CSS = """
body { font-family: "Noto Sans CJK SC","Microsoft YaHei",sans-serif; max-width: 920px;
       margin: 2rem auto; padding: 0 1rem; line-height: 1.85; color: #1a1a1a; }
pre { background: #f5f7fa; padding: .8rem 1rem; border-radius: 6px; overflow-x: auto; }
code { font-family: "JetBrains Mono",Consolas,monospace; }
img { max-width: 100%; }
table { border-collapse: collapse; } th, td { border: 1px solid #ccc; padding: 4px 10px; }
h1 { border-bottom: 2px solid #eee; padding-bottom: .3rem; }
nav.toc a { display: block; padding: .4rem .8rem; color: #2563eb; text-decoration: none;
            border-radius: 6px; }
nav.toc a:hover { background: #eff6ff; }
"""


def discover_iframe_url() -> str:
    """打开分享页，返回内容 iframe 的静态 HTML 地址。"""
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()
        page.goto(SHARE_URL, wait_until="domcontentloaded", timeout=120000)
        frame_el = page.wait_for_selector("iframe", timeout=60000)
        # 等待 iframe 内容真正加载出 src
        page.wait_for_function(
            "() => { const f = document.querySelector('iframe');"
            " return f && f.src && !f.src.startsWith('about'); }",
            timeout=60000,
        )
        src = frame_el.get_attribute("src") or frame_el.evaluate("e => e.src")
        browser.close()
    if not src:
        raise RuntimeError("未找到内容 iframe")
    return src


def download(session: requests.Session, url: str, dest: Path) -> None:
    if dest.exists():
        return
    resp = session.get(url, timeout=60)
    resp.raise_for_status()
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(resp.content)
    print(f"  [下载] {urlparse(url).path.split('/')[-1]} -> {dest.relative_to(ROOT)}")


def local_filename(url: str) -> str:
    """根据 URL 生成稳定的本地文件名。"""
    name = unquote(urlparse(url).path.split("/")[-1])
    return re.sub(r"[^\w.\-\u4e00-\u9fff]", "_", name) or \
        f"img_{hashlib.md5(url.encode()).hexdigest()[:8]}"


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    session = requests.Session()
    session.headers["User-Agent"] = (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/126.0 Safari/537.36"
    )

    print("步骤1: 解析分享页，定位内容 iframe ...")
    iframe_url = discover_iframe_url()
    print(f"  内容地址: {iframe_url}")

    print("步骤2: 下载原始 HTML 与全部图片 ...")
    html_resp = session.get(iframe_url, timeout=60)
    html_resp.raise_for_status()
    raw_html = html_resp.content.decode("utf-8")

    # 原样保存整份指导书（仅去掉站点注入脚本，避免本地 404）
    raw_html = re.sub(
        r'<script[^>]*src="/page/page_comm/inject\.js"[^>]*></script>', "", raw_html)
    m = re.search(r"<h1[^>]*>(.*?)</h1>", raw_html, re.S)
    doc_title = re.sub(r"<[^>]+>", "", m.group(1)).strip() if m else "指导书"
    raw_file = OUT_DIR / f"{doc_title}.html"
    raw_file.write_text(raw_html, encoding="utf-8")
    print(f"  原样保存: {raw_file.name} ({len(raw_html)} 字符)")

    # 下载全部图片（HTML 内为相对路径 images/...，与保存位置对应）
    soup = BeautifulSoup(raw_html, "html.parser")
    for img in soup.find_all("img"):
        src = img.get("src") or img.get("data-src")
        if not src:
            continue
        abs_url = urljoin(iframe_url, src)
        download(session, abs_url, IMG_DIR / local_filename(abs_url))

    print("步骤3: 按实验切分分节 HTML ...")
    body = soup.body or soup
    main = body.find("main") or body
    panels = main.find_all("section", class_="panel") or \
        [c for c in main.children if getattr(c, "name", None) == "section"]
    if len(panels) != len(SECTIONS):
        print(f"  警告: 仅找到 {len(panels)}/{len(SECTIONS)} 个分节 panel")

    toc_items = []
    for i, (key, fname) in enumerate(SECTIONS):
        if i >= len(panels):
            break
        panel = panels[i]
        title = panel.find("h1").get_text(strip=True) if panel.find("h1") else key
        out = OUT_DIR / f"{fname}.html"
        out.write_text(
            f'<!DOCTYPE html>\n<html lang="zh-CN">\n<head>\n<meta charset="UTF-8">\n'
            f"<title>{title}</title>\n<style>{PAGE_CSS}</style>\n</head>\n<body>\n"
            f"{panel.decode_contents()}\n</body>\n</html>\n",
            encoding="utf-8",
        )
        toc_items.append((title, out.name))
        print(f"  [{i + 1}/{len(SECTIONS)}] {title} -> {out.name}")

    # 生成导航首页
    links = "\n".join(f'<a href="{f}">{t}</a>' for t, f in toc_items)
    (OUT_DIR / "index.html").write_text(
        f'<!DOCTYPE html>\n<html lang="zh-CN">\n<head>\n<meta charset="UTF-8">\n'
        f"<title>{doc_title}</title>\n<style>{PAGE_CSS}</style>\n</head>\n<body>\n"
        f"<h1>{doc_title}</h1>\n"
        f'<p>来源: <a href="{SHARE_URL}">{SHARE_URL}</a></p>\n'
        f'<nav class="toc">\n{links}\n</nav>\n'
        f'<p>完整原样文档: <a href="{raw_file.name}">{raw_file.name}</a></p>\n'
        f"</body>\n</html>\n",
        encoding="utf-8",
    )
    print("  导航页 -> index.html")

    print(f"\n完成！输出目录: {OUT_DIR}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
