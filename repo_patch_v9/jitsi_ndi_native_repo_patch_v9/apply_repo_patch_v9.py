from __future__ import annotations

import re
import shutil
from pathlib import Path

ROOT = Path.cwd()
SRC = ROOT / "src"

PATCH_TAG = "PATCH_V9_AV1_RESTORE_AUDIO_UNBLOCK"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="")


def backup(path: Path) -> None:
    bak = path.with_suffix(path.suffix + ".bak_v9")
    if not bak.exists():
        shutil.copy2(path, bak)


def replace_regex(path: Path, pattern: str, repl: str, desc: str, flags: int = re.S) -> bool:
    text = read(path)
    new, n = re.subn(pattern, repl, text, count=1, flags=flags)
    if n == 0:
        print(f"[WARN] not patched: {path.name}: {desc}")
        return False
    if new != text:
        backup(path)
        write(path, new)
        print(f"[OK] {path.name}: {desc}")
    else:
        print(f"[OK] {path.name}: already effectively patched: {desc}")
    return True


def replace_literal(path: Path, old: str, new: str, desc: str) -> bool:
    text = read(path)
    if old not in text:
        print(f"[WARN] not found: {path.name}: {desc}")
        return False
    text2 = text.replace(old, new, 1)
    if text2 != text:
        backup(path)
        write(path, text2)
        print(f"[OK] {path.name}: {desc}")
    return True


def patch_jitsi_signaling() -> None:
    path = SRC / "JitsiSignaling.cpp"
    if not path.exists():
        print(f"[WARN] missing {path}")
        return

    new_join_muc = r'''void JitsiSignaling::joinMuc() {
    Logger::info("Joining MUC room as: ", mucJid());

    std::ostringstream xml;
    xml
        << "<presence xmlns='jabber:client'"
        << " to='" << xmlEscape(mucJid()) << "'>";

    xml << "<x xmlns='http://jabber.org/protocol/muc'/>";

    xml
        << "<nick xmlns='http://jabber.org/protocol/nick'>"
        << xmlEscape(cfg_.nick)
        << "</nick>";

    xml
        << "<c xmlns='http://jabber.org/protocol/caps'"
        << " hash='sha-1'"
        << " node='https://github.com/jitsi-ndi-native'"
        << " ver='native'/>";

    // PATCH_V9_AV1_RESTORE_AUDIO_UNBLOCK:
    // JVB is an SFU and normally forwards the codec produced by the browser.
    // In current meet.jit.si rooms that is often AV1/PT=41, so advertise AV1 too.
    // Keep this XML well-formed; previous VP8-only patch left stray text after the tag.
    xml << "<jitsi_participant_codecList>av1,vp8,opus</jitsi_participant_codecList>";

    xml << "</presence>";
    sendRaw(xml.str());
}

void JitsiSignaling::sendIqResult'''

    replace_regex(
        path,
        r"void\s+JitsiSignaling::joinMuc\s*\(\s*\)\s*\{[\s\S]*?\n\}\s*\n\s*void\s+JitsiSignaling::sendIqResult",
        new_join_muc,
        "restore valid MUC presence and advertise av1,vp8,opus",
    )


def patch_jingle_session() -> None:
    path = SRC / "JingleSession.cpp"
    if not path.exists():
        print(f"[WARN] missing {path}")
        return

    new_func = r'''bool isSupportedVideoCodec(const JingleCodec& codec) {
    const std::string name = toLower(codec.name);

    // PATCH_V9_AV1_RESTORE_AUDIO_UNBLOCK:
    // The bridge forwards the sender's encoded stream; it does not transcode AV1 to VP8 for us.
    // Accept the two codecs we actually route/decode in this native pipeline.
    return name == "av1" || name == "vp8";
}

bool isSupportedCodecForContent'''

    replace_regex(
        path,
        r"bool\s+isSupportedVideoCodec\s*\(\s*const\s+JingleCodec&\s+codec\s*\)\s*\{[\s\S]*?\n\}\s*\n\s*bool\s+isSupportedCodecForContent",
        new_func,
        "accept AV1 + VP8 in Jingle session-accept",
    )

    # Remove stale comments that can mislead while reading logs/code.
    text = read(path)
    text2 = text.replace(
        "No H264 parameters here anymore because this native receiver currently\n    accepts only VP8 for video.",
        "No extra video fmtp parameters are emitted here; AV1 and VP8 are accepted as-is."
    )
    if text2 != text:
        backup(path)
        write(path, text2)
        print("[OK] JingleSession.cpp: updated stale VP8-only comment")


