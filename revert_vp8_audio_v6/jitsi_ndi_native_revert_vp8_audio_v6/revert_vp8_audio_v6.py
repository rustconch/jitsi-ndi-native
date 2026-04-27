#!/usr/bin/env python3
# -*- coding: utf-8 -*-
from __future__ import annotations

import datetime
import re
import shutil
import sys
from pathlib import Path

ROOT = Path.cwd()
SRC = ROOT / "src"
BACKUP = ROOT / ("revert_vp8_audio_v6_backup_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))


def info(msg: str) -> None:
    print(f"[REVERT_VP8_AUDIO_V6] {msg}")


def warn(msg: str) -> None:
    print(f"[REVERT_VP8_AUDIO_V6] WARN: {msg}")


def die(msg: str) -> None:
    print(f"[REVERT_VP8_AUDIO_V6] ERROR: {msg}")
    sys.exit(1)


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


def write(p: Path, s: str) -> None:
    p.write_text(s, encoding="utf-8", newline="")


def backup(p: Path) -> None:
    if not p.exists():
        return
    dst = BACKUP / p.relative_to(ROOT)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(p, dst)


def src_files() -> list[Path]:
    return list(SRC.rglob("*.cpp")) + list(SRC.rglob("*.h")) + list(SRC.rglob("*.hpp"))


def strip_region(text: str, begin_marker: str, end_marker: str) -> str:
    return re.sub(
        r"\n?//\s*" + re.escape(begin_marker) + r".*?//\s*" + re.escape(end_marker) + r"\n?",
        "\n",
        text,
        flags=re.S,
    )


def cleanup_force_vp8() -> None:
    markers = [
        ("JNN_FORCE_JINGLE_VP8_HOTFIX_BEGIN", "JNN_FORCE_JINGLE_VP8_HOTFIX_END"),
        ("JNN_FORCE_JINGLE_VP8_REAL_V4_BEGIN", "JNN_FORCE_JINGLE_VP8_REAL_V4_END"),
        ("JNN_FORCE_JINGLE_VP8_COMPILE_V5_BEGIN", "JNN_FORCE_JINGLE_VP8_COMPILE_V5_END"),
        ("JNN_FORCE_VP8_REAL_V4_BEGIN", "JNN_FORCE_VP8_REAL_V4_END"),
    ]

    changed = 0
    for p in src_files():
        t = read(p)
        original = t
        for b, e in markers:
            t = strip_region(t, b, e)

        # Remove generated one-line calls from previous VP8 forcing patches.
        t = re.sub(
            r"^[ \t]*[A-Za-z_]\w*\s*=\s*jnnForceJingleSessionAcceptVp8Only(?:V4|V5)?\s*\([^\n;]*\)\s*;\s*//\s*JNN_FORCE_JINGLE_VP8[^\r\n]*\r?\n",
            "",
            t,
            flags=re.M,
        )
        t = re.sub(
            r"^[ \t]*[A-Za-z_]\w*\s*=\s*jnnForceSdpVideoVp8Only\s*\([^\n;]*\)\s*;\s*//\s*JNN_FORCE_REMOTE_OFFER_VP8[^\r\n]*\r?\n",
            "",
            t,
            flags=re.M,
        )

        # If any accidental helper declarations without markers survived, remove simple static helper blocks by name.
        t = re.sub(
            r"\n?static\s+std::string\s+jnn(?:EraseXmlElementAroundVp8|ErasePayloadTypeByCodecNameVp8|EraseRtpHeaderExtensionByTextVp8|ForceJingleSessionAcceptVp8Only|ForceSdpVideoVp8Only)[A-Za-z0-9_]*\s*\([^)]*\)\s*\{.*?\n\}\s*",
            "\n",
            t,
            flags=re.S,
        )

        # Advertise AV1 as available again. This does not force AV1 by itself, but avoids saying VP8-only in MUC presence.
        t = t.replace(">vp8,opus<", ">av1,vp8,opus<")
        t = t.replace("vp8,opus", "av1,vp8,opus")
        # Avoid duplicate codec list if the script is run twice.
        t = t.replace("av1,av1,vp8,opus", "av1,vp8,opus")

        if t != original:
            backup(p)
            write(p, t)
            changed += 1
            info(f"cleaned VP8 forcing in {p.relative_to(ROOT)}")
    if changed == 0:
        info("no old VP8 forcing code found")


def patch_audio_clock() -> None:
    patched = 0
    for p in src_files():
        if p.name.lower() != "ndisender.cpp":
            continue
        t = read(p)
        original = t
        if "clock_audio" not in t:
            continue
        # Let NDI clock audio. With live RTP packets this is usually smoother than sending decoded Opus bursts directly.
        t = re.sub(
            r"createDesc\.clock_audio\s*=\s*false\s*;",
            "createDesc.clock_audio = true; // REVERT_VP8_AUDIO_V6: let NDI clock audio",
            t,
        )
        if t != original:
            backup(p)
            write(p, t)
            patched += 1
            info(f"patched NDI audio clock in {p.relative_to(ROOT)}")
    if patched == 0:
        warn("NDISender.cpp clock_audio=false was not found; audio clock patch skipped")


def patch_video_payload_logging_and_av1_guard() -> None:
    p = SRC / "PerParticipantNdiRouter.cpp"
    if not p.exists():
        warn("PerParticipantNdiRouter.cpp not found; video payload-type logging skipped")
        return
    t = read(p)
    original = t
    if "REVERT_VP8_AUDIO_V6_VIDEO_PT_LOG" in t:
        info("video payload-type logging already present")
        return

    # Insert right after the per-participant video packet counter if possible.
    patterns = [
        r"(if\s*\(\s*media\s*==\s*\"video\"\s*\|\|\s*mid\s*==\s*\"video\"\s*\)\s*\{\s*\r?\n\s*\+\+p\.videoPackets\s*;)",
        r"(if\s*\([^\n{}]*(?:media|mid)[^\n{}]*video[^\n{}]*\)\s*\{\s*\r?\n\s*\+\+p\.videoPackets\s*;)",
    ]
    block = r'''
        // REVERT_VP8_AUDIO_V6_VIDEO_PT_LOG
        if (p.videoPackets <= 20 || (p.videoPackets % 300) == 0) {
            Logger::info(
                "PerParticipantNdiRouter: video RTP endpoint=", p.endpointId,
                " pt=", static_cast<int>(rtp.payloadType),
                " marker=", static_cast<int>(rtp.marker),
                " payloadBytes=", rtp.payloadSize,
                " ssrc=", rtp.ssrc
            );
        }
        // This build currently has a working AV1 decode path, not a wired VP8 decode path.
        // If old VP8 forcing made the bridge send PT=100, do not feed VP8 bytes to libdav1d.
        if (rtp.payloadType == 100) {
            if (p.videoPackets <= 20 || (p.videoPackets % 300) == 0) {
                Logger::warn("PerParticipantNdiRouter: got VP8 RTP while AV1 decoder path is active; skipping VP8 packet instead of sending it to dav1d");
            }
            return;
        }
'''
    inserted = False
    for pat in patterns:
        m = re.search(pat, t, flags=re.S)
        if m:
            t = t[:m.end()] + block + t[m.end():]
            inserted = True
            break

    if inserted and t != original:
        backup(p)
        write(p, t)
        info(f"patched video RTP payload-type logging/VP8 guard in {p.relative_to(ROOT)}")
    else:
        warn("could not auto-insert video payload-type logging; send PerParticipantNdiRouter.cpp if needed")


def main() -> None:
    if not SRC.exists():
        die(r"Run this from project root, e.g. D:\MEDIA\Desktop\jitsi-ndi-native")
    BACKUP.mkdir(parents=True, exist_ok=True)
    cleanup_force_vp8()
    patch_audio_clock()
    patch_video_payload_logging_and_av1_guard()
    info(f"backup folder: {BACKUP}")
    info("done. Rebuild with: cmake --build build --config Release")


if __name__ == "__main__":
    main()
