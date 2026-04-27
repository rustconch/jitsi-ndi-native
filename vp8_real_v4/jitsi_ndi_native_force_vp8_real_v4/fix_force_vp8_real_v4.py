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
BACKUP = ROOT / ("force_vp8_real_v4_backup_" + datetime.datetime.now().strftime("%Y%m%d_%H%M%S"))


def info(msg: str) -> None:
    print(f"[FORCE_VP8_REAL_V4] {msg}")


def warn(msg: str) -> None:
    print(f"[FORCE_VP8_REAL_V4] WARN: {msg}")


def die(msg: str) -> None:
    print(f"[FORCE_VP8_REAL_V4] ERROR: {msg}")
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


def strip_region(text: str, begin: str, end: str) -> str:
    return re.sub(r"\n?// " + re.escape(begin) + r".*?// " + re.escape(end) + r"\n?", "\n", text, flags=re.S)


def cleanup_old_force_lines() -> None:
    old_call_res = [
        re.compile(r"^[ \t]*(?:[A-Za-z_]\w*)\s*=\s*jnnForceJingleSessionAcceptVp8Only\s*\([^\n;]*\)\s*;\s*//\s*JNN_FORCE_JINGLE_VP8_APPLIED\s*\r?\n", re.M),
        re.compile(r"^[ \t]*(?:[A-Za-z_]\w*)\s*=\s*jnnForceSdpVideoVp8Only\s*\([^\n;]*\)\s*;\s*//\s*JNN_FORCE_VP8_APPLIED\s*\r?\n", re.M),
        re.compile(r"^[ \t]*std::string\s+jnnVp8SessionAcceptXml\s*=\s*jnnForceJingleSessionAcceptVp8Only\s*\([^\n;]*\)\s*;\s*//\s*JNN_FORCE_JINGLE_VP8_APPLIED\s*\r?\n", re.M),
    ]
    for p in src_files():
        t = read(p)
        t2 = t
        for rx in old_call_res:
            t2 = rx.sub("", t2)
        if t2 != t:
            backup(p)
            write(p, t2)
            info(f"removed old partial force-VP8 call(s) from {p.relative_to(ROOT)}")


SDP_HELPER = r'''
// JNN_FORCE_VP8_REAL_V4_BEGIN
static std::vector<std::string> jnnSplitSdpLines(const std::string& inputSdp) {
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
    return lines;
}

static bool jnnSdpLinePayloadTypeIs(const std::string& line, const std::string& pt) {
    const size_t colon = line.find(':');
    if (colon == std::string::npos) return false;
    const size_t start = colon + 1;
    const size_t end = line.find_first_of(" \t", start);
    const std::string found = line.substr(start, end == std::string::npos ? std::string::npos : end - start);
    return found == pt;
}

static std::string jnnForceSdpVideoVp8Only(const std::string& inputSdp) {
    const auto lines = jnnSplitSdpLines(inputSdp);

    std::string vp8Pt;
    bool inVideo = false;
    for (const auto& line : lines) {
        if (line.rfind("m=", 0) == 0) inVideo = (line.rfind("m=video", 0) == 0);
        if (!inVideo) continue;
        if (line.rfind("a=rtpmap:", 0) == 0 && line.find(" VP8/90000") != std::string::npos) {
            const size_t start = std::string("a=rtpmap:").size();
            const size_t space = line.find_first_of(" \t", start);
            if (space != std::string::npos && space > start) {
                vp8Pt = line.substr(start, space - start);
                break;
            }
        }
    }

    if (vp8Pt.empty()) return inputSdp;

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
            if (line.rfind("a=rtpmap:", 0) == 0 && !jnnSdpLinePayloadTypeIs(line, vp8Pt)) drop = true;
            if (!drop && line.rfind("a=fmtp:", 0) == 0 && !jnnSdpLinePayloadTypeIs(line, vp8Pt)) drop = true;
            if (!drop && line.rfind("a=rtcp-fb:", 0) == 0 && !jnnSdpLinePayloadTypeIs(line, vp8Pt)) drop = true;
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
// JNN_FORCE_VP8_REAL_V4_END
'''

JINGLE_HELPER = r'''
// JNN_FORCE_JINGLE_VP8_REAL_V4_BEGIN
static std::string jnnEraseXmlElementAround(std::string xml, size_t pos, const std::string& elementName) {
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

static std::string jnnErasePayloadTypeByCodecNameV4(std::string xml, const std::string& codecName) {
    for (;;) {
        size_t pos = xml.find("name='" + codecName + "'");
        if (pos == std::string::npos) pos = xml.find("name=\"" + codecName + "\"");
        if (pos == std::string::npos) break;
        xml = jnnEraseXmlElementAround(std::move(xml), pos, "payload-type");
    }
    return xml;
}

static std::string jnnEraseRtpHeaderExtensionByTextV4(std::string xml, const std::string& needle) {
    for (;;) {
        size_t pos = xml.find(needle);
        if (pos == std::string::npos) break;
        xml = jnnEraseXmlElementAround(std::move(xml), pos, "rtp-hdrext");
    }
    return xml;
}

static std::string jnnForceJingleSessionAcceptVp8OnlyV4(std::string xml) {
    if (xml.find("session-accept") == std::string::npos) return xml;
    xml = jnnErasePayloadTypeByCodecNameV4(std::move(xml), "AV1");
    xml = jnnErasePayloadTypeByCodecNameV4(std::move(xml), "H264");
    xml = jnnErasePayloadTypeByCodecNameV4(std::move(xml), "VP9");
    xml = jnnEraseRtpHeaderExtensionByTextV4(std::move(xml), "dependency-descriptor");
    xml = jnnEraseRtpHeaderExtensionByTextV4(std::move(xml), "video-layers-allocation");
    return xml;
}
// JNN_FORCE_JINGLE_VP8_REAL_V4_END
'''


