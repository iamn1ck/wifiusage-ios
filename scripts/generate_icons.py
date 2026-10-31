#!/usr/bin/env python3
"""
Generates valid PNG icons (29x29, 58x58, 87x87) for the WiFiUsage Settings bundle
using only Python's standard library (zlib + struct + math).
"""
import math
import os
import struct
import zlib


def write_png(filepath: str, width: int, height: int, rgba_bytes: bytes) -> None:
    def chunk(chunk_type: bytes, data: bytes) -> bytes:
        crc = zlib.crc32(chunk_type + data) & 0xFFFFFFFF
        return struct.pack(">I", len(data)) + chunk_type + data + struct.pack(">I", crc)

    raw_rows = bytearray()
    stride = width * 4
    for y in range(height):
        raw_rows.append(0)  # Filter type 0 (None)
        raw_rows.extend(rgba_bytes[y * stride : (y + 1) * stride])

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    compressed = zlib.compress(bytes(raw_rows), 9)
    png_data = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", compressed)
        + chunk(b"IEND", b"")
    )
    os.makedirs(os.path.dirname(filepath), exist_ok=True)
    with open(filepath, "wb") as f:
        f.write(png_data)


def render_icon(size: int) -> bytes:
    buf = bytearray(size * size * 4)
    radius = size * 0.225  # Standard iOS rounded rect corner radius (~22.5%)
    cx = size / 2.0
    cy = size / 2.0

    for y in range(size):
        for x in range(size):
            px = x + 0.5
            py = y + 0.5

            # Rounded rectangle signed distance
            dx = max(abs(px - cx) - (size / 2.0 - radius), 0.0)
            dy = max(abs(py - cy) - (size / 2.0 - radius), 0.0)
            dist = math.hypot(dx, dy) - radius

            if dist > 0.5:
                continue

            alpha = max(0.0, min(1.0, 0.5 - dist))

            # Background gradient: iOS Blue (#007AFF) to Teal/Green (#30D158)
            t = (py / size) * 0.7 + (px / size) * 0.3
            r = int(0 * (1 - t) + 16 * t)
            g = int(122 * (1 - t) + 185 * t)
            b = int(255 * (1 - t) + 129 * t)

            # Draw Wi-Fi arcs on upper-left / center and Cellular bars on lower-right
            # Normalized coordinates in [0, 1]
            nx = px / size
            ny = py / size

            # Draw 3 vertical cellular-style bars + wifi arc motif in white
            fg_alpha = 0.0

            # Wi-Fi arc center at (0.5, 0.68)
            arc_dx = nx - 0.50
            arc_dy = ny - 0.70
            arc_r = math.hypot(arc_dx, arc_dy)
            arc_angle = math.atan2(-arc_dy, arc_dx)  # upward fan

            if math.pi * 0.22 <= arc_angle <= math.pi * 0.78:
                for ring_r in (0.19, 0.33, 0.47):
                    ring_dist = abs(arc_r - ring_r)
                    thickness = 0.042
                    if ring_dist < thickness:
                        fg_alpha = max(
                            fg_alpha,
                            max(0.0, min(1.0, (thickness - ring_dist) * size * 0.8)),
                        )

            # Bottom dot
            dot_dist = math.hypot(nx - 0.50, ny - 0.72)
            if dot_dist < 0.065:
                fg_alpha = max(
                    fg_alpha, max(0.0, min(1.0, (0.065 - dot_dist) * size * 0.9))
                )

            if fg_alpha > 0.0:
                r = int(r * (1.0 - fg_alpha) + 255 * fg_alpha)
                g = int(g * (1.0 - fg_alpha) + 255 * fg_alpha)
                b = int(b * (1.0 - fg_alpha) + 255 * fg_alpha)

            idx = (y * size + x) * 4
            buf[idx] = r
            buf[idx + 1] = g
            buf[idx + 2] = b
            buf[idx + 3] = int(alpha * 255)

    return bytes(buf)


def main() -> None:
    out_dir = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "WiFiUsagePrefs",
        "Resources",
    )
    icons = {
        "icon.png": 29,
        "icon@2x.png": 58,
        "icon@3x.png": 87,
    }
    for name, dim in icons.items():
        path = os.path.join(out_dir, name)
        write_png(path, dim, dim, render_icon(dim))
        print(f"Generated {path} ({dim}x{dim})")


if __name__ == "__main__":
    main()

