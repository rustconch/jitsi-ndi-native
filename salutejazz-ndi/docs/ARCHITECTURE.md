# Архитектура SaluteJazz NDI-порта

## Сравнение с jitsi-ndi-native

| Слой | jitsi-ndi-native (C++) | salutejazz-ndi (TS+C++) |
|------|------------------------|--------------------------|
| **Сигналинг** | XMPP/Jingle поверх WebSocket — `XmppWebSocketClient.cpp`, `JingleSession.cpp` (~2300 строк) | `@salutejs/jazz-sdk-web` — обработано SDK |
| **WebRTC peer** | libdatachannel `PeerConnection` — `NativeWebRTCAnswerer.cpp` (~700 строк) | Chromium WebRTC внутри Electron renderer |
| **RTP-приём** | Custom RTP-парсеры (VP8/AV1 depacketizers) — `Av1RtpFrameAssembler.cpp`, `Vp8RtpDepacketizer.cpp` (~1200 строк) | SDK сам декодирует → MediaStreamTrack |
| **Декодирование** | FFmpeg + dav1d — `FfmpegMediaDecoder.cpp` (~600 строк) | `MediaStreamTrackProcessor` → VideoFrame |
| **Маршрутизация по участникам** | Парсинг SSRC из Jingle, mapping SSRC→endpointId — `PerParticipantNdiRouter.cpp` (~700 строк) | `room.getParticipantMediaSource(participantId, mediaType)` — встроено в SDK |
| **NDI отправка** | NDI 6 SDK напрямую — `JitsiNdiSender` | NDI 6 SDK через `salutejazz-ndi-bridge` (~250 строк C++) |
| **GUI** | PowerShell `JitsiNdiGui.ps1` (Windows-only) | HTML/CSS в Electron (cross-platform) |

**Итого**: ~5500 строк C++ заменены на ~1300 строк TS + 250 строк C++.

## Поток данных

```
                  ┌──────────────────────────────────────────────────┐
                  │  Electron Renderer (Chromium V8 + Node integ.)   │
                  │                                                  │
SaluteJazz сервер │  ┌──────────────────────┐                        │
  (cloud / on-prem)──▶│ @salutejs/jazz-sdk-web │                        │
                  │  └────────┬─────────────┘                        │
                  │           │                                      │
                  │           ▼  for each (participant, mediaType):  │
                  │  ┌──────────────────────────────────┐            │
                  │  │ room.getParticipantMediaSource() │            │
                  │  │      .stream() → MediaStream     │            │
                  │  └────────┬─────────────────────────┘            │
                  │           │                                      │
                  │           ▼                                      │
                  │  ┌──────────────────────────────┐                │
                  │  │ MediaStreamTrackProcessor    │                │
                  │  │ ReadableStream<VideoFrame>   │                │
                  │  │ ReadableStream<AudioData>    │                │
                  │  └────────┬─────────────────────┘                │
                  │           │                                      │
                  │           ▼                                      │
                  │  ┌────────────────────────────────────┐          │
                  │  │ NdiPump.start() — pulls frames,    │          │
                  │  │ packs planes (NV12/I420), copies   │          │
                  │  │ audio to f32-planar Float32Array,  │          │
                  │  │ calls salutejazz-ndi-bridge        │          │
                  │  └────────┬───────────────────────────┘          │
                  │           │ require('salutejazz-ndi-bridge')    │
                  │           │ (loaded in renderer as native node)  │
                  └───────────┼──────────────────────────────────────┘
                              │
                              ▼
                  ┌──────────────────────────────────────────────────┐
                  │ salutejazz-ndi-bridge.node (C++ N-API)           │
                  │                                                  │
                  │ NdiSender::SendVideo() → NDIlib_send_send_video  │
                  │ NdiSender::SendAudio() → NDIlib_send_send_audio  │
                  └────────────────────────┬─────────────────────────┘
                                           │
                                           ▼ NDI multicast/unicast
                              ┌────────────────────────────┐
                              │ NDI Tools / OBS / vMix     │
                              │ "SaluteJazz NDI - Алексей"│
                              │ "SaluteJazz NDI - Алексей  │
                              │  Screen"                   │
                              │ "SaluteJazz NDI - Мария"   │
                              └────────────────────────────┘
```

## Ключевые решения и trade-off'ы

### 1. Electron, а не headless Node.js + node-webrtc

