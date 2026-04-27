#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Fix/redo VP8-only negotiation patch for jitsi-ndi-native.

This v2 script fixes the broken v1 insertion that could leave a bare line like
    xml = jnnForceJingleSessionAcceptVp8Only(std::move(xml));
at file scope in JitsiSignaling.cpp.

Run from project root:
  cd D:\\MEDIA\\Desktop\\jitsi-ndi-native
  python .\\vp8_hotfix_v2\\jitsi_ndi_native_force_vp8_hotfix_v2\\fix_force_vp8_v2.py
"""
from __future__ import annotations

import datetime
import re
import shutil
import sys
from pathlib import Path

ROOT = Path.cwd()
SRC = ROOT / "src"
BACKUP = ROOT / ("force_vp8_hotfix_v2_backup_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))


def info(msg: str) -> None:
    print(f"[FORCE_VP8_V2] {msg}")


def warn(msg: str) -> None:
    print(f"[FORCE_VP8_V2] WARN: {msg}")


def die(msg: str) -> None:
    print(f"[FORCE_VP8_V2] ERROR: {msg}")
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
    return text[:pos] + "\n\n" + block.strip() + "\n" + text[pos:]


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

            if (drop) continue;
        }
        out += line + "\r\n";
    }
    return out;
}
// JNN_FORCE_VP8_HOTFIX_END
'''


JINGLE_HELPER = r'''
// JNN_FORCE_JINGLE_VP8_HOTFIX_BEGIN
// Filters outgoing Jingle session-accept so video advertises VP8 only.
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


def src_files() -> list[Path]:
    return list(SRC.rglob("*.cpp")) + list(SRC.rglob("*.h")) + list(SRC.rglob("*.hpp"))


def find_file_containing(needles: list[str]) -> Path | None:
    for p in src_files():
        t = read(p)
        if all(n in t for n in needles):
            return p
    return None


def remove_broken_jingle_call_everywhere() -> int:
    changed = 0
    bad_line_re = re.compile(r"^[ \t]*\w+\s*=\s*jnnForceJingleSessionAcceptVp8Only\s*\(\s*std::move\s*\(\s*\w+\s*\)\s*\)\s*;\s*//\s*JNN_FORCE_JINGLE_VP8_APPLIED\s*\r?\n", re.M)
    for p in src_files():
        t = read(p)
        t2, n = bad_line_re.subn("", t)
        if n:
            backup(p)
            write(p, t2)
            changed += n
            info(f"removed broken old Jingle VP8 call(s) from {p.relative_to(ROOT)}: {n}")
    return changed


def patch_native_sdp() -> bool:
    p = find_file_containing(["local SDP description generated"])
    if not p:
        warn("NativeWebRTCAnswerer source not found by log string; skipping SDP filter.")
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
            warn(f"SDP helper present in {p.relative_to(ROOT)}, but automatic call-site patch was not found.")
        else:
            info(f"patched {p.relative_to(ROOT)}: local SDP answer is VP8-only for video")

    if t != original:
        backup(p)
        write(p, t)
    return "JNN_FORCE_VP8_APPLIED" in t


def looks_like_inside_function(text: str, pos: int) -> bool:
    # Rough sanity check: more opening braces than closing braces before pos.
    prefix = text[:pos]
    return prefix.count('{') > prefix.count('}')


def find_actual_session_accept_log(text: str) -> int:
    # Prefer the real log string with colon. Avoid helper comments.
    candidates = []
    for needle in ["session-accept XML:", "JingleSession: session-accept XML", "session-accept XML"]:
        start = 0
        while True:
            pos = text.find(needle, start)
            if pos == -1:
                break
            if "JNN_FORCE_JINGLE_VP8_HOTFIX_BEGIN" in text[max(0, pos-300):pos+300]:
                start = pos + 1
                continue
            if looks_like_inside_function(text, pos):
                candidates.append(pos)
            start = pos + 1
        if candidates:
            return candidates[0]
    return -1


def detect_xml_variable_near(text: str, log_pos: int) -> str | None:
    window_start = max(0, log_pos - 6000)
    window_end = min(len(text), log_pos + 1200)
    window = text[window_start:window_end]

    # 1) Explicit preferred variable names used in this project/codegen style.
    preferred = [
        "xml", "sessionAcceptXml", "acceptXml", "jingleXml", "iqXml",
        "session_accept_xml", "sessionAccept", "accept", "out", "result"
    ]
    for name in preferred:
        # Must appear as declaration or assignment before the log point.
        before = text[window_start:log_pos]
        if re.search(r"(?:std::string|auto)\s+" + re.escape(name) + r"\b", before) or re.search(r"\b" + re.escape(name) + r"\s*=", before):
            return name

    # 2) Look for latest std::string variable initialized with something containing jingle/session-accept/xml/iq.
    before = text[window_start:log_pos]
    decls = list(re.finditer(r"(?:std::string|auto)\s+([A-Za-z_]\w*)\s*=\s*([^;]{0,800});", before, re.S))
    for m in reversed(decls):
        rhs = m.group(2)
        if any(x in rhs for x in ["<iq", "<jingle", "session-accept", "jingle", "xml"]):
            return m.group(1)

    # 3) Try variables printed on the log line / nearby lines: + var, << var, var.c_str().
    near = text[log_pos:min(len(text), log_pos + 600)]
    for m in re.finditer(r"(?:\+|<<|,)\s*([A-Za-z_]\w*)\s*(?:\.c_str\s*\(\s*\))?", near):
        var = m.group(1)
        if var not in {"std", "string", "INFO", "WARN", "ERROR"}:
            return var

    return None


def patch_jingle_xml() -> bool:
    p = find_file_containing(["session-accept XML"])
    if not p:
        # Fallback: source that already contains the helper after a previous failed run.
        p = find_file_containing(["JNN_FORCE_JINGLE_VP8_HOTFIX_BEGIN"])
    if not p:
        warn("Jingle/session-accept source not found; skipping Jingle XML filter.")
        return False

    t = read(p)
    original = t

    if "JNN_FORCE_JINGLE_VP8_HOTFIX_BEGIN" not in t:
        t = add_include_once(t, "<utility>")
        t = add_include_once(t, "<string>")
        t = insert_after_includes(t, JINGLE_HELPER)

    # Recompute after helper insertion.
    if "JNN_FORCE_JINGLE_VP8_APPLIED" not in t:
        log_pos = find_actual_session_accept_log(t)
        if log_pos < 0:
            warn(f"Could not find the real session-accept XML log inside a function in {p.relative_to(ROOT)}.")
        else:
            var = detect_xml_variable_near(t, log_pos)
            if var:
                line_start = t.rfind("\n", 0, log_pos) + 1
                indent = re.match(r"[ \t]*", t[line_start:]).group(0)
                insertion = f"{indent}{var} = jnnForceJingleSessionAcceptVp8Only(std::move({var})); // JNN_FORCE_JINGLE_VP8_APPLIED\n"
                t = t[:line_start] + insertion + t[line_start:]
                info(f"patched {p.relative_to(ROOT)}: outgoing Jingle session-accept XML is VP8-only for video")
            else:
                warn(f"Could not detect XML variable near session-accept log in {p.relative_to(ROOT)}.")
                warn("Manual call needed immediately before logging/sending session-accept XML:")
                warn("    <xmlVar> = jnnForceJingleSessionAcceptVp8Only(std::move(<xmlVar>));")

    if t != original:
        backup(p)
        write(p, t)
    return "JNN_FORCE_JINGLE_VP8_APPLIED" in t


def main() -> None:
    if not SRC.exists():
        die("Run this from project root, e.g. D:\\MEDIA\\Desktop\\jitsi-ndi-native")

    remove_broken_jingle_call_everywhere()
    ok_sdp = patch_native_sdp()
    ok_jingle = patch_jingle_xml()

    info(f"backup folder: {BACKUP}")
    if ok_sdp or ok_jingle:
        info("done. Rebuild with: cmake --build build --config Release")
        if not ok_jingle:
            warn("Jingle XML filter was not definitely applied. Build may succeed, but AV1 may still be advertised.")
    else:
        warn("Build-breaking line was removed if present, but no VP8 call site was patched automatically.")
        sys.exit(2)


if __name__ == "__main__":
    main()
