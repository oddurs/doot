#!/usr/bin/env python3
"""Generate the benchmark corpora.

The corpora are committed as files rather than generated at run time, so the
bench measures the terminal and not this script, and so a number from today is
comparable with a number from six months ago. Re-run this only to add a corpus
or deliberately change one -- regenerating for no reason invalidates every
baseline that came before it.

Output is what a PTY actually delivers: the line discipline turns \\n into
\\r\\n on the way out, so that is what these files contain.
"""

import random
import pathlib

TARGET = 256 * 1024  # bytes per corpus
OUT = pathlib.Path(__file__).parent / "corpus"

IDENTS = [
    "parser", "cursor", "screen", "scrollback", "glyph", "atlas", "terminal",
    "renderer", "viewport", "codepoint", "attrs", "palette", "damage", "cell",
    "region", "pending_wrap", "alt_screen", "metrics", "baseline", "advance",
]
KEYWORDS = ["const", "var", "fn", "pub", "if", "else", "while", "for", "switch",
            "return", "try", "defer", "struct", "enum", "union", "inline"]


def cap(buf: list, name: str) -> bytes:
    out = b"".join(buf)[:TARGET]
    (OUT / name).write_bytes(out)
    print(f"{name:16} {len(out):>8} bytes")
    return out


def gen_ascii(rng):
    """Plain source-like text. The `cat a big file` case: no escapes at all,
    which is the pure printable-run path Sprint 4 targets."""
    buf = []
    total = 0
    while total < TARGET:
        indent = " " * (4 * rng.randint(0, 3))
        kw = rng.choice(KEYWORDS)
        a, b = rng.choice(IDENTS), rng.choice(IDENTS)
        line = f"{indent}{kw} {a} = {b}.{rng.choice(IDENTS)}({rng.randint(0, 4096)});"
        if rng.random() < 0.12:
            line = f"{indent}// {' '.join(rng.choice(IDENTS) for _ in range(rng.randint(3, 9)))}"
        raw = (line + "\r\n").encode()
        buf.append(raw)
        total += len(raw)
    return cap(buf, "ascii.bin")


def gen_sgr(rng):
    """A colourised build log. Dense SGR churn -- the case that defeats
    background-run detection and forces a colour change per glyph."""
    buf = []
    total = 0
    levels = [
        (b"\x1b[1;32m", b"ok  "), (b"\x1b[1;33m", b"warn"),
        (b"\x1b[1;31m", b"err "), (b"\x1b[1;36m", b"info"),
    ]
    while total < TARGET:
        col, tag = rng.choice(levels)
        parts = [col, tag, b"\x1b[0m ", b"\x1b[2m", f"{rng.randint(0,999999):06d}".encode(), b"\x1b[0m "]
        for _ in range(rng.randint(3, 8)):
            r = rng.random()
            if r < 0.35:
                parts.append(f"\x1b[38;5;{rng.randint(16,231)}m".encode())
            elif r < 0.6:
                parts.append(f"\x1b[38;2;{rng.randint(0,255)};{rng.randint(0,255)};{rng.randint(0,255)}m".encode())
            else:
                parts.append(f"\x1b[{rng.choice([1,2,3,4,7,22,24,27])}m".encode())
            parts.append(rng.choice(IDENTS).encode())
            parts.append(b" ")
        parts.append(b"\x1b[0m\r\n")
        raw = b"".join(parts)
        buf.append(raw)
        total += len(raw)
    return cap(buf, "sgr.bin")


def gen_scroll(rng):
    """Short lines, nothing but scrolling. Every line costs a full-screen
    shift at 24 rows, so this isolates the scroll path from the print path."""
    buf = []
    total = 0
    while total < TARGET:
        raw = f"{rng.randint(0, 99999):>7} {rng.choice(IDENTS)}\r\n".encode()
        buf.append(raw)
        total += len(raw)
    return cap(buf, "scroll.bin")


def gen_altscreen(rng):
    """A full-screen application redrawing itself: alt screen, absolute
    cursor addressing, erase-to-end-of-line, a reverse-video status bar.
    The interactive case -- what vim or htop actually puts on the wire."""
    buf = [b"\x1b[?1049h\x1b[2J"]
    total = len(buf[0])
    rows, cols = 24, 80
    while total < TARGET:
        frame = [b"\x1b[H"]
        for y in range(1, rows):
            frame.append(f"\x1b[{y};1H".encode())
            frame.append(b"\x1b[K")
            text = " ".join(rng.choice(IDENTS) for _ in range(rng.randint(2, 6)))
            if rng.random() < 0.25:
                frame.append(b"\x1b[1;34m" + text[:cols].encode() + b"\x1b[0m")
            else:
                frame.append(text[:cols].encode())
        frame.append(f"\x1b[{rows};1H\x1b[7m".encode())
        frame.append(f" line {rng.randint(1,9999):<5} col {rng.randint(1,200):<4} ".ljust(cols)[:cols].encode())
        frame.append(b"\x1b[0m")
        raw = b"".join(frame)
        buf.append(raw)
        total += len(raw)
    buf.append(b"\x1b[?1049l")
    return cap(buf, "altscreen.bin")


def gen_cjk(rng):
    """Wide and multibyte text. Exercises the UTF-8 decoder, charWidth, and
    the wide/spacer cell pairing that a printable-run fast path must not
    break."""
    han = "処理端末画面文字列描画状態機械入力出力走査行列幅高描画器"
    kana = "ターミナルエミュレータバッファスクロール"
    buf = []
    total = 0
    while total < TARGET:
        n = rng.randint(4, 14)
        src = han if rng.random() < 0.6 else kana
        text = "".join(rng.choice(src) for _ in range(n))
        if rng.random() < 0.4:
            text += " " + rng.choice(IDENTS)
        raw = (text + "\r\n").encode("utf-8")
        buf.append(raw)
        total += len(raw)
    return cap(buf, "cjk.bin")


def gen_region(rng):
    """A full-screen app with a status line: DECSTBM carves out rows 1-23
    and everything scrolls inside that region, leaving row 24 alone. This is
    what vim, less and tmux actually do, and it is the case a whole-screen
    scroll fast path does *not* cover."""
    buf = [b"\x1b[?1049h\x1b[2J\x1b[1;23r"]
    total = len(buf[0])
    while total < TARGET:
        frame = []
        # Output inside the region, scrolling it line by line.
        for _ in range(rng.randint(4, 20)):
            text = " ".join(rng.choice(IDENTS) for _ in range(rng.randint(3, 8)))
            frame.append(text[:79].encode() + b"\r\n")
        # Repaint the status line outside the region, cursor saved/restored.
        frame.append(b"\x1b7\x1b[24;1H\x1b[7m")
        frame.append(f" {rng.choice(IDENTS)}  {rng.randint(1,9999):>5}/{rng.randint(1,9999):<5} ".ljust(80)[:80].encode())
        frame.append(b"\x1b[0m\x1b8")
        raw = b"".join(frame)
        buf.append(raw)
        total += len(raw)
    buf.append(b"\x1b[r\x1b[?1049l")
    return cap(buf, "region.bin")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    # Each corpus gets its own seed, so adding a sixth generator later does
    # not shift the bytes of the first five and quietly void their baselines.
    for i, gen in enumerate((gen_ascii, gen_sgr, gen_scroll, gen_altscreen, gen_cjk, gen_region)):
        gen(random.Random(0xC0FFEE + i))


if __name__ == "__main__":
    main()
