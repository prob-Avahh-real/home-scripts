#!/usr/bin/env python3
"""
繁体中文字体子集化脚本 (iOS / 移动端用)

用法:
  python3 subset-tc-fonts.py font.otf
  python3 subset-tc-fonts.py --woff2 *.otf
  python3 subset-tc-fonts.py --text "自訂文字" font.otf
  python3 subset-tc-fonts.py --text-file ui.txt font.otf
  python3 subset-tc-fonts.py --common-only font.otf   # 只保留常用繁中字
  python3 subset-tc-fonts.py --full-cjk font.otf      # 保留全部 CJK

依赖:
  pip3 install fonttools brotli
"""

import argparse
import sys
from pathlib import Path

# -----------------------------------------------------------
# 字符集生成 — 全部运行时 Unicode 范围生成，不依赖嵌入字串
# -----------------------------------------------------------

# Big5 Level 1 范围: 5401 个最常用汉字对应的 Unicode
# 这些是 Big5 编码 0xA440-0xC67E 范围内有对应 Unicode 的字
# 我们从以下 Unicode 区块中选取常用字：
#   - CJK Unified Ideographs 基本区 (U+4E00–U+9FFF)
#   - CJK Compatibility Ideographs (U+F900–U+FAFF) 常用部分
# 由于 Big5 Level 1 的精确映射过长，这里使用等价策略：
#   取 CJK 基本区 + 兼容区中 Unihan kFrequency ≥ 3 的字
#   若 Unihan 数据不可用，fallback 到全部 CJK 基本区

_UNIHAN_FREQUENCY = {}  # lazy loaded


def _load_unihan_frequency() -> dict:
    """加载 Unihan kFrequency 数据（macOS 系统自带）"""
    freq = {}
    unihan_paths = [
        "/System/Library/Input Methods/ChineseIM.app/Contents/Resources/",
        "/usr/share/unicode/",
    ]
    for base in unihan_paths:
        p = Path(base) / "Unihan_IRGSources.txt"
        if p.exists():
            for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
                if not line.strip() or line.startswith("#"):
                    continue
                if "kFrequency" in line:
                    parts = line.split("\t")
                    if len(parts) >= 3:
                        try:
                            cp = int(parts[0].lstrip("U+"), 16)
                            # kFrequency 格式: 数字
                            freq_val = int(parts[2].strip())
                            freq[cp] = freq_val
                        except (ValueError, IndexError):
                            continue
            if freq:
                return freq
    return freq


def get_common_tc_chars() -> str:
    """
    常用繁中汉字。
    优先用 Unihan kFrequency 筛选常用字（频率 ≥ 3）；
    若 Unihan 不可用，返回全部 CJK 基本区 + 兼容区。
    """
    global _UNIHAN_FREQUENCY
    if not _UNIHAN_FREQUENCY:
        _UNIHAN_FREQUENCY = _load_unihan_frequency()

    chars = set()

    # CJK Unified Ideographs 基本区
    if _UNIHAN_FREQUENCY:
        for cp in range(0x4E00, 0x9FFF + 1):
            if _UNIHAN_FREQUENCY.get(cp, 0) >= 3:
                chars.add(chr(cp))
    else:
        for cp in range(0x4E00, 0x9FFF + 1):
            chars.add(chr(cp))

    # CJK Compatibility Ideographs (常见的在 F900-FAD9)
    for cp in range(0xF900, 0xFAD9 + 1):
        if not _UNIHAN_FREQUENCY or _UNIHAN_FREQUENCY.get(cp, 0) >= 3:
            chars.add(chr(cp))

    return "".join(sorted(chars))


def get_full_cjk_chars() -> str:
    """全部 CJK 统一表意文字（基本区 + Extension A + 兼容区）"""
    chars = []
    for cp in range(0x4E00, 0x9FFF + 1):
        chars.append(chr(cp))
    for cp in range(0x3400, 0x4DBF + 1):
        chars.append(chr(cp))
    for cp in range(0xF900, 0xFAFF + 1):
        chars.append(chr(cp))
    return "".join(chars)


def get_punctuation() -> str:
    """标点、数字、英文、注音 — 全部 Unicode 范围实时生成"""
    parts = []
    # 中文标点 (U+3000–U+303F)
    parts.append("".join(chr(c) for c in range(0x3000, 0x303F + 1)))
    # 半角英文标点 + 空格
    parts.append("".join(chr(c) for c in range(0x20, 0x7F + 1)))
    # 全角英数字 (U+FF01–U+FF5E)
    parts.append("".join(chr(c) for c in range(0xFF01, 0xFF5F + 1)))
    # 注音符号 (U+3100–U+312F)
    parts.append("".join(chr(c) for c in range(0x3100, 0x312F + 1)))
    # 全角空格
    parts.append("\u3000")
    # 常用箭头 (U+2190–U+21FF)
    parts.append("".join(chr(c) for c in range(0x2190, 0x21FF + 1)))
    # 带圈数字 (U+2460–U+2473)
    parts.append("".join(chr(c) for c in range(0x2460, 0x2474 + 1)))
    # 带括号数字 (U+3220–U+3243)
    parts.append("".join(chr(c) for c in range(0x3220, 0x3244 + 1)))
    # 几何图形 (U+25A0–U+25FF)
    parts.append("".join(chr(c) for c in range(0x25A0, 0x25FF + 1)))
    # 货币符号 (U+00A3 £, U+00A5 ¥, U+20AC €)
    parts.append("£¥€$￥＄￡")
    # 度数/编号
    parts.append("℃℉№")
    # 音乐符号
    parts.append("♪♫♯")

    return "".join(parts)


