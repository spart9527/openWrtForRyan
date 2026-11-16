#!/usr/bin/env python3
"""删掉 Kwrt luci-mod-status 概览“系统”卡片底部的作者外链行。

kiddin9 的 luci-mod-status（op-packages）在 10_system.js 里加了：
    if (uci.get('system', '@system[0]', 'links') !== '0') { ...固件下载与定制 / 赞助 / 源码与反馈 / TG交流... }
这里按花括号配对把整个 if 块删掉。改的是源码（未压缩），编译时再压缩进固件。
用法：strip-status-links.py <10_system.js> ...
找到外链字符串却删不掉时退出码为 1，让编译直接失败。
"""
import re
import sys

MARKERS = ("固件下载与定制", "TG交流", "t.me/opkwrt", "openwrt.ai/fadian")
COND = re.compile(r"if\s*\(\s*uci\.get\(\s*'system'\s*,\s*'@system\[0\]'\s*,\s*'links'\s*\)\s*!==?\s*'0'\s*\)\s*\{")


def strip_block(src):
    m = COND.search(src)
    if not m:
        return src, False
    depth = 0
    i = m.end() - 1  # 指向 if 块的 {
    quote = None
    while i < len(src):
        c = src[i]
        if quote:
            if c == "\\":
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in "'\"`":
            quote = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                end = i + 1
                # 连同前面的缩进和后面的换行一起删
                start = src.rfind("\n", 0, m.start()) + 1
                if src[start:m.start()].strip():
                    start = m.start()
                if end < len(src) and src[end] == "\n":
                    end += 1
                return src[:start] + src[end:], True
        i += 1
    return src, False


rc = 0
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as f:
        src = f.read()
    if not any(k in src for k in MARKERS):
        print(f"strip-status-links: {path}: no author links, skip")
        continue
    new, changed = strip_block(src)
    left = [k for k in MARKERS if k in new]
    if not changed or left:
        print(f"ERROR: strip-status-links: {path}: author links still present: {left}", file=sys.stderr)
        rc = 1
        continue
    with open(path, "w", encoding="utf-8") as f:
        f.write(new)
    print(f"strip-status-links: {path}: removed author links row")
sys.exit(rc)
