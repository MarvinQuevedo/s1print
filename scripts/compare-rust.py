#!/usr/bin/env python3
"""Compare the Rust core against the live, unmodified Swift implementation."""
import argparse
import collections
import binascii
import json
import pathlib
import random
import struct
import subprocess
import sys
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]


def page(w, h, pixels, dpi=203):
    return dict(width=w, height=h, dpi=dpi, pixels=pixels)


def raster(fmt, bpp, cs, w, h, data, dpi=203, count=1):
    if fmt == "pwg":
        header = bytearray(1796)
        for offset, value in [(276, dpi), (372, w), (376, h), (388, bpp), (400, cs)]:
            struct.pack_into(">I", header, offset, value)
        return list(b"RaS2" + header + bytes(data))
    header = bytearray(32)
    header[0:2] = bytes([bpp, cs])
    for offset, value in [(12, w), (16, h), (20, dpi)]:
        struct.pack_into(">I", header, offset, value)
    return list(b"UNIRAST\0" + struct.pack(">I", count) + header + bytes(data))


def cases():
    rng = random.Random(51024)
    pages = {
        "blank": page(9, 4, [255] * 36),
        "black": page(8, 3, [0] * 24),
        "threshold-edges": page(11, 3, [0, 40, 41, 149, 150, 151, 214, 215, 244, 249, 250] * 3),
        "gradient": page(37, 17, [int(x * 255 / 36) for _ in range(17) for x in range(37)]),
        "single-pixel": page(1, 1, [149]),
        "white-borders": page(21, 31, [0 if 8 <= x <= 12 and y in (9, 22) else 255 for y in range(31) for x in range(21)]),
        "long-receipt": page(384, 520, [0 if 50 <= x <= 330 and y % 43 == 7 else 255 for y in range(520) for x in range(384)]),
    }
    for i in range(24):
        w, h = rng.randint(1, 73), rng.randint(1, 49)
        pages[f"seeded-{i:02}"] = page(w, h, [rng.randrange(256) for _ in range(w*h)], rng.choice([0, 203, 406]))
    for name, p in pages.items():
        for mode in ("auto", "threshold", "floyd", "atkinson"):
            yield f"page-{name}-{mode}", dict(op="page", page=p, mode=mode,
                targetWidth=max(1, p["width"] // 2), maxBlankRows=2, crop=[2, max(2, p["width"] - 3)])
        # Enlargement also exercises halfway rounding and edge interpolation.
        yield f"page-{name}-enlarge", dict(op="page", page=p, mode="auto",
            targetWidth=p["width"] * 2 + 1, maxBlankRows=1, crop=[-6, p["width"] + 5])
        yield f"page-{name}-same-width", dict(op="page", page=p, mode="threshold", threshold=128,
            targetWidth=p["width"], maxBlankRows=160, crop=[0, p["width"] - 1])
    for raw in range(256):
        yield f"status-{raw:02x}", dict(op="status", raw=raw)
    for density in (-10, 0, 1, 2, 10):
        for dots in (0, 1, 254, 255, 256, 510, 1024):
            yield f"commands-density-{density}-feed-{dots}", dict(op="commands", density=density, dots=dots)
    sets = {
        "empty": [], "blank": [pages["blank"]], "gradient": [pages["gradient"]],
        "long-receipt": [pages["long-receipt"]],
        "mixed": [pages["white-borders"], pages["blank"], pages["gradient"]],
        "shared-crop": [page(100, 2, [0 if i == 20 else 255 for i in range(200)]),
                        page(100, 2, [0 if i == 60 else 255 for i in range(200)])],
    }
    variants = {
        "default": {}, "fit-trim": dict(fitContentWidth=True, trimBottom=True),
        "labels": dict(labelPaper=True, fitContentWidth=True),
        "floyd": dict(dither="floyd", density=2, rowsPerBlock=17),
        "atkinson": dict(dither="atkinson", feedAfterPage=510, maxBlankRows=0),
        "threshold": dict(dither="threshold", headWidthBytes=6, feedAfterPage=0, maxBlankRows=1),
    }
    for name, ps in sets.items():
        for variant, options in variants.items():
            yield f"job-{name}-{variant}", dict(op="job", pages=ps, options=options)
    for fmt in ("urf", "pwg"):
        kinds = [(8, 1, 1), (24, 1, 3), (32, 1, 4)]
        if fmt == "pwg":
            kinds += [(1, 3, 1), (8, 3, 1)]
        for bpp, cs, unit in kinds:
            prefix = f"decode-{fmt}-{bpp}-{cs}"
            # Literal run, repeated row, repeated compression units, white remainder.
            width = 13 if bpp == 1 else 5
            units = (width + 7) // 8 if bpp == 1 else width
            literal = [rng.randrange(256) for _ in range(units * unit)]
            data = [1, 257 - units] + literal + [0, 0] + [0] * unit + [128]
            yield prefix + "-literal-repeat-fill", dict(op="decode", bytes=raster(fmt, bpp, cs, width, 3, data))
            data = [0, units - 1] + [113] * unit
            yield prefix + "-unit-repeat", dict(op="decode", bytes=raster(fmt, bpp, cs, width, 1, data, dpi=0))
            for tail in ([], [0], [0, 0], [0, 255]):
                yield prefix + f"-truncated-{len(tail)}-{tail[-1] if tail else 0}", dict(op="decode", bytes=raster(fmt, bpp, cs, width, 1, tail))
        yield f"decode-{fmt}-unsupported", dict(op="decode", bytes=raster(fmt, 16, 1, 5, 1, []))
        yield f"decode-{fmt}-invalid-dimensions", dict(op="decode", bytes=raster(fmt, 8, 1, 0, 1, []))
        a = raster(fmt, 8, 1, 2, 1, [0, 1, 0], count=0)
        b = raster(fmt, 8, 1, 3, 1, [0, 2, 255], count=0)
        yield f"decode-{fmt}-multipage", dict(op="decode", bytes=a + b[4 if fmt == "pwg" else 12:])
        if fmt == "urf":
            a = raster(fmt, 8, 1, 2, 1, [0, 1, 0], count=1)
            yield "decode-urf-page-count", dict(op="decode", bytes=a + b[12:])
    for name, data in [("unknown", []), ("unknown-text", list(b"hello")),
                       ("pwg-header", list(b"RaS2")), ("urf-header", list(b"UNIRAST")),
                       ("urf-no-page", list(b"UNIRAST\0") + [0]*4)]:
        yield "decode-" + name, dict(op="decode", bytes=data)


def first_difference(a, b, path="$"):
    if type(a) is not type(b):
        return f"{path}: {type(a).__name__} != {type(b).__name__}"
    if isinstance(a, dict):
        if a.keys() != b.keys():
            return f"{path}: object keys differ"
        for key in sorted(a):
            if a[key] != b[key]:
                return first_difference(a[key], b[key], f"{path}.{key}")
    elif isinstance(a, list):
        for i, (x, y) in enumerate(zip(a, b)):
            if x != y:
                return first_difference(x, y, f"{path}[{i}]")
        if len(a) != len(b):
            return f"{path}: length {len(a)} != {len(b)}"
    elif a != b:
        return f"{path}: Swift={a!r}, Rust={b!r}"
    return None


def write_png(path, width, height, pixels):
    """Write a grayscale PNG using only the Python standard library."""
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", binascii.crc32(kind + data) & 0xffffffff)
    raw = b"".join(b"\0" + bytes(pixels[y*width:(y+1)*width]) for y in range(height))
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def export_images(folder, prefix, output):
    def image(name, p):
        write_png(folder / f"{prefix}-{name}.png", p["width"], p["height"], p["pixels"])
        (folder / f"{prefix}-{name}.pgm").write_bytes(
            f'P5\n{p["width"]} {p["height"]}\n255\n'.encode() + bytes(p["pixels"]))
    for key in ("scaled", "trimmed", "collapsed", "cropped"):
        if key in output:
            image(key, output[key])
    for i, p in enumerate(output.get("pages", [])):
        image(f"page-{i}", p)
    if "bitmap" in output:
        b = output["bitmap"]
        width = b["widthBytes"] * 8
        pixels = [0 if byte & (0x80 >> bit) else 255 for byte in b["rows"] for bit in range(8)]
        write_png(folder / f"{prefix}-bitmap.png", width, b["height"], pixels)
        (folder / f"{prefix}-bitmap.pbm").write_bytes(
            f'P4\n{b["widthBytes"] * 8} {b["height"]}\n'.encode() + bytes(b["rows"]))
    if "chunks" in output:
        (folder / f"{prefix}-job.bin").write_bytes(bytes(x for chunk in output["chunks"] for x in chunk))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--case", default="", help="Run names containing this substring")
    parser.add_argument("--output", type=pathlib.Path, default=ROOT / "rust/target/parity")
    parser.add_argument("--release", action="store_true", help="Compare optimized Rust and Swift builds")
    parser.add_argument("--no-build", action="store_true", help="Use existing binaries")
    args = parser.parse_args()
    selected = [(name, v) for name, v in cases() if args.case in name]
    if not selected:
        parser.error("no matching cases")
    args.output.mkdir(parents=True, exist_ok=True)
    profile = "release" if args.release else "debug"
    swift = ROOT / "rust/target" / f"swift-oracle-{profile}"
    rust = ROOT / "rust/target" / profile / "examples/parity"
    if not args.no_build:
        subprocess.run(["swiftc", "-O" if args.release else "-Onone", "-o", str(swift),
                        *map(str, sorted((ROOT / "Sources/S1Kit").glob("*.swift"))),
                        str(ROOT / "tools/swift-oracle/main.swift")], check=True)
        subprocess.run(["cargo", "build", "--manifest-path", str(ROOT / "rust/Cargo.toml"),
                        "--example", "parity", *(["--release"] if args.release else [])], check=True)
    wire = "".join(json.dumps(v) + "\n" for _, v in selected)
    outputs = []
    for binary in (swift, rust):
        result = subprocess.run([str(binary)], input=wire, text=True, capture_output=True, check=True)
        parsed = [json.loads(line) for line in result.stdout.splitlines()]
        if len(parsed) != len(selected):
            raise RuntimeError(f"{binary}: expected {len(selected)} results, got {len(parsed)}")
        outputs.append(parsed)
    report = []
    for (name, v), reference, actual in zip(selected, *outputs):
        difference = first_difference(reference, actual)
        folder = args.output / name
        folder.mkdir(exist_ok=True)
        for filename, data in [("input.json", v), ("swift.json", reference), ("rust.json", actual)]:
            (folder / filename).write_text(json.dumps(data, indent=2) + "\n")
        export_images(folder, "swift", reference)
        export_images(folder, "rust", actual)
        if "page" in v:
            p = v["page"]
            write_png(folder / "input.png", p["width"], p["height"], p["pixels"])
            (folder / "input.pgm").write_bytes(f'P5\n{p["width"]} {p["height"]}\n255\n'.encode() + bytes(p["pixels"]))
        report.append(dict(case=name, passed=difference is None, difference=difference))
        print(f'{"PASS" if difference is None else "FAIL"} {name}' + (f": {difference}" if difference else ""))
    (args.output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = ["# Swift / Rust comparison", "", "Each case compares complete outputs, including pixels, metadata, and command block boundaries.", "",
             "| Case | Result | Input | Swift | Rust |", "|---|---|---|---|---|"]
    for row in report:
        name = row["case"]
        result = "PASS" if row["passed"] else "FAIL: " + row["difference"]
        lines.append(f"| {name} | {result} | [JSON]({name}/input.json) | [JSON]({name}/swift.json) | [JSON]({name}/rust.json) |")
    (args.output / "report.md").write_text("\n".join(lines) + "\n")
    counts = collections.Counter(v["op"] for _, v in selected)
    failures = sum(not r["passed"] for r in report)
    print(f"\n{len(report) - failures}/{len(report)} passed: {dict(counts)}")
    print(f"Review artifacts: {args.output}")
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
