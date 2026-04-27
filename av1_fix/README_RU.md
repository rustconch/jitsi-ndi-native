# AV1 build fix для jitsi-ndi-native

Это маленький фикс поверх предыдущего AV1-патча.

Запускать из корня проекта:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native
python .\av1_fix\apply_av1_build_fix.py
cmake --build build --config Release
```

Что исправляет:

1. `Av1RtpFrameAssembler.cpp` использовал `frame.data`, но в твоём проекте поле `EncodedVideoFrame` называется иначе. Скрипт сам читает `src/Vp8RtpDepacketizer.h` и подставляет правильное имя.
2. В `PerParticipantNdiRouter.cpp` уже есть вызов `p.av1`, но в `ParticipantPipeline` не был добавлен `Av1RtpFrameAssembler av1;`.