# -----------------------------------------------------------
# 字体子集化核心
# -----------------------------------------------------------

def check_fonttools() -> bool:
    try:
        from fontTools.subset import main as subset_main  # noqa: F401
        return True
    except ImportError:
        return False


def subset_font(font_path: Path, text: str, output_dir: Path,
                woff2: bool = False, verbose: bool = False) -> bool:
    from fontTools.subset import main as subset_main

    orig_size = font_path.stat().st_size
    name = font_path.stem
    ext = font_path.suffix

    if woff2:
        out_path = output_dir / f"{name}-subset.woff2"
    else:
        out_path = output_dir / f"{name}-subset{ext}"

    unique = "".join(dict.fromkeys(text))

    args = [
        str(font_path),
        f"--text={unique}",
        f"--output-file={out_path}",
        "--layout-features=*",
        "--desubroutinize",
        "--no-hinting",
        "--name-IDs=*",
        "--drop-tables+=DSIG",
    ]
    if woff2:
        args.append("--flavor=woff2")

    if verbose:
        cmd = " ".join(f"'{a}'" if " " in a else a for a in args)
        print(f"  pyftsubset {cmd}")

    try:
        subset_main(args)
    except SystemExit as e:
        if e.code != 0:
            print(f"  [错误] pyftsubset 退出码: {e.code}")
            return False

    if out_path.exists():
        new_size = out_path.stat().st_size
        ratio = (1 - new_size / orig_size) * 100 if orig_size > 0 else 0
        print(f"  {font_path.name}")
        print(f"    {format_size(orig_size)} → {format_size(new_size)}  (-{ratio:.1f}%)")
        print(f"    → {out_path}")
        return True
    else:
        print(f"  [失败] 未生成: {out_path}")
        return False


def format_size(size: int) -> str:
    for unit in ("B", "KB", "MB", "GB"):
        if size < 1024:
            return f"{size:.1f} {unit}"
        size /= 1024
    return f"{size:.1f} TB"


# -----------------------------------------------------------
# 主入口
# -----------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="繁体中文字体子集化脚本 (iOS / 移动端用)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  %(prog)s SourceHanSansTC-Regular.otf
  %(prog)s --woff2 *.otf
  %(prog)s --text "我的App專用詞彙" font.otf
  %(prog)s --text-file ui_strings.txt font.otf
  %(prog)s --common-only font.otf
  %(prog)s --full-cjk font.otf
  %(prog)s --text-only --text "我的文案" font.otf
        """,
    )
    parser.add_argument("fonts", nargs="+", help="字体文件路径（支持通配符）")
    parser.add_argument("--text", default="", help="追加自订文字")
    parser.add_argument("--text-file", help="从文件读取追加文字")
    parser.add_argument("--woff2", action="store_true",
                        help="输出 woff2 格式 (更小, iOS 14+)")
    parser.add_argument("--output-dir", default="./subset-fonts",
                        help="输出目录 (默认: ./subset-fonts)")
    parser.add_argument("--common-only", action="store_true",
                        help="仅使用常用繁中字表，体积最小")
    parser.add_argument("--text-only", action="store_true",
                        help="仅使用自订文字 + 标点，不含预设字表（最小体积）")
    parser.add_argument("--full-cjk", action="store_true",
                        help="包含全部 CJK (~27,000 字)，覆盖最全")
    parser.add_argument("--verbose", "-v", action="store_true",
                        help="显示完整 pyftsubset 命令")
    args = parser.parse_args()

    if not check_fonttools():
        print("[错误] 未安装 fonttools，请先执行:")
        print("  pip3 install fonttools brotli")
        sys.exit(1)

    # 构建字符集
    if args.full_cjk:
        text = get_full_cjk_chars()
        print(f"[字表] 全 CJK 模式: {len(text)} 个汉字")
    elif args.text_only:
        text = get_punctuation()
        print(f"[字表] 自定义模式: {len(text)} 个基础符号")
    elif args.common_only:
        text = get_common_tc_chars()
        print(f"[字表] 常用字模式: {len(text)} 个汉字")
    else:
        text = get_common_tc_chars() + get_punctuation()
        print(f"[字表] 默认模式: {len(text)} 个字符")

    # 追加自定义文字
    if args.text:
        text += args.text
        print(f"[追加] --text: {len(args.text)} 个字符")

    if args.text_file:
        tf = Path(args.text_file)
        if not tf.exists():
            print(f"[错误] 找不到文件: {args.text_file}")
            sys.exit(1)
        file_text = tf.read_text(encoding="utf-8").replace("\n", "")
        text += file_text
        print(f"[追加] --text-file: {len(file_text)} 个字符")

    # 去重
    text = "".join(dict.fromkeys(text))
    print(f"[去重] 最终 {len(text)} 个不重复字符")

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    success = 0
    fail = 0
    for pattern in args.fonts:
        import glob
        for font_file in glob.glob(pattern):
            fp = Path(font_file)
            if not fp.exists():
                print(f"[跳过] 找不到: {font_file}")
                fail += 1
                continue
            if fp.suffix.lower() not in (".otf", ".ttf", ".woff", ".woff2"):
                print(f"[跳过] 不支持的格式: {font_file}")
                fail += 1
                continue

            print()
            if subset_font(fp, text, output_dir, args.woff2, args.verbose):
                success += 1
            else:
                fail += 1

    print(f"\n{'='*50}")
    print(f"完成: {success} 成功, {fail} 失败")
    if success > 0:
        print(f"输出: {output_dir.resolve()}")
        for f in sorted(output_dir.iterdir()):
            print(f"  {f.name}  ({format_size(f.stat().st_size)})")


if __name__ == "__main__":
    main()