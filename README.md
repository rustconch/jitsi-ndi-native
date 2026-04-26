# jitsi-ndi-native rebuilt

Clean rebuilt package for `D:\MEDIA\Desktop\jitsi-ndi-native`.

This archive intentionally does **not** bundle the NDI SDK, Visual Studio build output, Jitsi source trees, or vendored dependency dumps. It builds a clean app and fetches/uses dependencies through CMake/vcpkg.

## What this version does

- Connects to Jitsi XMPP over WebSocket.
- Joins a meet.jit.si MUC room as an anonymous participant.
- Answers Jingle `session-initiate` with a native libdatachannel `PeerConnection`.
- Handles repeated Jitsi `moving` re-offers without crashing by resetting the previous peer session.
- Sends local ICE candidates as Jingle `transport-info`, skipping relay candidates in Jingle because Jitsi rejects some libjuice relay candidates as malformed.
- Receives remote audio/video tracks and logs RTP packet counters.
- Keeps NDI alive with a low-cost native BGRA test/status pattern.

Important: this is a stable native signaling/RTP receiver harness. It does not yet decode VP8/H264 into real video frames. That requires an RTP depacketizer + video decoder stage, for example FFmpeg/libvpx, after the RTP counters confirm media is flowing.

## Build on Windows

Recommended clean setup:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native

# If vcpkg is not installed yet:
git clone https://github.com/microsoft/vcpkg.git D:\vcpkg
D:\vcpkg\bootstrap-vcpkg.bat
D:\vcpkg\vcpkg.exe install openssl:x64-windows

Remove-Item -Recurse -Force .\build-ndi -ErrorAction SilentlyContinue

cmake -S . -B build-ndi -G "Visual Studio 17 2022" -A x64 `
  -DCMAKE_TOOLCHAIN_FILE="D:/vcpkg/scripts/buildsystems/vcpkg.cmake" `
  -DVCPKG_TARGET_TRIPLET=x64-windows `
  -DJNN_NDI_SDK_DIR="C:\Program Files\NDI\NDI 6 SDK"

cmake --build build-ndi --config Release
```

If the built `.exe` cannot find OpenSSL DLLs at runtime:

```powershell
Copy-Item "D:\vcpkg\installed\x64-windows\bin\libcrypto-3-x64.dll" ".\build-ndi\Release\" -Force
Copy-Item "D:\vcpkg\installed\x64-windows\bin\libssl-3-x64.dll" ".\build-ndi\Release\" -Force
```

## Run

```powershell
.\build-ndi\Release\jitsi-ndi-native.exe --room 6767676766767penxyi --ndi-name JitsiNativeNDI --nick probe123
```

Useful flags:

```powershell
--room ROOM_NAME
--participant-filter TEXT
--ndi-name NAME
--nick NICK
--width 1280
--height 720
--fps 30
--websocket-url https://meet.jit.si/xmpp-websocket
--domain meet.jit.si
--guest-domain guest.meet.jit.si
--muc-domain conference.meet.jit.si
--no-real-xmpp
```

## Next debug target

After `track opened, mid=video`, check for logs like:

```text
NativeWebRTCAnswerer: RTP video packets=...
```

If counters stay at zero, the issue is still in Jingle/RTCP/source negotiation. If counters grow, the next step is adding a decoder stage and sending decoded frames to `NDISender` instead of the test/status pattern.
