#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Hotfix for compile error:
  Av1RtpFrameAssembler::pushRtp cannot accept const RtpPacketView
"""
from __future__ import annotations

import datetime
import re
import shutil
import sys
from pathlib import Path

ROOT = Path.cwd()
SRC = ROOT / "src"
BACKUP = ROOT / ("rtp_view_hotfix_backup_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))

FULL_DATA_NAMES = ["data", "packet", "packetData", "rtp", "rtpData", "raw", "rawData", "buffer", "bytes"]
FULL_SIZE_NAMES = ["size", "packetSize", "rtpSize", "rawSize", "dataSize", "bufferSize", "bytesSize", "length", "len"]
PAYLOAD_NAMES = ["payload", "payloadData", "payloadPtr", "payloadBytes"]
PAYLOAD_SIZE_NAMES = ["payloadSize", "payloadLen", "payloadLength", "payloadBytes", "size"]
SEQ_NAMES = ["sequence", "sequenceNumber", "seq", "seqNumber", "sequence_number"]
TS_NAMES = ["timestamp", "rtpTimestamp", "ts", "rtpTs", "rtp_timestamp"]
MARKER_NAMES = ["marker", "markerBit", "isMarker", "m"]


def info(msg: str) -> None:
    print(f"[RTP VIEW HOTFIX] {msg}")


def warn(msg: str) -> None:
    print(f"[RTP VIEW HOTFIX] WARN: {msg}")


def die(msg: str) -> None:
    print(f"[RTP VIEW HOTFIX] ERROR: {msg}")
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


def find_struct_body() -> tuple[Path | None, str | None]:
    for p in SRC.rglob("*.h"):
        t = read(p)
        m = re.search(r"(?:struct|class)\s+RtpPacketView\s*\{(?P<body>.*?)\};", t, re.S)
        if m:
            return p, m.group("body")
    return None, None


def parse_fields(body: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in body.splitlines():
        line = re.sub(r"//.*", "", line).strip()
        if not line or "(" in line or ";" not in line:
            continue
        m = re.search(r"(?P<type>[A-Za-z_:<>\s\*&]+?)\s+(?P<name>[A-Za-z_]\w*)\s*(?:[=;]|,)", line)
        if m:
            fields[m.group("name")] = " ".join(m.group("type").split())
    return fields


def prefer(names: list[str], fields: dict[str, str]) -> str | None:
    for n in names:
        if n in fields:
            return n
    low = {k.lower(): k for k in fields}
    for n in names:
        if n.lower() in low:
            return low[n.lower()]
    return None


def is_vector_type(tp: str) -> bool:
    return "vector" in tp and "uint8" in tp


def data_expr(field: str, tp: str) -> str:
    if is_vector_type(tp):
        return f"packet.{field}.data()"
    return f"packet.{field}"


def size_expr(size_field: str, size_tp: str) -> str:
    if is_vector_type(size_tp):
        return f"packet.{size_field}.size()"
    return f"packet.{size_field}"


def insert_after_vector_overload(text: str, overload: str) -> str:
    marker = "std::vector<EncodedVideoFrame> pushRtp(const std::vector<uint8_t>& packet)"
    pos = text.find(marker)
    if pos < 0:
        die("Could not find vector pushRtp overload in Av1RtpFrameAssembler.h")
    m = re.search(
        r"std::vector<EncodedVideoFrame>\s+pushRtp\s*\(const\s+std::vector<uint8_t>&\s+packet\)\s*\{.*?\n\s*\}",
        text[pos:],
        re.S,
    )
    if not m:
        die("Could not locate end of vector pushRtp overload")
    insert_at = pos + m.end()
    return text[:insert_at] + overload + text[insert_at:]


def patch_header_for_full_packet(h: Path, data_field: str, data_tp: str, size_field: str, size_tp: str) -> None:
    t = read(h)
    if "RTP_VIEW_HOTFIX" in t:
        info("Av1RtpFrameAssembler.h already contains RTP view hotfix")
        return
    call_data = data_expr(data_field, data_tp)
    call_size = size_expr(size_field, size_tp)
    overload = (
        "\n"
        "    // RTP_VIEW_HOTFIX: accept current project RtpPacketView-like objects.\n"
        "    template <typename PacketView>\n"
        "    std::vector<EncodedVideoFrame> pushRtp(const PacketView& packet) {\n"
        f"        return pushRtp(reinterpret_cast<const uint8_t*>({call_data}), static_cast<size_t>({call_size}));\n"
        "    }\n"
    )
    backup(h)
    write(h, insert_after_vector_overload(t, overload))
    info(f"patched Av1RtpFrameAssembler.h: pushRtp(PacketView) uses packet.{data_field} + packet.{size_field}")


def patch_header_and_cpp_for_payload(
    h: Path,
    cpp: Path,
    payload_field: str,
    payload_tp: str,
    payload_size_field: str,
    payload_size_tp: str,
    seq_field: str,
    ts_field: str,
    marker_field: str,
) -> None:
    ht = read(h)
    if "RTP_VIEW_HOTFIX" not in ht:
        method_decl = "    std::vector<EncodedVideoFrame> pushRtpPayload(uint16_t sequence, uint32_t timestamp, bool marker, const uint8_t* payload, size_t payloadSize);\n"
        if "pushRtpPayload(uint16_t" not in ht:
            marker = "std::vector<EncodedVideoFrame> pushRtp(const uint8_t* data, size_t size);"
            if marker not in ht:
                die("Could not find main pushRtp declaration in Av1RtpFrameAssembler.h")
            ht = ht.replace(marker, marker + "\n" + method_decl, 1)

        call_payload = data_expr(payload_field, payload_tp)
        call_size = size_expr(payload_size_field, payload_size_tp)
        overload = (
            "\n"
            "    // RTP_VIEW_HOTFIX: accept current project RtpPacketView-like objects carrying parsed RTP payload.\n"
            "    template <typename PacketView>\n"
            "    std::vector<EncodedVideoFrame> pushRtp(const PacketView& packet) {\n"
            "        return pushRtpPayload(\n"
            f"            static_cast<uint16_t>(packet.{seq_field}),\n"
            f"            static_cast<uint32_t>(packet.{ts_field}),\n"
            f"            static_cast<bool>(packet.{marker_field}),\n"
            f"            reinterpret_cast<const uint8_t*>({call_payload}),\n"
            f"            static_cast<size_t>({call_size}));\n"
            "    }\n"
        )
        backup(h)
        write(h, insert_after_vector_overload(ht, overload))
        info("patched Av1RtpFrameAssembler.h: pushRtp(PacketView) uses parsed payload fields")
    else:
        info("Av1RtpFrameAssembler.h already contains RTP view hotfix")

    ct = read(cpp)
    if "pushRtpPayload(uint16_t" in ct:
        info("Av1RtpFrameAssembler.cpp already contains pushRtpPayload")
        return
    impl = """
