#!/usr/bin/env python3
"""Subset LXGW WenKai Lite to the character domains needed by the app UI.

Two charset modes:
  full-cjk : ASCII + punctuation/symbol ranges + entire CJK Unified Ideographs
             U+4E00-U+9FFF (as specified for the first attempt)
  gb2312   : same base ranges, CJK narrowed to GB2312 Level-1 (3755) +
             Level-2 (3008) = 6763 common hanzi, decoded algorithmically
             from the GB2312 code grid (rows B0-D7 level 1, D8-F7 level 2)

Symbols actually used in lib/ (✓ ✗ → ← — • … etc.) are always added; the
inventory is in tool/special_chars.txt.

Usage:
  python tool/subset_font.py --mode gb2312 \
      --font fonts/LXGWWenKaiLite-Regular.ttf \
      --out  fonts/LXGWWenKaiLite-Regular-subset.ttf
"""
import argparse
import os
import sys

# (lo, hi) inclusive codepoint ranges common to both modes
BASE_RANGES = [
    (0x0020, 0x007E),  # ASCII printable
    (0x00A0, 0x00FF),  # Latin-1 Supplement (nbsp, accented latin)
    (0x2000, 0x206F),  # General Punctuation (— • … quotes)
    (0x2190, 0x21FF),  # Arrows (← →)
    (0x2500, 0x257F),  # Box Drawing
    (0x2B00, 0x2BFF),  # Misc Symbols and Arrows (⬛ ➜ …)
    (0x3000, 0x303F),  # CJK Symbols and Punctuation (、。「」《》)
    (0xFF00, 0xFFEF),  # Halfwidth and Fullwidth Forms (（），：；？)
]

# Explicit symbols found in lib/ (grep tool/special_chars.txt)
EXTRA_CPS = {0x2713, 0x2717}  # ✓ ✗ (Dingbats block, not covered above)


def gb2312_hanzi():
    """All hanzi of the GB2312 code grid: rows B0..F7, cells A1..FE."""
    cps = set()
    for hi in range(0xB0, 0xF8):
        for lo in range(0xA1, 0xFF):
            try:
                ch = bytes((hi, lo)).decode("gb2312")
            except UnicodeDecodeError:
                continue
            cp = ord(ch)
            if 0x4E00 <= cp <= 0x9FFF:
                cps.add(cp)
    return cps


def build_charset(mode):
    cps = set(EXTRA_CPS)
    for lo, hi in BASE_RANGES:
        cps.update(range(lo, hi + 1))
    if mode == "full-cjk":
        cps.update(range(0x4E00, 0x9FFF + 1))
    elif mode == "gb2312":
        g = gb2312_hanzi()
        if len(g) < 6000:
            sys.exit("error: GB2312 decode gave only %d hanzi" % len(g))
        cps.update(g)
    else:
        sys.exit("unknown mode: %s" % mode)
    return sorted(cps)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["full-cjk", "gb2312"], required=True)
    ap.add_argument("--font", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    cps = build_charset(args.mode)
    charset_path = os.path.join(here, "charset_%s.txt" % args.mode)
    with open(charset_path, "w", encoding="utf-8") as fh:
        fh.write("".join(chr(cp) for cp in cps))
    print("charset [%s]: %d codepoints -> %s" % (args.mode, len(cps), charset_path))

    from fontTools import subset as ft_subset

    argv = [
        args.font,
        "--text-file=%s" % charset_path,
        "--output-file=%s" % args.out,
        "--no-hinting",          # drop fpgm/prep/cvt + instruction data
        "--layout-features=",    # drop all GSUB/GPOS features (UI text, no shaping extras)
        "--desubroutinize",      # no-op for glyf/TTF, kept per spec
        "--no-glyph-names",      # drop 25k glyph names from glyf
        "--drop-tables+=FFTM,VDMX",
        "--ignore-missing-unicodes",
        "--name-IDs=0,1,2,3,4,5,6,14",
    ]
    ft_subset.main(argv)

    size = os.path.getsize(args.out)
    print("output: %s  %.2f MB" % (args.out, size / 1e6))

    # coverage sanity check against the produced file
    from fontTools.ttLib import TTFont

    f = TTFont(args.out, lazy=True)
    cmap = f.getBestCmap()
    need = [cp for cp in cps if cp not in cmap]
    cjk_in = sum(1 for cp in cmap if 0x4E00 <= cp <= 0x9FFF)
    print("mapped in subset: %d, requested but absent: %d, CJK glyphs: %d"
          % (len(cmap), len(need), cjk_in))
    if need:
        print("absent sample:", ", ".join("U+%04X" % cp for cp in need[:20]))


if __name__ == "__main__":
    main()