def patch_native_webrtc_answerer() -> None:
    path = SRC / "NativeWebRTCAnswerer.cpp"
    if not path.exists():
        print(f"[WARN] missing {path}")
        return

    # If a previous patch added a VP8-only SDP filter, make it a no-op.
    new_func = r'''std::string forceVp8OnlyVideoSdp(const std::string& sdp) {
    // PATCH_V9_AV1_RESTORE_AUDIO_UNBLOCK:
    // Do not strip AV1. JVB/SFU forwards sender codec and current rooms send PT=41/AV1.
    return sdp;
}'''
    ok = replace_regex(
        path,
        r"std::string\s+forceVp8OnlyVideoSdp\s*\(\s*const\s+std::string&\s+sdp\s*\)\s*\{[\s\S]*?\n\}",
        new_func,
        "make VP8-only SDP filter a no-op",
    )
    if not ok:
        # Fallback: if the function was inlined/renamed, at least neutralize obvious call sites.
        text = read(path)
        text2 = re.sub(r"(\w+)\s*=\s*forceVp8OnlyVideoSdp\s*\(\s*\1\s*\)\s*;", r"/* v9: keep AV1 in SDP */", text)
        if text2 != text:
            backup(path)
            write(path, text2)
            print("[OK] NativeWebRTCAnswerer.cpp: neutralized VP8-only SDP call site")


def patch_router() -> None:
    path = SRC / "PerParticipantNdiRouter.cpp"
    if not path.exists():
        print(f"[WARN] missing {path}")
        return

    new_video_block = r'''if (media == "video" || mid == "video") {
        ++p.videoPackets;

        if (p.videoPackets <= 3 || (p.videoPackets % 300) == 0) {
            Logger::info(
                "PerParticipantNdiRouter: video RTP endpoint=",
                p.endpointId,
                " pt=",
                static_cast<int>(rtp.payloadType),
                " marker=",
                static_cast<int>(rtp.marker),
                " payloadBytes=",
                rtp.payloadSize,
                " ssrc=",
                rtp.ssrc
            );
        }

        // PATCH_V9_AV1_RESTORE_AUDIO_UNBLOCK:
        // Current meet.jit.si sends AV1 as PT=41. Do not drop it; depacketize AV1 RTP
        // and feed FFmpeg/dav1d with complete AV1 temporal units.
        if (rtp.payloadType == 41) {
            ++routedVideoPackets_;
            const auto frames = p.av1.pushRtp(rtp);
            for (const auto& encoded : frames) {
                for (const auto& decoded : p.av1Decoder.decode(encoded)) {
                    p.ndi->sendVideoFrame(decoded, 30, 1);
                }
            }
            if ((p.videoPackets % 300) == 0 || !frames.empty()) {
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

        if (payloadType != kVp8PayloadType) {
            const std::string dropKey =
                p.endpointId + ":ssrc-" + RtpPacket::ssrcHex(rtp.ssrc) + ":pt-" + std::to_string(payloadType);
            const auto dropped = ++g_droppedNonVp8VideoPackets[dropKey];
            if (dropped == 1 || (dropped % 300) == 0) {
                Logger::warn(
                    "PerParticipantNdiRouter: dropping unsupported non-AV1/non-VP8 video RTP endpoint=",
                    p.endpointId,
                    " ssrc=",
                    RtpPacket::ssrcHex(rtp.ssrc),
                    " pt=",
                    static_cast<int>(payloadType),
                    " dropped=",
                    dropped
                );
            }
            return;
        }

        ++routedVideoPackets_;
        auto encoded = p.vp8.push(rtp);
        if (encoded) {
            for (const auto& decoded : p.videoDecoder.decode(*encoded)) {
                p.ndi->sendVideoFrame(decoded, 30, 1);
            }
        }
        if ((p.videoPackets % 300) == 0) {
            Logger::info(
                "PerParticipantNdiRouter: VP8 video packets endpoint=",
                p.endpointId,
                " count=",
                p.videoPackets,
                " pt=",
                static_cast<int>(payloadType)
            );
        }
        return;
    }
}'''

    replace_regex(
        path,
        r"if\s*\(\s*media\s*==\s*\"video\"\s*\|\|\s*mid\s*==\s*\"video\"\s*\)\s*\{[\s\S]*?\n\s*return;\s*\n\s*\}\s*\n\s*\}\s*$",
        new_video_block,
        "route PT=41 AV1 instead of dropping it; keep VP8 fallback",
    )


