#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
VP8 hotfix v3 for jitsi-ndi-native.

Fixes v2 compile error where the patch tried to assign to a const std::string
near the outgoing Jingle session-accept XML log.

Run from project root:
  cd D:\\MEDIA\\Desktop\\jitsi-ndi-native
  python .\\vp8_hotfix_v3\\jitsi_ndi_native_force_vp8_hotfix_v3\\fix_force_vp8_v3.py
"""
from __future__ import annotations

import datetime
import re
import shutil
import sys
from pathlib import Path

ROOT = Path.cwd()
SRC = ROOT / "src"
BACKUP = ROOT / ("force_vp8_hotfix_v3_backup_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))


def info(msg: str) -> None:
    print(f"[FORCE_VP8_V3] {msg}")


def warn(msg: str) -> None:
    print(f"[FORCE_VP8_V3] WARN: {msg}")


def die(msg: str) -> None:
    print(f"[FORCE_VP8_V3] ERROR: {msg}")
    sys.exit(1)


def read(p: Path) -> str:
    return p.read_text(encoding="utf-8", errors="replace")


def write(p: Path, s: str) -> None:
    p.write_text(s, encoding="utf-8", newline="")


def backup(p: Path) -> None:
    dst = BACKUP / p.relative_to(ROOT)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(p, dst)


def src_files() -> list[Path]:
    return list(SRC.rglob("*.cpp")) + list(SRC.rglob("*.h")) + list(SRC.rglob("*.hpp"))


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


JINGLE_HELPER = r'''
// JNN_FORCE_JINGLE_VP8_HOTFIX_BEGIN
// Temporary compatibility fix: do not advertise AV1/H264/VP9 in outgoing
// Jingle session-accept. This avoids libdav1d errors from malformed/unsupported
// AV1 RTP reassembly while we stabilize the native RTP path.
static std::string jnnErasePayloadTypeByCodecName(std::string xml, const std::string& codecName) {
    for (;;) {
        size_t pos = xml.find("name='" + codecName + "'");
        if (pos == std::string::npos) pos = xml.find("name=\"" + codecName + "\"");
        if (pos == std::string::npos) break;

        const size_t start = xml.rfind("<payload-type", pos);
        if (start == std::string::npos) break;

        size_t end = xml.find("</payload-type>", pos);
        if (end != std::string::npos) {
            end += std::string("</payload-type>").size();
        } else {
            end = xml.find("/>", pos);
            if (end == std::string::npos) break;
            end += 2;
        }
        xml.erase(start, end - start);
    }
    return xml;
}

static std::string jnnEraseHeaderExtensionByText(std::string xml, const std::string& needle) {
    for (;;) {
        size_t pos = xml.find(needle);
        if (pos == std::string::npos) break;
        const size_t start = xml.rfind("<rtp-hdrext", pos);
        if (start == std::string::npos) break;
        size_t end = xml.find("/>", pos);
        if (end == std::string::npos) break;
        end += 2;
        xml.erase(start, end - start);
    }
    return xml;
}

static std::string jnnForceJingleSessionAcceptVp8Only(std::string xml) {
    if (xml.find("session-accept") == std::string::npos) {
        return xml;
    }
    xml = jnnErasePayloadTypeByCodecName(std::move(xml), "AV1");
    xml = jnnErasePayloadTypeByCodecName(std::move(xml), "H264");
    xml = jnnErasePayloadTypeByCodecName(std::move(xml), "VP9");
    xml = jnnEraseHeaderExtensionByText(std::move(xml), "dependency-descriptor");
    xml = jnnEraseHeaderExtensionByText(std::move(xml), "video-layers-allocation");
    return xml;
}
// JNN_FORCE_JINGLE_VP8_HOTFIX_END
'''


def remove_bad_v2_call(text: str) -> tuple[str, int]:
    # Remove the build-breaking v2 line, wherever it landed.
    pat = re.compile(
        r"^[ \t]*(?:[A-Za-z_]\w*)\s*=\s*jnnForceJingleSessionAcceptVp8Only\s*\(\s*std::move\s*\(\s*(?:[A-Za-z_]\w*)\s*\)\s*\)\s*;\s*//\s*JNN_FORCE_JINGLE_VP8_APPLIED\s*\r?\n",
        re.M,
    )
    return pat.subn("", text)


def cleanup_everywhere() -> int:
    total = 0
    for p in src_files():
        t = read(p)
        t2, n = remove_bad_v2_call(t)
        if n:
            backup(p)
            write(p, t2)
            total += n
            info(f"removed old/broken const assignment from {p.relative_to(ROOT)}: {n}")
    return total


def find_jitsi_signaling() -> Path | None:
    direct = SRC / "JitsiSignaling.cpp"
    if direct.exists():
        return direct
    for p in src_files():
        t = read(p)
        if "session-accept XML" in t or "JNN_FORCE_JINGLE_VP8_HOTFIX_BEGIN" in t:
            return p
    return None


def strip_helper_regions(text: str) -> str:
    # Remove duplicate helper regions, then v3 adds a single clean one.
    return re.sub(
        r"\n?// JNN_FORCE_JINGLE_VP8_HOTFIX_BEGIN.*?// JNN_FORCE_JINGLE_VP8_HOTFIX_END\n?",
        "\n",
        text,
        flags=re.S,
    )


def looks_like_inside_function(text: str, pos: int) -> bool:
    prefix = text[:pos]
    return prefix.count("{") > prefix.count("}")


def find_session_accept_log(text: str) -> int:
    # Prefer the real log line, not comments/helper text.
    for needle in ["JingleSession: session-accept XML", "session-accept XML:", "session-accept XML"]:
        start = 0
        while True:
            pos = text.find(needle, start)
            if pos < 0:
                break
            vicinity = text[max(0, pos - 300):pos + 300]
            if "JNN_FORCE_JINGLE_VP8_HOTFIX" not in vicinity and looks_like_inside_function(text, pos):
                return pos
            start = pos + 1
    return -1


def detect_xml_var(text: str, log_pos: int) -> str:
    # In this project this is usually named xml. Keep a fallback detector.
    before = text[max(0, log_pos - 5000):log_pos]
    for name in ["xml", "sessionAcceptXml", "acceptXml", "jingleXml", "iqXml", "session_accept_xml", "out"]:
        if re.search(r"(?:const\s+)?(?:std::string|auto)(?:\s*&|\s+const\s*&|\s+)?\s+" + re.escape(name) + r"\b", before) or re.search(r"\b" + re.escape(name) + r"\s*=", before):
            return name
    decls = list(re.finditer(r"(?:const\s+)?(?:std::string|auto)(?:\s*&|\s+const\s*&|\s+)?\s+([A-Za-z_]\w*)\b", before))
    return decls[-1].group(1) if decls else "xml"


def line_start_at(text: str, pos: int) -> int:
    return text.rfind("\n", 0, pos) + 1


def replace_var_in_following_lines(text: str, start_pos: int, var: str, new_var: str, max_lines: int = 50) -> str:
    # Replace the original XML variable in the local send/log area after the inserted line.
    end = start_pos
    for _ in range(max_lines):
        n = text.find("\n", end + 1)
        if n < 0:
            end = len(text)
            break
        end = n
    segment = text[start_pos:end]
    lines = segment.splitlines(keepends=True)
    out_lines: list[str] = []
    for line in lines:
        if "JNN_FORCE_JINGLE_VP8_APPLIED" in line:
            out_lines.append(line)
            continue
        # Stop being aggressive after the first clear end of a function/block that follows the send area.
        # Still keep the line unchanged.
        if re.match(r"^\s*}\s*(?:else\b|catch\b)?", line):
            out_lines.append(line)
            # Continue unchanged for the rest of captured segment.
            out_lines.extend(lines[len(out_lines):])
            return text[:start_pos] + "".join(out_lines) + text[end:]
        # Replace standalone variable name. This should hit log/send lines like: ... + xml, send(xml), xml.c_str().
        out_lines.append(re.sub(r"\b" + re.escape(var) + r"\b", new_var, line))
    return text[:start_pos] + "".join(out_lines) + text[end:]


def apply_v3() -> None:
    if not SRC.exists():
        die("Run this from project root, e.g. D:\\MEDIA\\Desktop\\jitsi-ndi-native")

    cleanup_everywhere()

    p = find_jitsi_signaling()
    if not p:
        die("Could not find src/JitsiSignaling.cpp or another file with session-accept XML")

    t = read(p)
    original = t

    # Normalize helper/call state.
    t, removed = remove_bad_v2_call(t)
    t = re.sub(r"^[ \t]*std::string\s+jnnVp8SessionAcceptXml\s*=.*?//\s*JNN_FORCE_JINGLE_VP8_APPLIED\s*\r?\n", "", t, flags=re.M)
    t = strip_helper_regions(t)
    t = add_include_once(t, "<utility>")
    t = add_include_once(t, "<string>")
    t = insert_after_includes(t, JINGLE_HELPER)

    log_pos = find_session_accept_log(t)
    if log_pos < 0:
        if t != original:
            backup(p)
            write(p, t)
        die("Could not find real 'session-accept XML' log line inside code. Send me lines 600-640 of JitsiSignaling.cpp.")

    var = detect_xml_var(t, log_pos)
    new_var = "jnnVp8SessionAcceptXml"
    insert_at = line_start_at(t, log_pos)
    indent = re.match(r"[ \t]*", t[insert_at:]).group(0)
    insert_line = f"{indent}std::string {new_var} = jnnForceJingleSessionAcceptVp8Only({var}); // JNN_FORCE_JINGLE_VP8_APPLIED\n"
    t = t[:insert_at] + insert_line + t[insert_at:]

    # After insertion, rewrite the immediate log/send area to use the mutable filtered copy.
    after_insert = insert_at + len(insert_line)
    t = replace_var_in_following_lines(t, after_insert, var, new_var, max_lines=50)

    if t != original:
        backup(p)
        write(p, t)
        info(f"patched {p.relative_to(ROOT)}")
        info(f"backup folder: {BACKUP}")
        info("done. Rebuild with: cmake --build build --config Release")
    else:
        warn("No changes were made; file may already be patched.")


if __name__ == "__main__":
    apply_v3()
