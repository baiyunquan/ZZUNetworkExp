#!/usr/bin/env python3
"""把 instruction/ 下的分节 HTML 转换为 Markdown。

转换规则:
- h1/h2/h3 -> #/##/###
- div.codeblock (含 div.code-cap 语言标签 + pre>code) -> ```lang 围栏代码块
- figure>img -> ![alt](images/xxx.png)
- ul/li -> 列表, strong -> **, em -> *, 行内 code -> `
- 剔除 <!--pnid:...--> 注释等站点元数据

用法:
    .venv/bin/python convert_to_md.py
"""

import re
import sys
from pathlib import Path

from bs4 import BeautifulSoup, Comment, NavigableString, Tag

ROOT = Path(__file__).resolve().parent
OUT_DIR = ROOT / "instruction"

SECTIONS = [
    "00_实验基础知识",
    "01_实验1",
    "02_实验2",
    "03_实验3",
    "04_实验4",
    "05_实验5",
    "06_实验6",
]


def clean_text(s: str) -> str:
    """去掉 pnid 注释残留并压缩空白。

    注意: BS4 的 html.parser 会把注释解析为 Comment 对象且 str() 不含
    <!-- --> 分隔符，因此这里还要兜底清除 pnid:xxx 残留。
    """
    s = re.sub(r"<!--pnid:[^>]*-->", "", s)
    s = re.sub(r"pnid:[A-Za-z0-9]+", "", s)
    return s


def inline_md(node) -> str:
    """递归转换行内内容为 Markdown 文本。"""
    if isinstance(node, Comment):
        return ""
    if isinstance(node, NavigableString):
        return clean_text(str(node))
    if not isinstance(node, Tag):
        return ""
    name = node.name
    if name in ("strong", "b"):
        inner = inline_children(node).strip()
        return f"**{inner}**" if inner else ""
    if name in ("em", "i"):
        inner = inline_children(node).strip()
        return f"*{inner}*" if inner else ""
    if name == "code":
        inner = clean_text(node.get_text()).strip()
        # 行内代码含反引号时用双反引号包裹
        if "`" in inner:
            return f"`` {inner} ``"
        return f"`{inner}`" if inner else ""
    if name == "br":
        return "  \n"
    if name == "img":
        alt = node.get("alt", "").strip() or "图片"
        src = node.get("src", "").strip()
        return f"![{alt}]({src})"
    if name == "a":
        href = node.get("href", "")
        return f"[{inline_children(node)}]({href})"
    return inline_children(node)


def inline_children(node: Tag) -> str:
    return "".join(inline_md(c) for c in node.children)


def block_md(node: Tag) -> str:
    """转换块级元素为 Markdown 块（以换行结尾）。"""
    name = node.name

    if name == "h1":
        return f"# {inline_children(node).strip()}\n\n"
    if name in ("h2", "h3", "h4"):
        level = int(name[1])
        return f"{'#' * level} {inline_children(node).strip()}\n\n"

    if name == "p":
        text = inline_children(node).strip()
        return f"{text}\n\n" if text else ""

    if name == "div" and "codeblock" in (node.get("class") or []):
        cap = node.find(class_="code-cap")
        lang = cap.get_text(strip=True).lower() if cap else ""
        lang = {"bash": "bash", "shell": "bash", "": ""}.get(lang, lang)
        pre = node.find("pre")
        code = clean_text(pre.get_text()).strip("\n") if pre else ""
        return f"```{lang}\n{code}\n```\n\n"

    if name == "pre":
        code = clean_text(node.get_text()).strip("\n")
        return f"```\n{code}\n```\n\n"

    if name == "figure":
        # figure 内的 img 已由 inline 处理，这里兜底转换子元素
        return "".join(block_md(c) for c in node.children if isinstance(c, Tag))

    if name == "img":
        alt = node.get("alt", "").strip() or "图片"
        return f"![{alt}]({node.get('src', '').strip()})\n\n"

    if name in ("ul", "ol"):
        lines = []
        for i, li in enumerate(node.find_all("li", recursive=False), 1):
            marker = f"{i}. " if name == "ol" else "- "
            # 处理 li 内可能嵌套的列表
            nested = ""
            children = [c for c in li.children]
            sub_lists = [c for c in children if isinstance(c, Tag) and c.name in ("ul", "ol")]
            for sl in sub_lists:
                sl.extract()
            text = inline_children(li).strip()
            lines.append(f"{marker}{text}")
            for sl in sub_lists:
                for j, sli in enumerate(sl.find_all("li", recursive=False), 1):
                    smarker = f"{j}. " if sl.name == "ol" else "- "
                    lines.append(f"  {smarker}{inline_children(sli).strip()}")
        return "\n".join(lines) + "\n\n"

    if name == "table":
        rows = []
        for tr in node.find_all("tr"):
            cells = [inline_children(td).strip().replace("|", "\\|")
                     for td in tr.find_all(["td", "th"])]
            rows.append("| " + " | ".join(cells) + " |")
        if rows:
            rows.insert(1, "|" + "---|" * len(rows[0].split("|"))[:-1])
        return "\n".join(rows) + "\n\n"

    # 未知块级元素：递归处理子块
    inner = "".join(block_md(c) for c in node.children if isinstance(c, Tag))
    if not inner:
        text = inline_children(node).strip()
        inner = f"{text}\n\n" if text else ""
    return inner


def convert(html: str) -> str:
    soup = BeautifulSoup(html, "html.parser")
    body = soup.body or soup
    md = "".join(block_md(c) for c in body.children if isinstance(c, Tag))
    # 合并相邻加粗: **A****B** -> **AB**（源文档常把一句话拆成多个 <strong>）
    while "****" in md:
        md = md.replace("****", "")
    # 规范化: 3+ 连续空行 -> 2 空行
    md = re.sub(r"\n{3,}", "\n\n", md)
    return md.strip() + "\n"


def main() -> int:
    for name in SECTIONS:
        src = OUT_DIR / f"{name}.html"
        if not src.exists():
            print(f"跳过(不存在): {src.name}")
            continue
        md = convert(src.read_text(encoding="utf-8"))
        dest = OUT_DIR / f"{name}.md"
        dest.write_text(md, encoding="utf-8")
        print(f"{src.name} -> {dest.name} ({len(md)} 字符)")
    print("转换完成")
    return 0


if __name__ == "__main__":
    sys.exit(main())
