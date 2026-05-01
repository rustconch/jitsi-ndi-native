# SaluteJazz → NDI

Порт идеи `jitsi-ndi-native` на платформу **SaluteJazz** (Sber).
Каждый участник конференции (его аудио, его камера) и каждая демонстрация экрана
становятся отдельным NDI-источником в локальной сети, без потери качества.

## Структура

```
salutejazz-ndi/
├── electron-app/         # POC: Electron + @salutejs/jazz-sdk-web → MediaStreamTrack
├── native-ndi-bridge/    # Node-API addon: MediaStreamTrack → NDI 6 SDK
└── docs/
    ├── LICENSING.md      # SDK Key, лицензия, лимиты, тарифы
    └── ARCHITECTURE.md   # детальная схема порта
```

## Как устроен пайплайн

```
Electron renderer (Chromium)
  │
  │  @salutejs/jazz-sdk-web
  │  ├─ createJazzSdkWeb({...})
  │  ├─ createJazzClient(sdk, {serverUrl})
  │  └─ client.conferences.join({roomId, password})  ──▶ JazzRoom
  │
  │  для каждого JazzRoomParticipant:
  │    room.getParticipantMediaSource(id, 'audio').stream()        → MediaStream
  │    room.getParticipantMediaSource(id, 'video').stream()        → MediaStream
  │    room.getParticipantMediaSource(id, 'displayScreen').stream()→ MediaStream
  │
  │  MediaStreamTrackProcessor
  │  ├─ video:  ReadableStream<VideoFrame>   (декодированные кадры из Chromium)
  │  └─ audio:  ReadableStream<AudioData>    (планарный PCM)
  │
  ▼
native-ndi-bridge (require('salutejazz-ndi-bridge'))
  │
  │  bridge.createSender("SaluteJazz NDI - Алексей")
  │  bridge.sendVideo(handle, planeBuffers, w, h, fourCC, fps_n, fps_d)
  │  bridge.sendAudio(handle, planarFloat,  sampleRate, channels)
  │
  ▼
NDI 6 SDK (Processing.NDI.Lib.h) → сетевые NDI-источники
```

## Минимум для запуска

1. Получить SDK Key — см. [docs/LICENSING.md](docs/LICENSING.md).
2. Установить NDI 6 SDK (Windows/macOS/Linux): https://ndi.video/sdk/
3. `cd salutejazz-ndi/native-ndi-bridge && npm install` (собирает нативный аддон).
4. `cd salutejazz-ndi/electron-app && npm install && npm run start`.
5. В UI приложения вставить SDK Key, server URL (`https://salutejazz.sberdevices.ru`),
   roomId и password — приложение войдёт headless и поднимет NDI-источники.

См. README в каждом подпроекте для деталей.

## Лицензия

NDI SDK — лицензия Vizrt NDI AB (см. `NDI 6 SDK/NDI SDK License Agreement.pdf`).
SaluteJazz SDK — лицензия Sber (см. `docs/LICENSING.md`).
Код этого порта — MIT.