Можно было бы попробовать запустить SDK в чистом Node.js через `node-webrtc`.
Но:
- `@salutejs/jazz-sdk-web` ожидает браузерное окружение: `window.crypto.subtle`,
  `RTCPeerConnection`, `MediaStream`, DOM-события, и так далее.
- В демо явно есть `@salutejs/jazz-sdk-electron` пакет — Sber официально
  поддерживает Electron-сценарии.
- Electron даёт нам стабильный Chromium с `MediaStreamTrackProcessor`
  (W3C Insertable Streams API), который позволяет вытащить декодированные
  кадры **без рендера в canvas + захвата** — то есть без потерь качества.

### 2. Native binding в renderer-процессе

Стандартная безопасностная рекомендация Electron — `contextIsolation: true` и
без `nodeIntegration`. Мы намеренно нарушаем это, потому что:
- Renderer **не** загружает произвольный веб-контент. Только наш `index.html`
  и SaluteJazz SDK.
- Передача кадров через IPC (renderer → main → native) добавила бы
  сериализацию и потеряла бы преимущество zero-copy `Transferable`.
- `VideoFrame` и `AudioData` — non-serialisable объекты; их в IPC нельзя.

Если потребуется multi-window setup или загрузка сторонних SDK в renderer —
тогда переехать на отдельный hidden BrowserWindow с native bindings, а UI
в защищённом окне.

### 3. Синхронный `NDIlib_send_send_video_v2`, а не async

NDI SDK предоставляет два варианта:
- `send_video_v2` — копирует кадр в очередь NDI, можно сразу освободить буфер.
- `send_video_async_v2` — не копирует, требует от вызывающего удерживать буфер
  до следующего вызова или до `destroy`.

Мы используем синхронный вариант, потому что:
- `VideoFrame.copyTo()` уже скопировал данные в наш `Uint8Array` — мы _уже_
  владеем буфером.
- Async добавляет сложности с lifetime: пришлось бы вести pool буферов и
  не освобождать до подтверждения от NDI.
- На 1080p30 синхронный `send_video_v2` тратит ~1-2 ms (просто `memcpy`), что
  отлично укладывается в 33 ms бюджет кадра.

### 4. NDI source per (participant, kind), не per participant

Альтернатива: один NDI source на участника со встроенным аудио. Но:
- Демонстрация экрана у того же участника — это **отдельный** видеопоток
  (`displayScreen`), и его NDI-сцена обычно мутит звук (звук всё равно
  идёт от микрофона того же человека).
- Многие операторские приложения (vMix, OBS, ATEM Mini) проще обрабатывают
  отдельные источники: видео — в один Layer, аудио — в Audio Mixer.
- NDI имеет минимальный overhead на дополнительный source — это не проблема.

При желании склеить — это легко делается одним патчем в `ndiPipeline.ts`
(использовать тот же `senderHandle` для аудио и видео одного участника).

### 5. Отсутствие пула буферов

Мы аллоцируем `new Uint8Array(...)` на каждый кадр. На 1080p30 это
~3 МБ × 30 = 90 МБ/с GC-нагрузки на источник. Для 5 источников = 450 МБ/с,
для 10 = 900 МБ/с — V8 справится, но GC-паузы могут начать сказываться.

Для production стоит сделать пул `Uint8Array` per-pump с переиспользованием.
В POC — `--no-compact-heap` Electron флаг и стандартный V8 хорошо.

## Вопросы которые ещё надо проверить на живом SDK Key

1. Какой `format` отдаёт `VideoFrame` в Chromium 38 для типичного потока
   SaluteJazz? (Скорее всего NV12 после H.264 декодирования, I420 после VP8.)
2. Как себя ведёт `addTrack` event vs `getParticipantMediaSource().stream()` —
   гонки могут быть, мы их обрабатываем в `streamPipeline.ts::refresh()`,
   но реальные edge cases надо проверить.
3. Поведение при потере сетевого соединения — SDK сам переподключается, или
   надо вручную? Проверить через `room.event$ === 'connectionLost'` или
   аналог.
4. Лимит на одновременные подключения от одного SDK Key. Если жесткий —
   придётся выпускать несколько ключей или использовать корпоративный
   on-prem.
5. Кодеки: видео в SaluteJazz — VP8/H.264/VP9/AV1? От этого зависит, какой
   `format` будет в `VideoFrame`. Для NDI это значит ничего (мы получаем
   уже декодированные пиксели), но влияет на CPU-нагрузку Chromium.
