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
BACKUP = ROOT / ("force_vp8_compile_v5_backup_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))


def info(msg: str) -> None:
    print(f"[FORCE_VP8_COMPILE_V5] {msg}")


def warn(msg: str) -> None:
    print(f"[FORCE_VP8_COMPILE_V5] WARN: {msg}")


def die(msg: str) -> None:
    print(f"[FORCE_VP8_COMPILE_V5] ERROR: {msg}")
    sys.exit(1)


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


def write(p: Path, s: str) -> None:
    p.write_text(s, encoding="utf-8", newline="")


def backup(p: Path) -> None:
    dst = BACKUP / p.relative_to(ROOT)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(p, dst)


def add_include_once(text: str, include: str) -> str:
    line = f"#include {include}"
    if line in text:
        return text
    includes = list(re.finditer(r"^#include\s+[<\"].*?[>\"]\s*$", text, re.M))
    if not includes:
        return line + "\n" + text
    pos = includes[-1].end()
    return text[:pos] + "\n" + line + text[pos:]


def insert_after_includes(text: str, block: str) -> str:
    includes = list(re.finditer(r"^#include\s+[<\"].*?[>\"]\s*$", text, re.M))
    if not includes:
        return block.strip() + "\n\n" + text
    pos = includes[-1].end()
    return text[:pos] + "\n\n" + block.strip() + "\n" + text[pos:]


def strip_region(text: str, begin_marker: str, end_marker: str) -> str:
    # Removes a previous generated helper/call region by comment markers.
    return re.sub(r"\n?//\s*" + re.escape(begin_marker) + r".*?//\s*" + re.escape(end_marker) + r"\n?", "\n", text, flags=re.S)


def src_files() -> list[Path]:
    return list(SRC.rglob("*.cpp")) + list(SRC.rglob("*.h")) + list(SRC.rglob("*.hpp"))


JINGLE_HELPER = r'''
// JNN_FORCE_JINGLE_VP8_COMPILE_V5_BEGIN
static std::string jnnEraseXmlElementAroundVp8V5(std::string xml, size_t pos, const std::string& elementName) {
    const std::string open = "<" + elementName;
    const size_t start = xml.rfind(open, pos);
    if (start == std::string::npos) return xml;

    const std::string close = "</" + elementName + ">";
    size_t end = xml.find(close, pos);
    if (end != std::string::npos) {
        end += close.size();
    } else {
        end = xml.find("/>", pos);
        if (end == std::string::npos) return xml;
        end += 2;
    }
    xml.erase(start, end - start);
    return xml;
}

static std::string jnnErasePayloadTypeByCodecNameVp8V5(std::string xml, const std::string& codecName) {
    for (;;) {
        size_t pos = xml.find("name='" + codecName + "'");
        if (pos == std::string::npos) pos = xml.find("name=\"" + codecName + "\"");
        if (pos == std::string::npos) break;
        xml = jnnEraseXmlElementAroundVp8V5(std::move(xml), pos, "payload-type");
    }
    return xml;
}

static std::string jnnEraseRtpHeaderExtensionByTextVp8V5(std::string xml, const std::string& needle) {
    for (;;) {
        size_t pos = xml.find(needle);
        if (pos == std::string::npos) break;
        xml = jnnEraseXmlElementAroundVp8V5(std::move(xml), pos, "rtp-hdrext");
    }
    return xml;
}

static std::string jnnForceJingleSessionAcceptVp8OnlyV5(std::string xml) {
    if (xml.find("session-accept") == std::string::npos) return xml;
    xml = jnnErasePayloadTypeByCodecNameVp8V5(std::move(xml), "AV1");
    xml = jnnErasePayloadTypeByCodecNameVp8V5(std::move(xml), "H264");
    xml = jnnErasePayloadTypeByCodecNameVp8V5(std::move(xml), "VP9");
    xml = jnnEraseRtpHeaderExtensionByTextVp8V5(std::move(xml), "dependency-descriptor");
    xml = jnnEraseRtpHeaderExtensionByTextVp8V5(std::move(xml), "video-layers-allocation");
    return xml;
}
// JNN_FORCE_JINGLE_VP8_COMPILE_V5_END
'''


def find_native_answerer() -> Path | None:
    p = SRC / "NativeWebRTCAnswerer.cpp"
    if p.exists():
        return p
    for f in src_files():
        t = read(f)
        if "NativeWebRTCAnswerer" in t or "setting remote Jitsi SDP-like offer" in t or "local SDP description generated" in t:
            return f
    return None


def find_jitsi_signaling() -> Path | None:
    p = SRC / "JitsiSignaling.cpp"
    if p.exists():
        return p
    for f in src_files():
        t = read(f)
        if "session-accept XML" in t:
            return f
    return None


def remove_broken_native_sdp_filter() -> None:
    p = find_native_answerer()
    if not p:
        warn("NativeWebRTCAnswerer.cpp not found; skipping broken SDP call cleanup")
        return
    t = read(p)
    original = t

    # The v4 patch may have inserted a line like:
    #     sdp = jnnForceSdpVideoVp8Only(sdp); // JNN_FORCE_REMOTE_OFFER_VP8_REAL_V4_APPLIED
    # In the current code that line can land where no variable named `sdp` exists.
    bad_patterns = [
        r"^[ \t]*[A-Za-z_]\w*\s*=\s*jnnForceSdpVideoVp8Only\s*\([^\n;]*\)\s*;\s*//\s*JNN_FORCE_REMOTE_OFFER_VP8_REAL_V4_APPLIED\s*\r?\n",
        r"^[ \t]*(?:std::string|auto)\s+[A-Za-z_]\w*\s*=\s*jnnForceSdpVideoVp8Only\s*\([^\n;]*\)\s*;\s*//\s*JNN_FORCE_REMOTE_OFFER_VP8_REAL_V4_APPLIED\s*\r?\n",
    ]
    removed = 0
    for pat in bad_patterns:
        t, n = re.subn(pat, "", t, flags=re.M)
        removed += n

    # Also remove the unused v4 remote SDP helper to avoid any accidental future conflict.
    t = strip_region(t, "JNN_FORCE_VP8_REAL_V4_BEGIN", "JNN_FORCE_VP8_REAL_V4_END")

    if t != original:
        backup(p)
        write(p, t)
        info(f"cleaned {p.relative_to(ROOT)}: removed broken remote SDP VP8 filter call(s): {removed}")
    else:
        info(f"{p.relative_to(ROOT)}: no broken remote SDP VP8 filter call found")


def make_mutable_near(text: str, var: str, pos: int) -> str:
    start = max(0, pos - 12000)
    window = text[start:pos]
    # Convert only the nearest declaration before the insertion point.
    patterns = [
        re.compile(r"const\s+std::string\s+" + re.escape(var) + r"\s*="),
        re.compile(r"const\s+auto\s+" + re.escape(var) + r"\s*="),
    ]
    for pattern in patterns:
        matches = list(pattern.finditer(window))
        if matches:
            m = matches[-1]
            repl = ("std::string " + var + " =") if "std::string" in m.group(0) else ("auto " + var + " =")
            return text[:start + m.start()] + repl + text[start + m.end():]
    return text


def detect_xml_var_before_log(text: str, log_pos: int) -> str | None:
    before_start = max(0, log_pos - 10000)
    before = text[before_start:log_pos]
    preferred = ["sessionAcceptXml", "acceptXml", "jingleXml", "iqXml", "xml", "out", "result", "sessionAccept", "accept"]
    for name in preferred:
        if re.search(r"(?:const\s+)?(?:std::string|auto)\s+" + re.escape(name) + r"\b", before) or re.search(r"\b" + re.escape(name) + r"\s*=", before):
            return name

    # Pick the last string-like variable whose declaration RHS looks like an iq/jingle XML builder.
    decls = list(re.finditer(r"(?:const\s+)?(?:std::string|auto)\s+([A-Za-z_]\w*)\s*=\s*([^;]{0,2000});", before, re.S))
    for m in reversed(decls):
        rhs = m.group(2)
        if any(token in rhs for token in ["session-accept", "<jingle", "<iq", "jingle", "session_accept"]):
            return m.group(1)

    # Fall back to variables being printed in the log line.
    near = text[log_pos:min(len(text), log_pos + 1200)]
    for m in re.finditer(r"(?:\+|<<|,)\s*([A-Za-z_]\w*)\s*(?:\.c_str\s*\(\s*\))?", near):
        var = m.group(1)
        if var not in {"std", "string", "INFO", "WARN", "ERROR", "Log", "Logger"}:
            return var
    return None


def find_session_accept_log(text: str) -> int:
    for needle in ["JingleSession: session-accept XML", "session-accept XML:", "session-accept XML"]:
        pos = text.find(needle)
        if pos >= 0:
            return pos
    return -1


def ensure_jingle_session_accept_filter() -> None:
    p = find_jitsi_signaling()
    if not p:
        warn("JitsiSignaling.cpp not found; cannot ensure session-accept VP8 filter")
        return
    t = read(p)
    original = t

    # Remove older helper blocks and older call markers so v5 is the single source of truth.
    for begin, end in [
        ("JNN_FORCE_JINGLE_VP8_HOTFIX_BEGIN", "JNN_FORCE_JINGLE_VP8_HOTFIX_END"),
        ("JNN_FORCE_JINGLE_VP8_REAL_V4_BEGIN", "JNN_FORCE_JINGLE_VP8_REAL_V4_END"),
        ("JNN_FORCE_JINGLE_VP8_COMPILE_V5_BEGIN", "JNN_FORCE_JINGLE_VP8_COMPILE_V5_END"),
    ]:
        t = strip_region(t, begin, end)

    old_calls = [
        r"^[ \t]*[A-Za-z_]\w*\s*=\s*jnnForceJingleSessionAcceptVp8Only(?:V4)?\s*\([^\n;]*\)\s*;\s*//\s*JNN_FORCE_JINGLE_VP8(?:_REAL_V4)?_APPLIED\s*\r?\n",
    ]
    for pat in old_calls:
        t = re.sub(pat, "", t, flags=re.M)

    t = add_include_once(t, "<string>")
    t = add_include_once(t, "<utility>")
    t = insert_after_includes(t, JINGLE_HELPER)

    if "JNN_FORCE_JINGLE_VP8_COMPILE_V5_APPLIED" not in t:
        log_pos = find_session_accept_log(t)
        if log_pos < 0:
            warn(f"{p.relative_to(ROOT)}: session-accept XML log not found; VP8 XML filter call was not inserted")
        else:
            var = detect_xml_var_before_log(t, log_pos)
            if not var:
                warn(f"{p.relative_to(ROOT)}: could not detect XML variable near session-accept log")
            else:
                t = make_mutable_near(t, var, log_pos)
                insert_at = t.rfind("\n", 0, log_pos) + 1
                indent = re.match(r"[ \t]*", t[insert_at:]).group(0)
                call = f"{indent}{var} = jnnForceJingleSessionAcceptVp8OnlyV5(std::move({var})); // JNN_FORCE_JINGLE_VP8_COMPILE_V5_APPLIED\n"
                t = t[:insert_at] + call + t[insert_at:]
                info(f"patched {p.relative_to(ROOT)}: session-accept XML is filtered to VP8 only via variable '{var}'")

    if t != original:
        backup(p)
        write(p, t)
    else:
        info(f"{p.relative_to(ROOT)}: no changes needed")


def main() -> None:
    if not SRC.exists():
        die(r"Run this from project root, e.g. D:\MEDIA\Desktop\jitsi-ndi-native")
    remove_broken_native_sdp_filter()
    ensure_jingle_session_accept_filter()
    info(f"backup folder: {BACKUP}")
    info("done. Rebuild with: cmake --build build --config Release")


if __name__ == "__main__":
    main()
