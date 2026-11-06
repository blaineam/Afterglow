#!/usr/bin/env python3
"""Writes the spherical-video v2 boxes (st3d, sv3d/proj/equi) into an MP4's video sample entry,
the way a 360 camera or Google's spatial-media injector marks a file, so the player can be
checked against metadata rather than file-name tags.

  python3 Tools/inject_spherical.py in.mp4 out.mp4 [--stereo mono|top-bottom|left-right] [--half]

--half crops the equirectangular bounds to a quarter each side: a VR180 file. The moov is
rewritten in place, so chunk offsets in stco/co64 are shifted when the moov sits before the mdat
(ffmpeg's -movflags +faststart), and left alone when it comes after.
"""
import struct
import sys


def box(kind, body):
    return struct.pack(">I4s", 8 + len(body), kind) + body


def st3d(mode):
    return box(b"st3d", b"\0\0\0\0" + bytes([mode]))


def sv3d(half):
    crop = (1 << 30) if half else 0
    equi = box(b"equi", struct.pack(">IIIII", 0, 0, 0, crop, crop))
    prhd = box(b"prhd", struct.pack(">IIII", 0, 0, 0, 0))
    return box(b"sv3d", box(b"svhd", b"\0\0\0\0\0") + box(b"proj", prhd + equi))


def children(data):
    """(start, end, kind) of each box in data."""
    found = []
    at = 0
    while at + 8 <= len(data):
        size, kind = struct.unpack(">I4s", data[at:at + 8])
        if size == 1:
            size = struct.unpack(">Q", data[at + 8:at + 16])[0]
        elif size == 0:
            size = len(data) - at
        if size < 8:
            break
        found.append((at, at + size, kind))
        at += size
    return found


def rewrite(data, path, extra):
    """data is one box; path the kinds to descend (b"*entry" = the first sample entry in an
    stsd); extra the bytes appended inside the leaf. Returns the box with every size updated."""
    if not path:
        return struct.pack(">I", len(data) + len(extra)) + data[4:] + extra
    kind = data[4:8]
    # stsd carries version/flags and an entry count before its children. The boxes go at the
    # end of the sample entry, after its 78 bytes of visual fields and whatever children it has.
    body_offset = 16 if kind == b"stsd" else 8
    inner = data[body_offset:]
    for start, end, k in children(inner):
        if k == path[0] or path[0] == b"*entry":
            new = rewrite(inner[start:end], path[1:], extra)
            out = data[:body_offset] + inner[:start] + new + inner[end:]
            return struct.pack(">I", len(out)) + out[4:]
    raise SystemExit(f"no {path[0].decode()} box under {kind.decode()}")


def shift_offsets(moov, delta):
    """Adds delta to every chunk offset in stco/co64 under moov."""
    out = bytearray(moov)

    def walk(start, end):
        at = start
        while at + 8 <= end:
            size, kind = struct.unpack(">I4s", out[at:at + 8])
            if size < 8:
                return
            if kind in (b"trak", b"mdia", b"minf", b"stbl"):
                walk(at + 8, at + size)
            elif kind == b"stco":
                count = struct.unpack(">I", out[at + 12:at + 16])[0]
                for i in range(count):
                    p = at + 16 + 4 * i
                    out[p:p + 4] = struct.pack(">I", struct.unpack(">I", out[p:p + 4])[0] + delta)
            elif kind == b"co64":
                count = struct.unpack(">I", out[at + 12:at + 16])[0]
                for i in range(count):
                    p = at + 16 + 8 * i
                    out[p:p + 8] = struct.pack(">Q", struct.unpack(">Q", out[p:p + 8])[0] + delta)
            at += size

    walk(8, len(out))
    return bytes(out)


def main():
    args = sys.argv[1:]
    if len(args) < 2:
        raise SystemExit(__doc__)
    src, dst = args[0], args[1]
    stereo = {"mono": 0, "top-bottom": 1, "left-right": 2}
    mode = 0
    half = False
    i = 2
    while i < len(args):
        if args[i] == "--stereo":
            mode = stereo[args[i + 1]]
            i += 2
        elif args[i] == "--half":
            half = True
            i += 1
        else:
            raise SystemExit(f"unknown option {args[i]}")
    data = open(src, "rb").read()
    extra = st3d(mode) + sv3d(half)
    top = children(data)
    moov = next((b for b in top if b[2] == b"moov"), None)
    mdat = next((b for b in top if b[2] == b"mdat"), None)
    if moov is None:
        raise SystemExit("no moov box")
    old = data[moov[0]:moov[1]]
    # The first video track's first sample entry.
    new = rewrite_video_track(old, extra)
    if mdat is not None and moov[0] < mdat[0]:
        new = shift_offsets(new, len(new) - len(old))
    open(dst, "wb").write(data[:moov[0]] + new + data[moov[1]:])
    print(f"{dst}: {len(extra)} bytes of spherical boxes, stereo {mode}, {'180' if half else '360'}")


def rewrite_video_track(moov, extra):
    inner = moov[8:]
    for start, end, kind in children(inner):
        if kind != b"trak":
            continue
        trak = inner[start:end]
        if b"vide" not in trak[:4096]:
            continue
        new = rewrite(trak, [b"mdia", b"minf", b"stbl", b"stsd", b"*entry"], extra)
        out = moov[:8] + inner[:start] + new + inner[end:]
        return struct.pack(">I", len(out)) + out[4:]
    raise SystemExit("no video track")


if __name__ == "__main__":
    main()
