#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Best-effort AV1 patch for jitsi-ndi-native.
Run from repository root:

    python apply_av1_patch.py

The script creates .bak_av1_patch backups before editing files.
"""
from __future__ import annotations

import re
import shutil
from pathlib import Path

ROOT = Path.cwd()
PATCH_DIR = Path(__file__).resolve().parent
SRC = ROOT / "src"


def die(message: str) -> None:
    raise SystemExit("[AV1 PATCH] ERROR: " + message)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def write(path: Path, text: str) -> None:
    if path.exists():
        backup = path.with_suffix(path.suffix + ".bak_av1_patch")
        if not backup.exists():
            shutil.copy2(path, backup)
    path.write_text(text, encoding="utf-8", newline="")


def ensure_file(path: Path) -> None:
    if not path.exists():
        die(f"missing file: {path}")


def copy_new_files() -> None:
    ensure_file(PATCH_DIR / "src" / "Av1RtpFrameAssembler.h")
    ensure_file(PATCH_DIR / "src" / "Av1RtpFrameAssembler.cpp")
    SRC.mkdir(parents=True, exist_ok=True)
    shutil.copy2(PATCH_DIR / "src" / "Av1RtpFrameAssembler.h", SRC / "Av1RtpFrameAssembler.h")
    shutil.copy2(PATCH_DIR / "src" / "Av1RtpFrameAssembler.cpp", SRC / "Av1RtpFrameAssembler.cpp")
    print("[AV1 PATCH] copied src/Av1RtpFrameAssembler.h/.cpp")


def patch_cmake() -> None:
    candidates = [ROOT / "CMakeLists.txt", SRC / "CMakeLists.txt"]
    cmake = next((p for p in candidates if p.exists()), None)
    if not cmake:
        print("[AV1 PATCH] WARN: CMakeLists.txt not found; add src/Av1RtpFrameAssembler.cpp manually")
        return

    text = read(cmake)
    if "Av1RtpFrameAssembler.cpp" in text:
        print("[AV1 PATCH] CMake already contains Av1RtpFrameAssembler.cpp")
        return

    patterns = [
        r"(src/FfmpegMediaDecoder\.cpp\s*)",
        r"(src/PerParticipantNdiRouter\.cpp\s*)",
        r"(FfmpegMediaDecoder\.cpp\s*)",
        r"(PerParticipantNdiRouter\.cpp\s*)",
    ]

    for pat in patterns:
        m = re.search(pat, text)
        if m:
            token = "src/Av1RtpFrameAssembler.cpp" if "src/" in m.group(1) else "Av1RtpFrameAssembler.cpp"
            text = text[:m.end()] + "    " + token + "\n" + text[m.end():]
            write(cmake, text)
            print(f"[AV1 PATCH] patched {cmake}")
            return

    print("[AV1 PATCH] WARN: could not locate source list in CMakeLists.txt; add src/Av1RtpFrameAssembler.cpp manually")


def find_class_block(text: str, class_name: str) -> tuple[int, int] | None:
    m = re.search(r"class\s+" + re.escape(class_name) + r"\b[^\{]*\{", text)
    if not m:
        return None

    start = m.start()
    brace = text.find("{", m.end() - 1)
    depth = 0
    i = brace

    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                semi = text.find(";", i)
                if semi == -1:
                    return None
                return start, semi + 1
        i += 1

    return None


def patch_decoder_header() -> None:
    path = SRC / "FfmpegMediaDecoder.h"
    ensure_file(path)
    text = read(path)

    if "FfmpegAv1Decoder" in text:
        print("[AV1 PATCH] FfmpegMediaDecoder.h already contains FfmpegAv1Decoder")
        return

    block = find_class_block(text, "FfmpegVp8Decoder")
    if not block:
        print("[AV1 PATCH] WARN: could not find class FfmpegVp8Decoder in FfmpegMediaDecoder.h")
        print("[AV1 PATCH]       copy snippets/FfmpegMediaDecoder_av1.h manually")
        return

    start, end = block
    vp8_decl = text[start:end]
    av1_decl = vp8_decl.replace("FfmpegVp8Decoder", "FfmpegAv1Decoder")
    text = text[:end] + "\n\n" + av1_decl + text[end:]
    write(path, text)
    print("[AV1 PATCH] patched FfmpegMediaDecoder.h")


def find_method_end(text: str, start: int) -> int | None:
    brace = text.find("{", start)
    if brace == -1:
        return None
    depth = 0
    i = brace
    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return None


def collect_vp8_impl_region(text: str) -> str | None:
    starts = []
    for pat in [r"struct\s+FfmpegVp8Decoder::Impl\b", r"class\s+FfmpegVp8Decoder::Impl\b", r"FfmpegVp8Decoder::FfmpegVp8Decoder\s*\("]:
        m = re.search(pat, text)
        if m:
            starts.append(m.start())
    if not starts:
        return None

    start = min(starts)

    # Try to end before the next decoder implementation begins.
    next_markers = []
    for marker in [
        r"struct\s+FfmpegOpusDecoder::Impl\b",
        r"class\s+FfmpegOpusDecoder::Impl\b",
        r"FfmpegOpusDecoder::FfmpegOpusDecoder\s*\(",
        r"struct\s+FfmpegAudioDecoder::Impl\b",
        r"class\s+FfmpegAudioDecoder::Impl\b",
        r"FfmpegAudioDecoder::FfmpegAudioDecoder\s*\(",
    ]:
        m = re.search(marker, text[start + 1:])
        if m:
            next_markers.append(start + 1 + m.start())

    if next_markers:
        end = min(next_markers)
        return text[start:end].rstrip() + "\n"

    # Fallback: duplicate only constructor/destructor/decode if present.
    methods = []
    for pat in [
        r"FfmpegVp8Decoder::FfmpegVp8Decoder\s*\(",
        r"FfmpegVp8Decoder::~FfmpegVp8Decoder\s*\(",
        r"FfmpegVp8Decoder::decode\s*\(",
    ]:
        m = re.search(pat, text)
        if not m:
            continue
        end = find_method_end(text, m.start())
        if end:
            methods.append(text[m.start():end])
    if methods:
        return "\n\n".join(methods) + "\n"

    return None


def patch_decoder_cpp() -> None:
    path = SRC / "FfmpegMediaDecoder.cpp"
    ensure_file(path)
    text = read(path)

    if "FfmpegAv1Decoder" in text:
        print("[AV1 PATCH] FfmpegMediaDecoder.cpp already contains FfmpegAv1Decoder")
        return

    region = collect_vp8_impl_region(text)
    if not region:
        print("[AV1 PATCH] WARN: could not duplicate VP8 decoder implementation automatically")
        print("[AV1 PATCH]       copy snippets/FfmpegMediaDecoder_av1.cpp manually")
        return

    av1_region = region.replace("FfmpegVp8Decoder", "FfmpegAv1Decoder").replace("AV_CODEC_ID_VP8", "AV_CODEC_ID_AV1")

    # Insert right after the VP8 region when possible; otherwise append.
    insert_at = text.find(region)
    if insert_at >= 0:
        insert_at += len(region)
        text = text[:insert_at] + "\n" + av1_region + text[insert_at:]
    else:
        text = text.rstrip() + "\n\n" + av1_region + "\n"

    write(path, text)
    print("[AV1 PATCH] patched FfmpegMediaDecoder.cpp")


def patch_router_header() -> None:
    path = SRC / "PerParticipantNdiRouter.h"
    ensure_file(path)
    text = read(path)

    changed = False

    if "Av1RtpFrameAssembler.h" not in text:
        inc = '#include "Av1RtpFrameAssembler.h"\n'
        m = re.search(r"#include\s+\"FfmpegMediaDecoder\.h\"\s*\n", text)
        if m:
            text = text[:m.end()] + inc + text[m.end():]
        else:
            text = inc + text
        changed = True

    if "Av1RtpFrameAssembler av1" not in text:
        m = re.search(r"(\s*)(Vp8FrameAssembler\s+\w+\s*;)", text)
        if m:
            indent = m.group(1)
            text = text[:m.end()] + f"\n{indent}Av1RtpFrameAssembler av1;" + text[m.end():]
            changed = True
        else:
            print("[AV1 PATCH] WARN: could not find Vp8FrameAssembler member in PerParticipantNdiRouter.h")

    if "FfmpegAv1Decoder av1Decoder" not in text:
        m = re.search(r"(\s*)(FfmpegVp8Decoder\s+\w+\s*;)", text)
        if m:
            indent = m.group(1)
            text = text[:m.end()] + f"\n{indent}FfmpegAv1Decoder av1Decoder;" + text[m.end():]
            changed = True
        else:
            # common fallback from this project: FfmpegVp8Decoder videoDecoder;
            m = re.search(r"(\s*)(FfmpegVp8Decoder\s+videoDecoder\s*;)", text)
            if m:
                indent = m.group(1)
                text = text[:m.end()] + f"\n{indent}FfmpegAv1Decoder av1Decoder;" + text[m.end():]
                changed = True
            else:
                print("[AV1 PATCH] WARN: could not find FfmpegVp8Decoder member in PerParticipantNdiRouter.h")

    if changed:
        write(path, text)
        print("[AV1 PATCH] patched PerParticipantNdiRouter.h")
    else:
        print("[AV1 PATCH] PerParticipantNdiRouter.h already patched")


def patch_router_cpp() -> None:
    path = SRC / "PerParticipantNdiRouter.cpp"
    ensure_file(path)
    text = read(path)

    if "AV1 video packets endpoint=" in text:
        print("[AV1 PATCH] PerParticipantNdiRouter.cpp already has AV1 route")
        return

    av1_block = r'''
    if (rtp.payloadType == 41) {
        const auto frames = p.av1.pushRtp(rtp);

        for (const auto& encoded : frames) {
            for (const auto& decoded : p.av1Decoder.decode(encoded)) {
                p.ndi->sendVideoFrame(decoded, 30, 1);
            }
        }

        if ((p.videoPackets % 300) == 0) {
            Logger::info(
                "PerParticipantNdiRouter: AV1 video packets endpoint=",
                p.endpointId,
                " count=",
                p.videoPackets,
                " producedFrames=",
                frames.size()
            );
        }

        return;
    }
'''

    # Best target: insert before the existing VP8-only drop block.
    patterns = [
        r"(\n\s*)if\s*\(\s*rtp\.payloadType\s*!=\s*100\s*\)\s*\{",
        r"(\n\s*)if\s*\(\s*rtp\.payloadType\s*!=\s*VP8_PAYLOAD_TYPE\s*\)\s*\{",
    ]
    for pat in patterns:
        m = re.search(pat, text)
        if m and "dropping non-VP8 video RTP" in text[m.start():m.start()+900]:
            text = text[:m.start()] + "\n" + av1_block + text[m.start():]
            write(path, text)
            print("[AV1 PATCH] patched PerParticipantNdiRouter.cpp before non-VP8 drop block")
            return

    # Fallback: insert at the beginning of the video branch after counters.
    m = re.search(r"if\s*\(\s*media\s*==\s*\"video\"\s*\|\|\s*mid\s*==\s*\"video\"\s*\)\s*\{", text)
    if m:
        branch_start = text.find("{", m.start()) + 1
        counter = re.search(r"\+\+routedVideoPackets_\s*;", text[branch_start:])
        if counter:
            insert_at = branch_start + counter.end()
            text = text[:insert_at] + "\n" + av1_block + text[insert_at:]
            write(path, text)
            print("[AV1 PATCH] patched PerParticipantNdiRouter.cpp inside video branch")
            return

    print("[AV1 PATCH] WARN: could not patch PerParticipantNdiRouter.cpp automatically")
    print("[AV1 PATCH]       copy snippets/PerParticipantNdiRouter_video_branch.cpp manually")


def patch_jingle_codecs() -> None:
    path = SRC / "JingleSession.cpp"
    if not path.exists():
        print("[AV1 PATCH] WARN: JingleSession.cpp not found; skipping codec negotiation patch")
        return

    text = read(path)
    original = text

    # If current function is VP8-only, make it accept AV1/VP9/H264 too.
    text = re.sub(
        r"bool\s+isSupportedVideoCodec\s*\(\s*const\s+JingleCodec&\s+codec\s*\)\s*\{[\s\S]*?\n\}",
        '''bool isSupportedVideoCodec(const JingleCodec& codec) {
    const std::string name = toLower(codec.name);

    // JVB usually forwards the sender's actual codec; it does not transcode to VP8 for us.
    return name == "vp8"
        || name == "vp9"
        || name == "h264"
        || name == "av1";
}''',
        text,
        count=1
    )

    if text != original:
        write(path, text)
        print("[AV1 PATCH] patched JingleSession.cpp video codec negotiation")
    else:
        print("[AV1 PATCH] JingleSession.cpp codec negotiation left unchanged")


def patch_native_answerer_vp8_filter() -> None:
    path = SRC / "NativeWebRTCAnswerer.cpp"
    if not path.exists():
        print("[AV1 PATCH] WARN: NativeWebRTCAnswerer.cpp not found; skipping VP8-only filter removal")
        return

    text = read(path)
    original = text

    # Remove simple offerSdp = filterSdpToVp8Only(offerSdp); style lines.
    text = re.sub(r"\n\s*offerSdp\s*=\s*filterSdpToVp8Only\s*\(\s*offerSdp\s*\)\s*;", "", text)
    text = re.sub(r"\n\s*const\s+std::string\s+vp8OnlyOfferSdp\s*=\s*filterSdpToVp8Only\s*\(\s*offerSdp\s*\)\s*;", "", text)
    text = text.replace("vp8OnlyOfferSdp", "offerSdp")

    # Remove/soften log messages.
    text = re.sub(r"\n\s*Logger::warn\([^;]*VP8-only SDP filter applied[^;]*;", "", text)
    text = text.replace("setting remote Jitsi SDP-like VP8-only offer", "setting remote Jitsi SDP-like offer")

    if text != original:
        write(path, text)
        print("[AV1 PATCH] patched NativeWebRTCAnswerer.cpp: removed VP8-only SDP forcing")
    else:
        print("[AV1 PATCH] NativeWebRTCAnswerer.cpp VP8 filter left unchanged")


def main() -> None:
    if not SRC.exists():
        die("run this script from the repository root; expected ./src directory")

    copy_new_files()
    patch_cmake()
    patch_decoder_header()
    patch_decoder_cpp()
    patch_router_header()
    patch_router_cpp()
    patch_jingle_codecs()
    patch_native_answerer_vp8_filter()

    print("[AV1 PATCH] done")
    print("[AV1 PATCH] now build:")
    print("    cmake --build build --config Release")
    print("[AV1 PATCH] if compilation fails, send the first 20-40 error lines")


if __name__ == "__main__":
    main()
