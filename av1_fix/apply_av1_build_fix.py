#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Small follow-up fix for the AV1 patch in jitsi-ndi-native.
Run from repository root:

    python .\av1_fix\apply_av1_build_fix.py

Fixes:
  1) Av1RtpFrameAssembler.cpp used frame.data, but this project may name the
     EncodedVideoFrame byte vector differently.
  2) PerParticipantNdiRouter.cpp now calls p.av1, but some local headers did not
     get Av1RtpFrameAssembler av1; inserted into ParticipantPipeline.
"""
from __future__ import annotations

import re
import shutil
from pathlib import Path

ROOT = Path.cwd()
SRC = ROOT / "src"


def die(msg: str) -> None:
    raise SystemExit("[AV1 BUILD FIX] ERROR: " + msg)


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def write(path: Path, text: str) -> None:
    if path.exists():
        backup = path.with_suffix(path.suffix + ".bak_av1_build_fix")
        if not backup.exists():
            shutil.copy2(path, backup)
    path.write_text(text, encoding="utf-8", newline="")


def ensure(path: Path) -> None:
    if not path.exists():
        die(f"missing file: {path}")


def find_matching_brace(text: str, open_pos: int) -> int | None:
    depth = 0
    i = open_pos
    while i < len(text):
        ch = text[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def detect_encoded_video_frame_bytes_field() -> str:
    candidates = [
        SRC / "Vp8RtpDepacketizer.h",
        SRC / "FfmpegMediaDecoder.h",
        SRC / "Av1RtpFrameAssembler.h",
    ]

    for path in candidates:
        if not path.exists():
            continue
        text = read(path)
        m = re.search(r"struct\s+EncodedVideoFrame\s*\{([\s\S]*?)\};", text)
        if not m:
            continue
        body = m.group(1)

        # Prefer the vector<uint8_t> member; this is what FFmpeg decoders consume.
        vector_patterns = [
            r"std::vector\s*<\s*std::uint8_t\s*>\s+(\w+)\s*;",
            r"std::vector\s*<\s*uint8_t\s*>\s+(\w+)\s*;",
            r"std::vector\s*<\s*unsigned\s+char\s*>\s+(\w+)\s*;",
            r"std::vector\s*<[^>]*uint8_t[^>]*>\s+(\w+)\s*;",
        ]
        for pat in vector_patterns:
            vm = re.search(pat, body)
            if vm:
                field = vm.group(1)
                print(f"[AV1 BUILD FIX] EncodedVideoFrame byte vector field detected: {field}")
                return field

        # Conservative fallbacks by common names.
        for name in ["bytes", "buffer", "payload", "data", "encoded", "frame"]:
            if re.search(r"\b" + re.escape(name) + r"\s*;", body):
                print(f"[AV1 BUILD FIX] EncodedVideoFrame fallback field detected: {name}")
                return name

    die("could not detect byte vector field in struct EncodedVideoFrame")


def patch_av1_assembler_cpp() -> None:
    path = SRC / "Av1RtpFrameAssembler.cpp"
    ensure(path)
    text = read(path)
    field = detect_encoded_video_frame_bytes_field()

    original = text

    # Replace the bad assumption from the first patch.
    text = re.sub(
        r"frame\s*\.\s*data\s*=\s*std::move\s*\(\s*currentFrame_\s*\)\s*;",
        f"frame.{field} = std::move(currentFrame_);",
        text,
        count=1,
    )

    # If someone manually changed it to another wrong name, patch the exact assignment
    # inside flushCurrentFrame without touching frame.timestamp.
    if text == original and f"frame.{field} = std::move(currentFrame_);" not in text:
        m = re.search(r"EncodedVideoFrame\s+frame\s*;([\s\S]*?)out\.push_back", text)
        if m:
            block = m.group(1)
            assignment = re.search(r"frame\s*\.\s*\w+\s*=\s*std::move\s*\(\s*currentFrame_\s*\)\s*;", block)
            if assignment:
                abs_start = m.start(1) + assignment.start()
                abs_end = m.start(1) + assignment.end()
                text = text[:abs_start] + f"frame.{field} = std::move(currentFrame_);" + text[abs_end:]

    if text != original:
        write(path, text)
        print(f"[AV1 BUILD FIX] patched {path}: frame.{field}")
    else:
        print(f"[AV1 BUILD FIX] {path} already uses frame.{field} or no change needed")


def insert_member_in_participant_pipeline(text: str, member_line: str) -> tuple[str, bool]:
    m = re.search(r"struct\s+ParticipantPipeline\s*\{", text)
    if not m:
        die("could not find struct ParticipantPipeline in PerParticipantNdiRouter.h")

    open_pos = text.find("{", m.start())
    close_pos = find_matching_brace(text, open_pos)
    if close_pos is None:
        die("could not find end of ParticipantPipeline block")

    block = text[open_pos + 1:close_pos]
    type_name = member_line.strip().split()[0]
    var_name = member_line.strip().split()[1].rstrip(";")

    if re.search(r"\b" + re.escape(type_name) + r"\s+" + re.escape(var_name) + r"\s*;", block):
        return text, False

    # Use indentation from nearby member lines.
    indent = "        "
    member_line_match = re.search(r"\n(\s+)[A-Za-z_][^;{}]*;", block)
    if member_line_match:
        indent = member_line_match.group(1)

    line_to_insert = "\n" + indent + member_line.strip()

    # Prefer placing av1 assembler after the existing vp8 assembler/member.
    targets = [
        r"\n\s*[^\n;]*\bvp8\s*;",
        r"\n\s*Vp8[^\n;]*;",
        r"\n\s*FfmpegAv1Decoder\s+av1Decoder\s*;",
        r"\n\s*FfmpegVp8Decoder[^\n;]*;",
    ]

    for pat in targets:
        matches = list(re.finditer(pat, block))
        if matches:
            last = matches[-1]
            insert_at = open_pos + 1 + last.end()
            return text[:insert_at] + line_to_insert + text[insert_at:], True

    # Fallback: insert before the closing brace of the pipeline block.
    return text[:close_pos] + line_to_insert + "\n" + text[close_pos:], True


def patch_router_header() -> None:
    path = SRC / "PerParticipantNdiRouter.h"
    ensure(path)
    text = read(path)
    original = text

    if "Av1RtpFrameAssembler.h" not in text:
        include_line = '#include "Av1RtpFrameAssembler.h"\n'
        include_targets = [
            r"#include\s+\"Vp8RtpDepacketizer\.h\"\s*\n",
            r"#include\s+\"FfmpegMediaDecoder\.h\"\s*\n",
        ]
        inserted = False
        for pat in include_targets:
            m = re.search(pat, text)
            if m:
                text = text[:m.end()] + include_line + text[m.end():]
                inserted = True
                break
        if not inserted:
            text = include_line + text

    text, inserted_av1 = insert_member_in_participant_pipeline(
        text,
        "Av1RtpFrameAssembler av1;"
    )

    if "FfmpegAv1Decoder av1Decoder" not in text:
        text, inserted_decoder = insert_member_in_participant_pipeline(
            text,
            "FfmpegAv1Decoder av1Decoder;"
        )
    else:
        inserted_decoder = False

    if text != original:
        write(path, text)
        print(f"[AV1 BUILD FIX] patched {path}")
        if inserted_av1:
            print("[AV1 BUILD FIX] added ParticipantPipeline::av1")
        if inserted_decoder:
            print("[AV1 BUILD FIX] added ParticipantPipeline::av1Decoder")
    else:
        print(f"[AV1 BUILD FIX] {path} already contains AV1 members")


def main() -> None:
    if not SRC.exists():
        die("run from repository root; expected ./src")

    patch_av1_assembler_cpp()
    patch_router_header()

    print("[AV1 BUILD FIX] done")
    print("[AV1 BUILD FIX] now run:")
    print("    cmake --build build --config Release")


if __name__ == "__main__":
    main()
