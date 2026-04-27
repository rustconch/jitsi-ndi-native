
from __future__ import annotations

import re
import shutil
from pathlib import Path

ROOT = Path.cwd()
SRC = ROOT / "src"

def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")

def write(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8", newline="")

def backup(path: Path) -> None:
    bak = path.with_suffix(path.suffix + ".bak_v11_syntax")
    if not bak.exists():
        shutil.copy2(path, bak)

def main() -> None:
    if not SRC.exists():
        raise SystemExit("Run this script from the project root, e.g. D:\\MEDIA\\Desktop\\jitsi-ndi-native")

    path = SRC / "PerParticipantNdiRouter.cpp"
    if not path.exists():
        raise SystemExit(f"Missing file: {path}")

    text = read(path)
    orig = text

    # v10 could produce:
    #   if ((p.videoPackets % 300) == 0) // PATCH... {
    # which comments out the opening brace and leaves a stray } later.
    text, n = re.subn(
        r"if\s*\(\s*\(p\.videoPackets\s*%\s*300\)\s*==\s*0\s*\)\s*//\s*PATCH_V10_AUDIO_PLANAR_CLOCK:\s*throttle AV1 frame logs;\s*do not spam console every frame\s*\{",
        "if ((p.videoPackets % 300) == 0) { // PATCH_V10_AUDIO_PLANAR_CLOCK: throttle AV1 frame logs; do not spam console every frame",
        text,
        count=1,
    )

    if n == 0:
        text, n = re.subn(
            r"if\s*\(\s*\(p\.videoPackets\s*%\s*300\)\s*==\s*0\s*\)\s*//([^\n{}]*throttle AV1 frame logs[^\n{}]*)\{",
            r"if ((p.videoPackets % 300) == 0) { //\1",
            text,
            count=1,
        )

    if n == 0:
        text, n = re.subn(
            r"if\s*\(\s*\(p\.videoPackets\s*%\s*300\)\s*==\s*0\s*\)\s*//([^\n{}]*throttle AV1 frame logs[^\n{}]*)\n\s*\{",
            r"if ((p.videoPackets % 300) == 0) { //\1",
            text,
            count=1,
        )

    if n:
        backup(path)
        write(path, text)
        print("[OK] PerParticipantNdiRouter.cpp: fixed malformed AV1 log if-brace")
        print("[OK] Backup:", path.with_suffix(path.suffix + ".bak_v11_syntax"))
    else:
        print("[INFO] Exact malformed line not found. No changes made.")
        print("Open src\\PerParticipantNdiRouter.cpp around line 225-235 and check for:")
        print("  if ((p.videoPackets % 300) == 0) // ... {")

    print("\nNow rebuild:")
    print("  cmake --build build --config Release")

if __name__ == "__main__":
    main()