def patch_av1_assembler() -> None:
    path = SRC / "Av1RtpFrameAssembler.cpp"
    if not path.exists():
        print(f"[WARN] missing {path}")
        return

    new_func = r'''bool Av1RtpFrameAssembler::appendCompletedObu(const std::uint8_t* data, std::size_t size) {
    if (!data || size == 0) {
        return true;
    }

    const std::uint8_t header = data[0];
    if ((header & 0x80) != 0 || (header & 0x01) != 0) {
        ++malformedPayloads_;
        if (malformedPayloads_ <= 5 || (malformedPayloads_ % 100) == 0) {
            Logger::warn(
                "Av1RtpFrameAssembler: malformed AV1 OBU header=",
                static_cast<int>(header),
                " size=",
                size,
                " malformed=",
                malformedPayloads_
            );
        }
        return false;
    }

    const int obuType = static_cast<int>((header >> 3) & 0x0f);
    const bool hasExtension = (header & 0x04) != 0;
    const bool hasSizeField = (header & 0x02) != 0;

    if (obuType == kObuTemporalDelimiter || obuType == kObuTileList || obuType == kObuPadding) {
        return true;
    }

    const std::size_t headerBytes = 1 + (hasExtension ? 1u : 0u);
    if (size < headerBytes) {
        return false;
    }

    // PATCH_V9_AV1_RESTORE_AUDIO_UNBLOCK:
    // FFmpeg/dav1d expects AV1 low-overhead OBUs with obu_has_size_field=1.
    // RTP AV1 payloads commonly omit the size field, and some senders keep the header bit
    // inconsistent. Normalize every OBU element into a self-contained low-overhead OBU.
    std::vector<std::uint8_t> normalized;
    normalized.reserve(size + 8);

    const std::uint8_t fixedHeader = static_cast<std::uint8_t>(header | 0x02);
    normalized.push_back(fixedHeader);

    std::size_t payloadPos = 1;
    if (hasExtension) {
        normalized.push_back(data[payloadPos]);
        ++payloadPos;
    }

    if (hasSizeField) {
        std::size_t afterLeb = payloadPos;
        std::size_t declaredPayloadSize = 0;
        if (readLeb128(data, size, afterLeb, declaredPayloadSize)) {
            const std::size_t declaredTotalSize = afterLeb + declaredPayloadSize;
            if (declaredTotalSize == size) {
                // A consistent obu_size field is already present. Preserve it.
                normalized.insert(normalized.end(), data + payloadPos, data + size);
            } else {
                // Header said size field was present, but the bytes do not describe this element.
                // Treat the element as RTP-style payload without a valid OBU size field.
                writeLeb128(static_cast<std::uint64_t>(size - payloadPos), normalized);
                normalized.insert(normalized.end(), data + payloadPos, data + size);
            }
        } else {
            writeLeb128(static_cast<std::uint64_t>(size - payloadPos), normalized);
            normalized.insert(normalized.end(), data + payloadPos, data + size);
        }
    } else {
        writeLeb128(static_cast<std::uint64_t>(size - payloadPos), normalized);
        normalized.insert(normalized.end(), data + payloadPos, data + size);
    }

    if (obuType == kObuSequenceHeader) {
        cachedSequenceHeaderObu_ = normalized;
        currentUnitHasSequenceHeader_ = true;
        currentUnitKey_ = true;
    }

    if (obuType == kObuFrameHeader || obuType == kObuTileGroup || obuType == kObuFrame) {
        currentUnitHasFrameData_ = true;
    }

    currentUnit_.insert(currentUnit_.end(), normalized.begin(), normalized.end());
    return true;
}'''

    replace_regex(
        path,
        r"bool\s+Av1RtpFrameAssembler::appendCompletedObu\s*\(\s*const\s+std::uint8_t\*\s+data\s*,\s*std::size_t\s+size\s*\)\s*\{[\s\S]*?\n\}\s*\n\s*bool\s+Av1RtpFrameAssembler::emitCurrentTemporalUnit",
        new_func + "\n\nbool Av1RtpFrameAssembler::emitCurrentTemporalUnit",
        "normalize AV1 RTP OBU elements before dav1d",
    )


def patch_ndi_sender() -> None:
    path = SRC / "NDISender.cpp"
    if not path.exists():
        print(f"[WARN] missing {path}")
        return

    text = read(path)
    text2 = text
    text2 = re.sub(
        r"createDesc\.clock_audio\s*=\s*true\s*;[^\n]*",
        "createDesc.clock_audio = false; // PATCH_V9_AV1_RESTORE_AUDIO_UNBLOCK: do not let NDI block the RTP/audio callback",
        text2,
        count=1,
    )
    if text2 != text:
        backup(path)
        write(path, text2)
        print("[OK] NDISender.cpp: set clock_audio=false")
    else:
        print("[WARN] NDISender.cpp: clock_audio assignment not found or already changed")


def main() -> None:
    if not SRC.exists():
        raise SystemExit("Run this script from the project root, e.g. D:\\MEDIA\\Desktop\\jitsi-ndi-native")

    patch_jitsi_signaling()
    patch_jingle_session()
    patch_native_webrtc_answerer()
    patch_router()
    patch_av1_assembler()
    patch_ndi_sender()

    print("\nDone. Now rebuild:")
    print("  cmake --build build --config Release")
    print("\nExpected log after this patch:")
    print("  <jitsi_participant_codecList>av1,vp8,opus</jitsi_participant_codecList>")
    print("  session-accept video contains AV1/PT=41 and VP8/PT=100")
    print("  PerParticipantNdiRouter: AV1 video packets ... producedFrames=...")
    print("  no 'dropping non-VP8 video RTP ... pt=41'")


if __name__ == "__main__":
    main()
