# AV1 patch для `jitsi-ndi-native`

Этот архив добавляет первый слой поддержки входящего AV1 RTP от Jitsi/JVB:

- новый `Av1RtpFrameAssembler`;
- маршрут `payloadType == 41` в `PerParticipantNdiRouter`;
- декларацию/реализацию `FfmpegAv1Decoder` через копирование VP8-декодера с заменой `AV_CODEC_ID_VP8` на `AV_CODEC_ID_AV1`;
- добавление `src/Av1RtpFrameAssembler.cpp` в CMake;
- отключение VP8-only SDP-фильтра в `NativeWebRTCAnswerer.cpp`, если он найден;
- разрешение `AV1/VP9/H264/VP8` в `JingleSession.cpp`, если текущий код всё ещё VP8-only.

## Как применить

1. Распакуй архив в корень проекта:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive .\jitsi_ndi_native_av1_patch.zip -DestinationPath .\av1_patch -Force
```

2. Запусти патч:

```powershell
python .\av1_patch\apply_av1_patch.py
```

3. Собери проект:

```powershell
cmake --build build --config Release
```

## Что должно исчезнуть из логов

Было:

```text
PerParticipantNdiRouter: dropping non-VP8 video RTP ... pt=41
```

Должно стать:

```text
Av1RtpFrameAssembler: produced AV1 frames=1
PerParticipantNdiRouter: AV1 video packets endpoint=... count=300 producedFrames=...
```

## Если сборка упадёт

Скрипт делает best-effort патч, потому что точные текущие версии файлов у меня не открыты. Он создаёт backups с суффиксом `.bak_av1_patch`.

Наиболее вероятные ошибки:

1. `EncodedVideoFrame` не имеет поля `data` — тогда в `src/Av1RtpFrameAssembler.cpp` нужно заменить `frame.data = ...` на реальное имя поля из `FfmpegMediaDecoder.h`.
2. `RtpPacketView` использует другое имя payload-полей — тогда в `src/Av1RtpFrameAssembler.h` нужно добавить эти имена в `getPayloadImpl` / `getPayloadSizeImpl`.
3. `FfmpegAv1Decoder` не сдублировался автоматически — тогда открой `FfmpegMediaDecoder.cpp`, скопируй блок `FfmpegVp8Decoder`, замени `FfmpegVp8Decoder` на `FfmpegAv1Decoder`, а `AV_CODEC_ID_VP8` на `AV_CODEC_ID_AV1`.
4. FFmpeg собран без AV1 decoder — тогда код соберётся не всегда, а при запуске декодер может не открыться. Нужен FFmpeg с AV1 decoder, лучше с `libdav1d`.