std::vector<EncodedVideoFrame> Av1RtpFrameAssembler::pushRtpPayload(
    uint16_t sequence,
    uint32_t timestamp,
    bool marker,
    const uint8_t* payload,
    size_t payloadSize) {

    if (!payload || payloadSize == 0) {
        return {};
    }

    if (!haveExpectedSeq_) {
        haveExpectedSeq_ = true;
        expectedSeq_ = sequence;
    }

    if (reorder_.find(sequence) != reorder_.end()) {
        return {};
    }

    RtpPacket packet;
    packet.sequence = sequence;
    packet.timestamp = timestamp;
    packet.marker = marker;
    packet.payload.assign(payload, payload + payloadSize);
    reorder_.emplace(packet.sequence, std::move(packet));

    return drainReorderBuffer();
}

"""
    pos = ct.find("std::vector<EncodedVideoFrame> Av1RtpFrameAssembler::drainReorderBuffer")
    if pos < 0:
        die("Could not find drainReorderBuffer implementation in Av1RtpFrameAssembler.cpp")
    backup(cpp)
    write(cpp, ct[:pos] + impl + ct[pos:])
    info("patched Av1RtpFrameAssembler.cpp: added pushRtpPayload implementation")


def main() -> None:
    if not SRC.exists():
        die("Run from project root, e.g. D:\\MEDIA\\Desktop\\jitsi-ndi-native")
    h = SRC / "Av1RtpFrameAssembler.h"
    cpp = SRC / "Av1RtpFrameAssembler.cpp"
    if not h.exists() or not cpp.exists():
        die("src/Av1RtpFrameAssembler.h/.cpp not found")

    struct_file, body = find_struct_body()
    if body is None:
        warn("Could not find struct RtpPacketView. Applying most common .data/.size template overload.")
        patch_header_for_full_packet(h, "data", "const uint8_t*", "size", "size_t")
        return

    fields = parse_fields(body)
    info(f"found RtpPacketView in {struct_file.relative_to(ROOT)}")
    info("detected fields: " + ", ".join(f"{k}:{v}" for k, v in fields.items()))

    data_f = prefer(FULL_DATA_NAMES, fields)
    size_f = prefer(FULL_SIZE_NAMES, fields)
    if data_f and size_f:
        patch_header_for_full_packet(h, data_f, fields[data_f], size_f, fields[size_f])
        return

    payload_f = prefer(PAYLOAD_NAMES, fields)
    payload_size_f = prefer(PAYLOAD_SIZE_NAMES, fields)
    seq_f = prefer(SEQ_NAMES, fields)
    ts_f = prefer(TS_NAMES, fields)
    marker_f = prefer(MARKER_NAMES, fields)

    if payload_f and payload_size_f and seq_f and ts_f and marker_f:
        patch_header_and_cpp_for_payload(
            h,
            cpp,
            payload_f,
            fields[payload_f],
            payload_size_f,
            fields[payload_size_f],
            seq_f,
            ts_f,
            marker_f,
        )
        return

    warn("Could not confidently map RtpPacketView fields.")
    warn("Applying fallback .data/.size overload; if it fails, send RtpPacketView definition.")
    patch_header_for_full_packet(h, "data", "const uint8_t*", "size", "size_t")


if __name__ == "__main__":
    main()
