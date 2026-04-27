#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Force the native Jitsi receiver to negotiate VP8 instead of AV1.

Run from project root:
  cd D:\\MEDIA\\Desktop\\jitsi-ndi-native
  python .\\vp8_hotfix\\jitsi_ndi_native_force_vp8_hotfix\\fix_force_vp8.py
"""
from __future__ import annotations

import datetime
import re
import shutil
import sys
from pathlib import Path

ROOT = Path.cwd()
SRC = ROOT / "src"
BACKUP = ROOT / ("force_vp8_hotfix_backup_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))


def info(msg: str) -> None:
    print(f"[FORCE_VP8_HOTFIX] {msg}")


def warn(msg: str) -> None:
    print(f"[FORCE_VP8_HOTFIX] WARN: {msg}")


def die(msg: str) -> None:
    print(f"[FORCE_VP8_HOTFIX] ERROR: {msg}")
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
        return block + "\n" + text
    pos = includes[-1].end()
    return text[:pos] + "\n\n" + block + "\n" + text[pos:]


SDP_HELPER = r'''
// JNN_FORCE_VP8_HOTFIX_BEGIN
// Temporary compatibility fix: do not negotiate AV1 until the native AV1 RTP
// depacketizer handles Jitsi AV1 aggregation/OBU framing correctly.
static std::string jnnForceSdpVideoVp8Only(const std::string& inputSdp) {
    std::vector<std::string> lines;
    std::string cur;
    for (char ch : inputSdp) {
        if (ch == '\n') {
            if (!cur.empty() && cur.back() == '\r') cur.pop_back();
            lines.push_back(cur);
            cur.clear();
        } else {
            cur.push_back(ch);
        }
    }
    if (!cur.empty()) {
        if (!cur.empty() && cur.back() == '\r') cur.pop_back();
        lines.push_back(cur);
    }

    std::string vp8Pt;
    bool inVideo = false;
    for (const auto& line : lines) {
        if (line.rfind("m=", 0) == 0) {
            inVideo = (line.rfind("m=video", 0) == 0);
        }
        if (!inVideo) continue;
        if (line.rfind("a=rtpmap:", 0) == 0 && line.find(" VP8/90000") != std::string::npos) {
            const size_t start = std::string("a=rtpmap:").size();
            const size_t space = line.find(' ', start);
            if (space != std::string::npos && space > start) {
                vp8Pt = line.substr(start, space - start);
            }
        }
    }

    if (vp8Pt.empty()) {
        return inputSdp;
    }

    std::string out;
    inVideo = false;
    for (const auto& line : lines) {
        if (line.rfind("m=", 0) == 0) {
            inVideo = (line.rfind("m=video", 0) == 0);
            if (inVideo) {
                // m=video <port> <proto> <payload-types...>
                size_t p1 = line.find(' ');
                size_t p2 = (p1 == std::string::npos) ? std::string::npos : line.find(' ', p1 + 1);
                size_t p3 = (p2 == std::string::npos) ? std::string::npos : line.find(' ', p2 + 1);
                if (p3 != std::string::npos) {
                    out += line.substr(0, p3 + 1) + vp8Pt + "\r\n";
                    continue;
                }
            }
        }

        if (inVideo) {
            bool drop = false;
            const char* dropCodecs[] = {" AV1/90000", " H264/90000", " VP9/90000"};
            for (const char* codec : dropCodecs) {
                if (line.rfind("a=rtpmap:", 0) == 0 && line.find(codec) != std::string::npos) {
                    drop = true;
                }
            }

            if (!drop && (line.rfind("a=fmtp:", 0) == 0 || line.rfind("a=rtcp-fb:", 0) == 0)) {
                const size_t colon = line.find(':');
                const size_t space = line.find(' ', colon == std::string::npos ? 0 : colon + 1);
                const std::string pt = (colon != std::string::npos)
                    ? line.substr(colon + 1, (space == std::string::npos ? line.size() : space) - colon - 1)
                    : std::string();
                if (!pt.empty() && pt != vp8Pt) {
                    drop = true;
                }
            }

            if (!drop && line.rfind("a=extmap:", 0) == 0) {
                if (line.find("dependency-descriptor") != std::string::npos ||
                    line.find("video-layers-allocation") != std::string::npos) {
                    drop = true;
                }
            }

            if (drop) {
                continue;
            }
        }
        out += line + "\r\n";
    }
    return out;
}
// JNN_FORCE_VP8_HOTFIX_END
'''


JINGLE_HELPER = r'''
// JNN_FORCE_JINGLE_VP8_HOTFIX_BEGIN
// Filters outgoing Jingle session-accept XML so the video content advertises VP8 only.
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
    xml = jnnErasePayloadTypeByCodecName(std::move(xml), "AV1");
    xml = jnnErasePayloadTypeByCodecName(std::move(xml), "H264");
    xml = jnnErasePayloadTypeByCodecName(std::move(xml), "VP9");
    xml = jnnEraseHeaderExtensionByText(std::move(xml), "dependency-descriptor");
    xml = jnnEraseHeaderExtensionByText(std::move(xml), "video-layers-allocation");
    return xml;
}
// JNN_FORCE_JINGLE_VP8_HOTFIX_END
'''


def find_file_containing(needles: list[str], suffixes=("*.cpp", "*.h")) -> Path | None:
    for suffix in suffixes:
        for p in SRC.rglob(suffix):
            t = read(p)
            if all(n in t for n in needles):
                return p
    return None


def patch_native_sdp() -> bool:
    p = find_file_containing(["local SDP description generated"])
    if not p:
        warn("Could not find NativeWebRTCAnswerer source by log string 'local SDP description generated'.")
        return False

    t = read(p)
    original = t
    if "JNN_FORCE_VP8_HOTFIX_BEGIN" not in t:
        t = add_include_once(t, "<sstream>")
        t = add_include_once(t, "<utility>")
        t = add_include_once(t, "<vector>")
        t = add_include_once(t, "<string>")
        t = insert_after_includes(t, SDP_HELPER)

    if "JNN_FORCE_VP8_APPLIED" not in t:
        patterns = [
            r"(?P<indent>^[ \t]*)(?P<decl>std::string\s+(?P<var>[A-Za-z_]\w*)\s*=\s*std::string\s*\(\s*(?:description|desc|localDescription|local_description)\s*\)\s*;)",
            r"(?P<indent>^[ \t]*)(?P<decl>auto\s+(?P<var>[A-Za-z_]\w*)\s*=\s*std::string\s*\(\s*(?:description|desc|localDescription|local_description)\s*\)\s*;)",
        ]
        patched = False
        for pat in patterns:
            def repl(m: re.Match) -> str:
                nonlocal patched
                patched = True
                indent = m.group('indent')
                var = m.group('var')
                return f"{indent}{m.group('decl')}\n{indent}{var} = jnnForceSdpVideoVp8Only({var}); // JNN_FORCE_VP8_APPLIED"
            t2, n = re.subn(pat, repl, t, count=1, flags=re.M)
            if n:
                t = t2
                break

        if not patched:
            member_pat = r"(?P<lhs>\b(?:answerSdp_|answer_sdp_|localAnswerSdp_|local_answer_sdp_)\s*=\s*)(?P<rhs>[^;\n]+);"
            def repl_member(m: re.Match) -> str:
                nonlocal patched
                patched = True
                return f"{m.group('lhs')}jnnForceSdpVideoVp8Only({m.group('rhs')}); // JNN_FORCE_VP8_APPLIED"
            t2, n = re.subn(member_pat, repl_member, t, count=1)
            if n:
                t = t2

        if not patched:
            warn(f"Inserted SDP helper into {p.relative_to(ROOT)}, but could not find the SDP variable to filter automatically.")
            warn("Manual patch needed: before storing/sending the local answer SDP, call: sdp = jnnForceSdpVideoVp8Only(sdp);")
        else:
            info(f"patched {p.relative_to(ROOT)}: local answer SDP will be filtered to VP8-only video")

    if t != original:
        backup(p)
        write(p, t)
    return "JNN_FORCE_VP8_APPLIED" in t


def detect_xml_variable_around_log(text: str, log_pos: int) -> str | None:
    common = ["xml", "sessionAcceptXml", "acceptXml", "jingleXml", "iqXml", "out", "result", "sessionAccept"]
    window = text[max(0, log_pos - 4000):log_pos + 800]
    for name in common:
        if re.search(r"\b" + re.escape(name) + r"\b", window):
            if re.search(r"(?:std::string|auto)\s+" + re.escape(name) + r"\b", window) or re.search(r"\b" + re.escape(name) + r"\s*=", window):
                return name
    return None


def patch_jingle_xml() -> bool:
    p = find_file_containing(["session-accept XML"])
    if not p:
        warn("Could not find JingleSession source by log string 'session-accept XML'.")
        return False

    t = read(p)
    original = t
    if "JNN_FORCE_JINGLE_VP8_HOTFIX_BEGIN" not in t:
        t = add_include_once(t, "<utility>")
        t = add_include_once(t, "<string>")
        t = insert_after_includes(t, JINGLE_HELPER)

    if "JNN_FORCE_JINGLE_VP8_APPLIED" not in t:
        log_pos = t.find("session-accept XML")
        var = detect_xml_variable_around_log(t, log_pos)
        if var:
            line_start = t.rfind("\n", 0, log_pos) + 1
            indent = re.match(r"[ \t]*", t[line_start:]).group(0)
            insertion = f"{indent}{var} = jnnForceJingleSessionAcceptVp8Only(std::move({var})); // JNN_FORCE_JINGLE_VP8_APPLIED\n"
            t = t[:line_start] + insertion + t[line_start:]
            info(f"patched {p.relative_to(ROOT)}: outgoing session-accept XML will advertise VP8-only video")
        else:
            warn(f"Inserted Jingle XML helper into {p.relative_to(ROOT)}, but could not detect XML variable near the log line.")
            warn("Manual patch needed: immediately before logging/sending session-accept XML, call:")
            warn("    xml = jnnForceJingleSessionAcceptVp8Only(std::move(xml));")

    if t != original:
        backup(p)
        write(p, t)
    return "JNN_FORCE_JINGLE_VP8_APPLIED" in t


def main() -> None:
    if not SRC.exists():
        die("Run from project root, e.g. D:\\MEDIA\\Desktop\\jitsi-ndi-native")

    ok1 = patch_native_sdp()
    ok2 = patch_jingle_xml()

    info(f"backup folder: {BACKUP}")
    if ok1 or ok2:
        info("done. Rebuild with: cmake --build build --config Release")
        info("Then check the new session-accept XML: video payload-types should no longer contain AV1/41.")
    else:
        warn("No automatic call sites were patched. The helper functions may have been inserted, but manual placement is required.")
        sys.exit(2)


if __name__ == "__main__":
    main()
