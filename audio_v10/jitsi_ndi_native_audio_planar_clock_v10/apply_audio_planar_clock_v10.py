from __future__ import annotations

import re
import shutil
from pathlib import Path

ROOT = Path.cwd()
SRC = ROOT / "src"
TAG = "PATCH_V10_AUDIO_PLANAR_CLOCK"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="")


def backup(path: Path) -> None:
    bak = path.with_suffix(path.suffix + ".bak_v10_audio")
    if not bak.exists():
        shutil.copy2(path, bak)


def patch_ffmpeg_audio_planar() -> None:
    path = SRC / "FfmpegMediaDecoder.cpp"
    if not path.exists():
        print(f"[WARN] missing {path}")
        return

    text = read(path)
    orig = text

    # The DecodedAudioFrameFloat32Planar/NDI path is planar: channel 0 block,
    # then channel 1 block. AV_SAMPLE_FMT_FLT is packed/interleaved; FLTP is planar.
    # Patch the output format requested from swresample.
    text, n1 = re.subn(
        r"(&outLayout\s*,\s*)AV_SAMPLE_FMT_FLT(\s*,\s*48000\s*,)",
        rf"\1AV_SAMPLE_FMT_FLTP\2 // {TAG}: planar float for NDI",
        text,
        count=1,
        flags=re.S,
    )

    # If this was already patched once and the comment blocks a repeat run, do not duplicate it.
    if n1 == 0 and "AV_SAMPLE_FMT_FLTP" in text:
        print("[OK] FfmpegMediaDecoder.cpp: audio output is already AV_SAMPLE_FMT_FLTP")
    elif n1:
        print("[OK] FfmpegMediaDecoder.cpp: changed Opus swresample output FLT -> FLTP")
    else:
        print("[WARN] FfmpegMediaDecoder.cpp: could not find Opus swr_alloc_set_opts2 output format")

    # Add one low-rate decoded-audio diagnostic after a successful converted frame.
    if TAG + "_DECODE_LOG" not in text:
        # Place the log after f.samples is set to converted and resize happened, before push_back.
        pattern = re.compile(
            r"(if\s*\(converted\s*>\s*0\)\s*\{\s*"
            r"f\.samples\s*=\s*converted\s*;\s*"
            r"f\.planar\.resize\(static_cast<[^;]+;\s*)"
            r"(out\.push_back\(std::move\(f\)\);)",
            re.S,
        )
        repl = (
            r"\1"
            "static std::uint64_t decodedAudioFrames = 0;\n"
            "                ++decodedAudioFrames;\n"
            f"                // {TAG}_DECODE_LOG\n"
            "                if (decodedAudioFrames == 1 || (decodedAudioFrames % 500) == 0) {\n"
            "                    Logger::info(\n"
            "                        \"FfmpegOpusDecoder: decoded audio frame samples=\",\n"
            "                        f.samples,\n"
            "                        \" channels=\",\n"
            "                        f.channels,\n"
            "                        \" format=fltp\"\n"
            "                    );\n"
            "                }\n"
            r"                \2"
        )
        text2, n2 = pattern.subn(repl, text, count=1)
        if n2:
            text = text2
            print("[OK] FfmpegMediaDecoder.cpp: added low-rate decoded-audio diagnostic")
        else:
            print("[WARN] FfmpegMediaDecoder.cpp: could not add decoded-audio diagnostic")
    else:
        print("[OK] FfmpegMediaDecoder.cpp: decoded-audio diagnostic already present")

    if text != orig:
        backup(path)
        write(path, text)


def patch_ndi_audio_clock() -> None:
    path = SRC / "NDISender.cpp"
    if not path.exists():
        print(f"[WARN] missing {path}")
        return

    text = read(path)
    orig = text

    # For audio, let NDI clock the audio stream. The v9 change prevented blocking,
    # but it can leave the receiver with bursty/unclocked audio when RTP/video decoding jitters.
    text, n = re.subn(
        r"createDesc\.clock_audio\s*=\s*false\s*;[^\n]*",
        f"createDesc.clock_audio = true; // {TAG}: let NDI pace audio; Opus/RTP decode is already 20 ms frames",
        text,
        count=1,
    )
    if n == 0:
        text, n = re.subn(
            r"createDesc\.clock_audio\s*=\s*true\s*;[^\n]*",
            f"createDesc.clock_audio = true; // {TAG}: let NDI pace audio; Opus/RTP decode is already 20 ms frames",
            text,
            count=1,
        )

    if n:
        print("[OK] NDISender.cpp: set createDesc.clock_audio=true")
    else:
        print("[WARN] NDISender.cpp: could not find createDesc.clock_audio assignment")

    if text != orig:
        backup(path)
        write(path, text)


def patch_av1_log_throttle() -> None:
    path = SRC / "PerParticipantNdiRouter.cpp"
    if not path.exists():
        print(f"[WARN] missing {path}")
        return

    text = read(path)
    orig = text

    # v9 logs every produced AV1 frame. Console I/O can easily steal time from audio.
    text, n = re.subn(
        r"if\s*\(\s*\(p\.videoPackets\s*%\s*300\)\s*==\s*0\s*\|\|\s*!frames\.empty\(\)\s*\)",
        f"if ((p.videoPackets % 300) == 0) // {TAG}: throttle AV1 frame logs; do not spam console every frame",
        text,
        count=1,
    )

    if n:
        print("[OK] PerParticipantNdiRouter.cpp: throttled AV1 per-frame logging")
    elif "throttle AV1 frame logs" in text:
        print("[OK] PerParticipantNdiRouter.cpp: AV1 log throttle already present")
    else:
        print("[WARN] PerParticipantNdiRouter.cpp: could not find v9 AV1 log condition")

    if text != orig:
        backup(path)
        write(path, text)


def main() -> None:
    if not SRC.exists():
        raise SystemExit("Run this script from the project root, e.g. D:\\MEDIA\\Desktop\\jitsi-ndi-native")

    patch_ffmpeg_audio_planar()
    patch_ndi_audio_clock()
    patch_av1_log_throttle()

    print("\nDone. Now rebuild:")
    print("  cmake --build build --config Release")
    print("\nExpected useful audio log:")
    print("  FfmpegOpusDecoder: decoded audio frame samples=960 channels=2 format=fltp")
    print("\nIf audio is still bad after this, the next target is a separate audio sender queue/jitter buffer.")


if __name__ == "__main__":
    main()