def find_native_answerer() -> Path | None:
    direct = SRC / "NativeWebRTCAnswerer.cpp"
    if direct.exists():
        return direct
    for p in src_files():
        t = read(p)
        if "setting remote Jitsi SDP-like offer" in t or "local SDP description generated" in t:
            return p
    return None


def find_jitsi_signaling() -> Path | None:
    direct = SRC / "JitsiSignaling.cpp"
    if direct.exists():
        return direct
    for p in src_files():
        t = read(p)
        if "session-accept XML" in t:
            return p
    return None


def line_start_at(text: str, pos: int) -> int:
    return text.rfind("\n", 0, pos) + 1


def detect_sdp_var_before(text: str, pos: int) -> str | None:
    before_start = max(0, pos - 10000)
    before = text[before_start:pos]
    preferred = ["offerSdp", "remoteSdp", "jitsiSdp", "sdp", "sdpOffer", "remoteOfferSdp", "sdpText"]
    for name in preferred:
        if re.search(r"(?:const\s+)?(?:std::string|auto)\s+" + re.escape(name) + r"\b", before) or re.search(r"\b" + re.escape(name) + r"\s*=", before):
            return name
    candidates: list[tuple[int, str]] = []
    for m in re.finditer(r"(?:const\s+)?(?:std::string|auto)\s+([A-Za-z_]\w*[sS][dD][pP][A-Za-z_]\w*)\b\s*(?:=|\{)", before):
        candidates.append((m.start(), m.group(1)))
    for m in re.finditer(r"\b([A-Za-z_]\w*[sS][dD][pP][A-Za-z_]\w*)\s*=", before):
        candidates.append((m.start(), m.group(1)))
    if candidates:
        candidates.sort()
        return candidates[-1][1]
    return None


def make_var_mutable_near(text: str, var: str, pos: int) -> str:
    start = max(0, pos - 12000)
    window = text[start:pos]
    pattern = re.compile(r"const\s+std::string\s+" + re.escape(var) + r"\s*=")
    matches = list(pattern.finditer(window))
    if not matches:
        return text
    m = matches[-1]
    return text[:start + m.start()] + "std::string " + var + " =" + text[start + m.end():]


def patch_remote_sdp() -> bool:
    p = find_native_answerer()
    if not p:
        warn("NativeWebRTCAnswerer.cpp not found; cannot patch remote SDP")
        return False
    t = read(p)
    original = t
    t = strip_region(t, "JNN_FORCE_VP8_HOTFIX_BEGIN", "JNN_FORCE_VP8_HOTFIX_END")
    t = strip_region(t, "JNN_FORCE_VP8_REAL_V4_BEGIN", "JNN_FORCE_VP8_REAL_V4_END")
    t = add_include_once(t, "<string>")
    t = add_include_once(t, "<vector>")
    t = insert_after_includes(t, SDP_HELPER)
    if "JNN_FORCE_REMOTE_OFFER_VP8_REAL_V4_APPLIED" not in t:
        log_pos = t.find("setting remote Jitsi SDP-like offer")
        if log_pos < 0:
            log_pos = t.find("setRemoteDescription")
        if log_pos >= 0:
            var = detect_sdp_var_before(t, log_pos)
            if var:
                t = make_var_mutable_near(t, var, log_pos)
                insert_at = line_start_at(t, log_pos)
                indent = re.match(r"[ \t]*", t[insert_at:]).group(0)
                t = t[:insert_at] + f"{indent}{var} = jnnForceSdpVideoVp8Only({var}); // JNN_FORCE_REMOTE_OFFER_VP8_REAL_V4_APPLIED\n" + t[insert_at:]
                info(f"patched {p.relative_to(ROOT)}: remote offer SDP is filtered to VP8-only before setRemoteDescription")
            else:
                pat = re.compile(r"rtc::Description\s+([A-Za-z_]\w*)\s*\(\s*([^,;\n]+)\s*,\s*\"offer\"\s*\)\s*;")
                def repl(m: re.Match) -> str:
                    expr = m.group(2).strip()
                    return f"rtc::Description {m.group(1)}(jnnForceSdpVideoVp8Only({expr}), \"offer\"); // JNN_FORCE_REMOTE_OFFER_VP8_REAL_V4_APPLIED"
                t, n = pat.subn(repl, t, count=1)
                if n:
                    info(f"patched {p.relative_to(ROOT)}: wrapped rtc::Description offer construction with VP8-only SDP filter")
                else:
                    warn(f"Could not detect SDP variable in {p.relative_to(ROOT)}")
        else:
            warn(f"Could not find remote-offer point in {p.relative_to(ROOT)}")
    if t != original:
        backup(p)
        write(p, t)
    return "JNN_FORCE_REMOTE_OFFER_VP8_REAL_V4_APPLIED" in t


