#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Patch v8 for rustconch/jitsi-ndi-native current repo.
Goal: make the media path internally consistent and stop mixing AV1 negotiation with a VP8 pipeline.
Default mode: VP8-stable path.

Run from repo root:
    python .\repo_patch_v8\apply_repo_patch_v8.py

What it changes:
  - negotiates video as VP8-only in synthetic SDP and Jingle session-accept;
  - advertises vp8,opus in presence;
  - routes VP8 RTP into the existing VP8 depacketizer/FFmpeg decoder;
  - drops non-VP8 video RTP instead of feeding it to dav1d;
  - disables NDI audio clocking to avoid blocking the RTP callback thread.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import pathlib
import re
import shutil
import sys


def log(msg: str) -> None:
    print(f"[repo-patch-v8] {msg}")


def read(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8-sig")


def write(path: pathlib.Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="")


def backup(path: pathlib.Path, backup_root: pathlib.Path) -> None:
    rel = path.relative_to(pathlib.Path.cwd())
    dst = backup_root / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(path, dst)


def find_function_span(text: str, name: str) -> tuple[int, int] | None:
    """Return [start,end) span for a C++ function body/function by name using brace matching."""
    m = re.search(r"(?:^|\n)([^\n;{}]*\b" + re.escape(name) + r"\s*\([^;{}]*\)\s*)\{", text)
    if not m:
        return None
    start = m.start(1)
    brace = text.find("{", m.end(1) - 1)
    if brace < 0:
        return None
    depth = 0
    i = brace
    in_str = False
    in_chr = False
    esc = False
    line_comment = False
    block_comment = False
    while i < len(text):
        c = text[i]
        n = text[i + 1] if i + 1 < len(text) else ""
        if line_comment:
            if c == "\n":
                line_comment = False
            i += 1
            continue
        if block_comment:
            if c == "*" and n == "/":
                block_comment = False
                i += 2
            else:
                i += 1
            continue
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            i += 1
            continue
        if in_chr:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == "'":
                in_chr = False
            i += 1
            continue
        if c == "/" and n == "/":
            line_comment = True
            i += 2
            continue
        if c == "/" and n == "*":
            block_comment = True
            i += 2
            continue
        if c == '"':
            in_str = True
            i += 1
            continue
        if c == "'":
            in_chr = True
            i += 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return start, i + 1
        i += 1
    return None


FORCE_VP8_FUNC = r'''std::string forceVp8OnlyVideoSdp(const std::string& sdp) {
    // Stable path: this build has a wired VP8 depacketizer + FFmpeg VP8 decoder.
    // Keep only VP8 in the video media section so JVB does not select AV1/VP9/H264.
    std::vector<std::string> vp8PayloadTypes = extractVideoPayloadTypesByCodec(sdp, "VP8");
    if (vp8PayloadTypes.empty()) {
        // Jitsi commonly uses PT 100 for VP8; keep this as a fallback for synthetic SDP.
        vp8PayloadTypes.push_back("100");
    }

    const std::set<std::string> allowedVideoPayloadTypes(
        vp8PayloadTypes.begin(), vp8PayloadTypes.end()
    );
    const std::string allowedVideoPayloadList = joinPayloadTypes(vp8PayloadTypes);

    std::istringstream input(sdp);
    std::ostringstream output;
    std::string line;
    bool inVideo = false;

    while (std::getline(input, line)) {
        line = trimTrailingCr(line);
        if (startsWith(line, "m=")) {
            inVideo = startsWith(line, "m=video ");
            if (inVideo) {
                std::istringstream parts(line);
                std::string media;
                std::string port;
                std::string proto;
                parts >> media >> port >> proto;
                if (!media.empty() && !port.empty() && !proto.empty() && !allowedVideoPayloadList.empty()) {
                    output << media << " " << port << " " << proto << " " << allowedVideoPayloadList << "\r\n";
                    continue;
                }
            }
            output << line << "\r\n";
            continue;
        }

        if (inVideo) {
            if (isCodecSpecificSdpAttribute(line) && !shouldKeepCodecSpecificVideoLine(line, allowedVideoPayloadTypes)) {
                continue;
            }
            // AV1/SVC extensions are not needed on the VP8-stable path.
            if (line.find("aomediacodec.github.io/av1-rtp-spec") != std::string::npos ||
                line.find("video-layers-allocation00") != std::string::npos) {
                continue;
            }
        }

        output << line << "\r\n";
    }

    return output.str();
}'''


def patch_native_webrtc(path: pathlib.Path) -> bool:
    text = read(path)
    original = text

    # Normalize older/experimental function names back to the stable VP8 filter.
    text = re.sub(r"\b(?:preferAv1OnlyVideoSdp|forceAv1OnlyVideoSdp|preferVp8OnlyVideoSdp)\s*\(", "forceVp8OnlyVideoSdp(", text)

    replaced = False
    for fname in ("forceVp8OnlyVideoSdp", "forceAv1OnlyVideoSdp", "preferAv1OnlyVideoSdp", "preferVp8OnlyVideoSdp"):
        span = find_function_span(text, fname)
        if span:
            text = text[:span[0]] + FORCE_VP8_FUNC + text[span[1]:]
            replaced = True
            break

    if not replaced:
        marker = "std::vector<std::string> extractVideoSourceNamesFromSdp"
        pos = text.find(marker)
        if pos < 0:
            raise RuntimeError("Could not find a place to insert forceVp8OnlyVideoSdp()")
        text = text[:pos] + FORCE_VP8_FUNC + "\n\n" + text[pos:]

    # Make sure the offer and returned answer are filtered.
    text = re.sub(
        r"const\s+std::string\s+offerSdp\s*=\s*[^;]*?\(\s*rawOfferSdp\s*\)\s*;",
        "const std::string offerSdp = forceVp8OnlyVideoSdp(rawOfferSdp);",
        text,
        count=1,
        flags=re.S,
    )
    text = re.sub(
        r"outAnswer\.sdp\s*=\s*[^;]*?\(\s*impl_->localSdp\s*\)\s*;",
        "outAnswer.sdp = forceVp8OnlyVideoSdp(impl_->localSdp);",
        text,
        count=1,
        flags=re.S,
    )

    if text != original:
        write(path, text)
        return True
    return False


VP8_CODEC_FUNC = r'''bool isSupportedVideoCodec(const JingleCodec& codec) {
    const std::string name = toLower(codec.name);
    // Stable path: advertise/accept only VP8 because the wired decoder path is VP8.
    return name == "vp8";
}'''


def patch_jingle_session(path: pathlib.Path) -> bool:
    text = read(path)
    original = text
    span = find_function_span(text, "isSupportedVideoCodec")
    if not span:
        raise RuntimeError("Could not find isSupportedVideoCodec()")
    text = text[:span[0]] + VP8_CODEC_FUNC + text[span[1]:]

    # Update misleading comments if they exist.
    text = text.replace("No H264 parameters here anymore because this native receiver currently accepts only VP8 for video.",
                        "No H264/AV1 parameters here because this VP8-stable patch accepts only VP8 for video.")
    text = text.replace("Keep only abs-send-time for VP8.", "Keep only abs-send-time for VP8.")

    if text != original:
        write(path, text)
        return True
    return False


def patch_jitsi_signaling(path: pathlib.Path) -> bool:
    text = read(path)
    original = text
    # Common forms seen in this repo/history.
    replacements = {
        "av1,vp8,opus": "vp8,opus",
        "av1,opus": "vp8,opus",
        "vp8,av1,opus": "vp8,opus",
        "av1,vp9,vp8,h264,opus": "vp8,opus",
    }
    for a, b in replacements.items():
        text = text.replace(a, b)
    # XML literal generated in pieces: avoid being too clever; if a codecList string exists, normalize video list.
    text = re.sub(r"jitsi_participant_codecList>[^<\"]*", "jitsi_participant_codecList>vp8,opus", text)
    if text != original:
        write(path, text)
        return True
    return False


def remove_matching_if_block(text: str, condition_snippet: str, replacement: str) -> tuple[str, bool]:
    pos = text.find(condition_snippet)
    if pos < 0:
        return text, False
    brace = text.find("{", pos)
    if brace < 0:
        return text, False
    depth = 0
    i = brace
    while i < len(text):
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0:
                return text[:pos] + replacement + text[i + 1:], True
        i += 1
    return text, False


def patch_router(path: pathlib.Path) -> bool:
    text = read(path)
    original = text

    # Remove the early "VP8 while AV1 decoder path is active" skip block, if present.
    sentinel = "// This build currently has a working AV1 decode path"
    start = text.find(sentinel)
    if start >= 0:
        end_marker = "++routedVideoPackets_;"
        end = text.find(end_marker, start)
        if end >= 0:
            text = text[:start] + "// VP8-stable path: route VP8 into the VP8 depacketizer/decoder.\n        " + text[end:]

    # Disable the AV1 dav1d branch in VP8-stable mode; non-VP8 packets are dropped by the existing block below.
    text, _ = remove_matching_if_block(
        text,
        "if (rtp.payloadType == 41)",
        "// AV1 dav1d branch disabled by repo-patch-v8 VP8-stable mode; non-VP8 video is dropped below.\n        "
    )

    # If the source uses payloadType variable instead of rtp.payloadType, handle that too.
    text, _ = remove_matching_if_block(
        text,
        "if (payloadType == 41)",
        "// AV1 dav1d branch disabled by repo-patch-v8 VP8-stable mode; non-VP8 video is dropped below.\n        "
    )

    # Update comments that would otherwise confuse later debugging.
    text = text.replace("Our current decoder path is VP8-only.", "The active decoder path is VP8-only.")
    text = text.replace("If AV1/VP9/H264 RTP packets are accidentally passed into the VP8 decoder", "If AV1/VP9/H264 RTP packets are received despite VP8-only negotiation")

    if text != original:
        write(path, text)
        return True
    return False


def patch_ndi_sender(path: pathlib.Path) -> bool:
    text = read(path)
    original = text
    text = re.sub(r"createDesc\.clock_audio\s*=\s*true\s*;", "createDesc.clock_audio = false;", text)
    text = text.replace("// REVERT_VP8_AUDIO_V6: let NDI clock audio", "// repo-patch-v8: RTP arrival already clocks audio; do not block the RTP callback thread")
    if text != original:
        write(path, text)
        return True
    return False


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--no-backup", action="store_true")
    args = parser.parse_args()

    root = pathlib.Path.cwd()
    required = [
        root / "src" / "NativeWebRTCAnswerer.cpp",
        root / "src" / "JingleSession.cpp",
        root / "src" / "JitsiSignaling.cpp",
        root / "src" / "PerParticipantNdiRouter.cpp",
        root / "src" / "NDISender.cpp",
    ]
    missing = [str(p) for p in required if not p.exists()]
    if missing:
        log("Missing expected files:\n  " + "\n  ".join(missing))
        log("Run this script from the repository root, for example: D:\\MEDIA\\Desktop\\jitsi-ndi-native")
        return 2

    backup_root = root / ".jnn_patch_backups" / ("repo_patch_v8_" + _dt.datetime.now().strftime("%Y%m%d_%H%M%S"))
    if not args.no_backup:
        for p in required:
            backup(p, backup_root)
        log(f"Backups written to {backup_root}")

    changed = []
    operations = [
        ("NativeWebRTCAnswerer.cpp", patch_native_webrtc, required[0]),
        ("JingleSession.cpp", patch_jingle_session, required[1]),
        ("JitsiSignaling.cpp", patch_jitsi_signaling, required[2]),
        ("PerParticipantNdiRouter.cpp", patch_router, required[3]),
        ("NDISender.cpp", patch_ndi_sender, required[4]),
    ]
    for label, fn, path in operations:
        try:
            if fn(path):
                changed.append(label)
                log(f"patched {label}")
            else:
                log(f"no change needed for {label}")
        except Exception as e:
            log(f"ERROR while patching {label}: {e}")
            return 3

    log("Done. Changed: " + (", ".join(changed) if changed else "nothing"))
    log("Now run: cmake --build build --config Release")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
