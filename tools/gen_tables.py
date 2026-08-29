#!/usr/bin/env python3
"""
Generate src/mp3/tables.luau from minimp3.h.

minimp3 (https://github.com/lieff/minimp3) is public domain software.
This script mechanically extracts the numeric tables so the Luau port of the
decoder uses exactly the same data as the C implementation (0-based indexing
is preserved via explicit [0]=... Luau table constructors).

Usage:
    python3 tools/gen_tables.py [path/to/minimp3.h] [out/tables.luau]

If the source header is missing it is downloaded from GitHub.
"""

import json
import os
import re
import sys
import urllib.request

DEFAULT_URL = "https://raw.githubusercontent.com/lieff/minimp3/master/minimp3.h"

# name -> nesting shape ("int" / "float" scalar type, list of dimensions)
TABLES = {
    "halfrate":         (2, 3, 15),   # [2][3][15]
    "g_hz":             (3,),
    "g_pow43":          (145,),
    "tabs":             (None,),      # flattened, keep flat
    "tab32":            (28,),
    "tab33":            (16,),
    "tabindex":         (32,),
    "g_linbits":        (32,),
    "g_pan":            (14,),
    "g_scf_long":       (8, 23),
    "g_scf_short":      (8, 40),
    "g_scf_mixed":      (8, 40),
    "g_expfrac":        (4,),
    "g_scf_partitions": (3, 28),
    "g_scfc_decode":    (16,),
    "g_mod":            (24,),
    "g_preamp":         (10,),
    "g_aa":             (2, 8),
    "g_twid9":          (18,),
    "g_twid3":          (6,),
    "g_mdct_window":    (2, 18),
    "g_sec":            (24,),
    "g_win":            (240,),
}

INT_TABLES = {
    "halfrate", "g_hz", "tabs", "tab32", "tab33", "tabindex", "g_linbits",
    "g_scf_long", "g_scf_short", "g_scf_mixed", "g_scf_partitions",
    "g_scfc_decode", "g_mod", "g_preamp",
}

FLOAT_FMT = "%.10g"


def load_source(path: str) -> str:
    if path and os.path.exists(path):
        with open(path, "r", encoding="utf-8") as f:
            src = f.read()
    else:
        print("minimp3.h not found locally, downloading...")
        with urllib.request.urlopen(DEFAULT_URL) as r:
            src = r.read().decode("utf-8")
    # strip comments so brace parsing is safe
    src = re.sub(r"/\*.*?\*/", " ", src, flags=re.S)
    src = re.sub(r"//[^\n]*", " ", src)
    return src


NUM_RE = re.compile(
    r"-?\d+\.\d*(?:[eE][-+]?\d+)?f?|-?\.\d+(?:[eE][-+]?\d+)?f?|"
    r"-?\d+[eE][-+]?\d+f?|-?\d+f?"
)


def extract_arrays(src: str):
    """Return {name: nested lists of number strings} for every `static const type name[..] = { .. };`"""
    out = {}
    pat = re.compile(r"static\s+const\s+\w+\s+(\w+)\s*((?:\[[^\]]*\])+)\s*=\s*\{", re.S)
    for m in pat.finditer(src):
        name = m.group(1)
        start = m.end() - 1  # position of opening '{'
        body, _ = _parse_braces(src, start)
        out[name] = body
    return out


def _parse_braces(src: str, i: int):
    """Parse a brace group starting at src[i] == '{'.
    Returns (list, next_index). The list contains either number strings or
    nested lists (for inner brace groups)."""
    assert src[i] == "{"
    i += 1
    items = []
    while True:
        while src[i] in " \t\r\n,":
            i += 1
        if src[i] == "}":
            return items, i + 1
        if src[i] == "{":
            sub, i = _parse_braces(src, i)
            items.append(sub)
        else:
            j = i
            while src[j] not in ",}":
                j += 1
            token = src[i:j].strip()
            if NUM_RE.fullmatch(token):
                items.append(token)
            i = j


def to_num(text: str, is_int: bool):
    text = text.strip()
    if text.endswith("f"):
        text = text[:-1]
    if is_int:
        return str(int(float(text)))
    v = float(text)
    return FLOAT_FMT % v


def emit(node, shape, is_int, indent):
    """Emit a 0-based nested Luau table constructor (zero-padded like C)."""
    if shape == (None,):  # flat, keep all values
        vals = [to_num(v, is_int) for v in node]
        return "{ [0]=" + ", ".join(vals) + " }" if vals else "{}"
    if len(shape) == 1:
        size = shape[0]
        vals = [to_num(v, is_int) for v in node[:size]]
        while len(vals) < size:  # C zero-fills missing trailing initializers
            vals.append("0")
        return "{ [0]=" + ", ".join(vals) + " }"
    size = shape[0]
    rows = []
    for r in range(size):
        sub = node[r] if r < len(node) else []
        rows.append("[%d]=" % r + emit(sub, shape[1:], is_int, indent + 1))
    pad = "\t" * (indent + 1)
    return "{\n" + pad + (",\n" + pad).join(rows) + "\n" + "\t" * indent + "}"


def count_leaves(node):
    total = 0
    for item in node:
        total += count_leaves(item) if isinstance(item, list) else 1
    return total


def main():
    src_path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/minimp3.h"
    out_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(__file__), "..", "src", "mp3", "tables.luau"
    )
    src = load_source(src_path)
    arrays = extract_arrays(src)

    lines = [
        "--!nolint",
        "-- GENERATED FILE - do not edit by hand.",
        "-- Generated by tools/gen_tables.py from minimp3.h (public domain,",
        "-- https://github.com/lieff/minimp3). All tables keep C 0-based",
        "-- indexing via explicit [0]=... entries.",
        "",
        "local tables = {}",
        "",
    ]
    for name, shape in TABLES.items():
        if name not in arrays:
            raise SystemExit("table %s not found in source" % name)
        node = arrays[name]
        if shape != (None,):
            expected = 1
            for d in shape:
                expected *= d
            found = count_leaves(node)
            if found > expected:
                raise SystemExit(
                    "table %s: expected %d values, found %d" % (name, expected, found)
                )
        is_int = name in INT_TABLES
        body = emit(node, shape, is_int, 1)
        lines.append("tables.%s = %s" % (name, body))
        lines.append("")

    lines.append("return tables")
    lines.append("")

    out = "\n".join(lines)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(out)
    print("wrote %s (%d bytes)" % (out_path, len(out)))


if __name__ == "__main__":
    main()