def find_session_accept_log_pos(text: str) -> int:
    for needle in ["JingleSession: session-accept XML", "session-accept XML:", "session-accept XML"]:
        start = 0
        while True:
            pos = text.find(needle, start)
            if pos < 0:
                break
            near = text[max(0, pos - 400):pos + 400]
            if "JNN_FORCE_JINGLE" not in near:
                return pos
            start = pos + 1
    return -1


def detect_xml_var_before(text: str, pos: int) -> str | None:
    before_start = max(0, pos - 10000)
    before = text[before_start:pos]
    preferred = ["xml", "sessionAcceptXml", "acceptXml", "jingleXml", "iqXml", "session_accept_xml", "out", "result"]
    for name in preferred:
        if re.search(r"(?:const\s+)?(?:std::string|auto)\s+" + re.escape(name) + r"\b", before) or re.search(r"\b" + re.escape(name) + r"\s*=", before):
            return name
    decls = list(re.finditer(r"(?:const\s+)?std::string\s+([A-Za-z_]\w*)\s*=\s*([^;]{0,1200}(?:session-accept|<iq|<jingle|jingle)[^;]{0,1200});", before, re.S))
    if decls:
        return decls[-1].group(1)
    near = text[pos:min(len(text), pos + 800)]
    for m in re.finditer(r"(?:\+|<<|,)\s*([A-Za-z_]\w*)\s*(?:\.c_str\s*\(\s*\))?", near):
        var = m.group(1)
        if var not in {"std", "string", "INFO", "WARN", "ERROR", "Logger"}:
            return var
    return None


def patch_jingle_xml() -> bool:
    p = find_jitsi_signaling()
    if not p:
        warn("JitsiSignaling.cpp not found; cannot patch session-accept XML")
        return False
    t = read(p)
    original = t
    t = strip_region(t, "JNN_FORCE_JINGLE_VP8_HOTFIX_BEGIN", "JNN_FORCE_JINGLE_VP8_HOTFIX_END")
    t = strip_region(t, "JNN_FORCE_JINGLE_VP8_REAL_V4_BEGIN", "JNN_FORCE_JINGLE_VP8_REAL_V4_END")
    t = add_include_once(t, "<string>")
    t = add_include_once(t, "<utility>")
    t = insert_after_includes(t, JINGLE_HELPER)
    if "JNN_FORCE_JINGLE_VP8_REAL_V4_APPLIED" not in t:
        log_pos = find_session_accept_log_pos(t)
        if log_pos >= 0:
            var = detect_xml_var_before(t, log_pos)
            if var:
                t = make_var_mutable_near(t, var, log_pos)
                insert_at = line_start_at(t, log_pos)
                indent = re.match(r"[ \t]*", t[insert_at:]).group(0)
                t = t[:insert_at] + f"{indent}{var} = jnnForceJingleSessionAcceptVp8OnlyV4({var}); // JNN_FORCE_JINGLE_VP8_REAL_V4_APPLIED\n" + t[insert_at:]
                info(f"patched {p.relative_to(ROOT)}: outgoing Jingle session-accept XML is filtered to VP8-only")
            else:
                warn(f"Could not detect XML variable near session-accept log in {p.relative_to(ROOT)}")
        else:
            warn(f"Could not find session-accept XML log in {p.relative_to(ROOT)}")
    if t != original:
        backup(p)
        write(p, t)
    return "JNN_FORCE_JINGLE_VP8_REAL_V4_APPLIED" in t


def main() -> None:
    if not SRC.exists():
        die("Run this from project root, e.g. D:\\MEDIA\\Desktop\\jitsi-ndi-native")
    cleanup_old_force_lines()
    ok_sdp = patch_remote_sdp()
    ok_jingle = patch_jingle_xml()
    info(f"backup folder: {BACKUP}")
    if ok_sdp:
        info("remote SDP filter applied: Jitsi should stop sending AV1 video RTP after rebuild")
    else:
        warn("remote SDP filter was not definitely applied")
    if ok_jingle:
        info("Jingle session-accept XML filter applied: the log should no longer show AV1/H264/VP9 in session-accept")
    else:
        warn("Jingle XML filter was not definitely applied")
    if ok_sdp or ok_jingle:
        info("done. Rebuild with: cmake --build build --config Release")
    else:
        die("No VP8 call site was patched automatically. Send lines around 'setting remote Jitsi SDP-like offer' and 'session-accept XML'.")


if __name__ == "__main__":
    main()
