#!/usr/bin/env python3
"""把各实验 MD 中的图片引用替换为 images/ 下同名 .md 中已识别的内容。

规则（纯程序处理，不经过任何模型）:
- 扫描 instruction/0*.md 中的 `![实验配图](images/xxx.png)` 行
- 读取 instruction/images/xxx.md，按优先级提取内容块:
  1. ```mermaid 围栏块（拓扑图）
  2. ```log 围栏块（控制台）
  3. "## 文本绘制软件界面" 小节下的 ```text 围栏块（软件界面）
- 用提取的块 + 一行来源说明替换原图片引用行

用法:
    .venv/bin/python replace_images_with_md.py [--dry-run]
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
INSTR = ROOT / "instruction"
IMG_DIR = INSTR / "images"

IMG_REF = re.compile(r"^!\[([^\]]*)\]\((images/[^)]+\.png)\)\s*$", re.M)
FENCE = re.compile(r"^```(\w*)\n(.*?)\n```", re.S | re.M)


def extract_block(img_md_text: str) -> tuple[str, str] | None:
    """从图片说明 md 中提取 (类型, 内容块)。返回 (lang, fenced_block)。"""
    # 1) mermaid 块
    for m in FENCE.finditer(img_md_text):
        if m.group(1) == "mermaid":
            return "mermaid", m.group(0)
    # 2) log 块
    for m in FENCE.finditer(img_md_text):
        if m.group(1) == "log":
            return "log", m.group(0)
    # 3) "文本绘制软件界面" 小节下的 text 块
    sec = re.search(
        r"^##\s*文本绘制软件界面\s*$(.*?)(?=^##\s|\Z)", img_md_text, re.S | re.M)
    if sec:
        m = FENCE.search(sec.group(1))
        if m:
            return "text", m.group(0)
    return None


def main() -> int:
    dry = "--dry-run" in sys.argv
    changed = 0
    for md_file in sorted(INSTR.glob("0*.md")):
        text = md_file.read_text(encoding="utf-8")
        refs = list(IMG_REF.finditer(text))
        if not refs:
            continue
        print(f"{md_file.name}: {len(refs)} 处图片引用")
        out, pos = [], 0
        for m in refs:
            img_rel = m.group(2)              # images/xxx.png
            img_md = IMG_DIR / (Path(img_rel).stem + ".md")
            out.append(text[pos:m.start()])
            pos = m.end()
            if not img_md.exists():
                print(f"  [跳过] 缺少说明文件: {img_md.name}")
                out.append(m.group(0))
                continue
            got = extract_block(img_md.read_text(encoding="utf-8"))
            if got is None:
                print(f"  [跳过] 未找到可提取内容块: {img_md.name}")
                out.append(m.group(0))
                continue
            lang, block = got
            caption = f"*图（{lang} 绘制，原图 {img_rel}）：*"
            out.append(f"{caption}\n\n{block}")
            print(f"  [替换] {img_rel} -> {lang} 块 ({len(block)} 字符)")
            changed += 1
        out.append(text[pos:])
        if not dry:
            md_file.write_text("".join(out), encoding="utf-8")

    print(f"\n共替换 {changed} 处" + ("（dry-run，未写入）" if dry else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
