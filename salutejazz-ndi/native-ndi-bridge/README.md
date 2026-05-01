# salutejazz-ndi-bridge

Тонкий Node-API аддон, преобразующий декодированные медиа-кадры в NDI-источники.

## Что делает

- `createSender(name)` создаёт NDI-источник в локальной сети
  (`NDIlib_send_create`).
- `sendVideo(handle, buffer, w, h, stride, fourCC, fpsN, fpsD)` отправляет один
  кадр (`NDIlib_send_send_video_v2`).
- `sendAudio(handle, planarFloat, sr, ch, samples)` отправляет аудио-фрейм
  (`NDIlib_send_send_audio_v3` в формате FLTP — планарный float32, ровно как
  выдаёт `AudioData.copyTo(buf, {format: 'f32-planar'})`).

Использует **NDI 6 SDK** (тот же что в основном `jitsi-ndi-native`).

## Поддерживаемые форматы

Видео: `NV12`, `I420`, `YV12`, `UYVY`, `BGRA`, `BGRX`, `RGBA`, `RGBX`.
В Chromium `VideoFrame.format` обычно равен `"NV12"` или `"I420"` — оба
поддерживаются NDI напрямую без конверсии.

Аудио: только `FLTP` (32-bit float planar). Подходит для всего, что отдаёт
`AudioData` из `MediaStreamTrackProcessor`.

## Сборка

```bash
# По умолчанию ищет NDI SDK в ../../NDI 6 SDK (рядом с salutejazz-ndi/)
cd salutejazz-ndi/native-ndi-bridge
npm install            # node-gyp rebuild
```

Для нестандартного пути к NDI:
```bash
NDI_SDK_DIR="C:/Program Files/NDI/NDI 6 SDK" npm install
# linux:   NDI_SDK_DIR=/usr/local/ndisdk npm install
# macos:   NDI_SDK_DIR=/Library/NDI\ SDK\ for\ Apple npm install
```

После сборки появится `build/Release/salutejazz_ndi_bridge.node`.
На Windows DLL `Processing.NDI.Lib.x64.dll` копируется в тот же каталог.

## Использование

```ts
import {
  createSender,
  sendVideo,
  sendAudio,
  FourCC,
  destroySender,
} from 'salutejazz-ndi-bridge';

const handle = createSender('SaluteJazz NDI - Алексей', { clockVideo: true });

// Видео-кадр (например, из MediaStreamTrackProcessor + VideoFrame.copyTo):
const yBuffer = new Uint8Array(width * height);
const uvBuffer = new Uint8Array(width * height / 2);
const nv12 = new Uint8Array(yBuffer.length + uvBuffer.length);
nv12.set(yBuffer, 0);
nv12.set(uvBuffer, yBuffer.length);

sendVideo(
  handle,
  nv12,
  width, height,
  width,            // Y stride
  FourCC.NV12,
  30000, 1001,      // 29.97 fps
);

// Аудио (из AudioData.copyTo с format='f32-planar'):
const planar = new Float32Array(numChannels * numSamples);
sendAudio(
  handle,
  planar,
  audioData.sampleRate,
  audioData.numberOfChannels,
  audioData.numberOfFrames,
  numSamples * 4,   // channel stride in bytes
);

// При уходе участника:
destroySender(handle); // или просто потерять ссылку — GC закроет
```

## Заметки по производительности

- `NDIlib_send_send_video_v2` (синхронный) копирует фрейм во внутреннюю
  очередь NDI и возвращается. Реальное JPEG/SpeedHQ-сжатие и сетевая
  отправка идут в фоновых потоках NDI SDK.
- При 1080p30 NV12 это ~3 МБ на кадр × 30 fps = ~90 МБ/с per-source. На
  10 источников — ~900 МБ/с в RAM. Это нормальная нагрузка для современного
  PC; основной CPU съедает кодирование внутри NDI runtime.
- Если нужен меньший CPU/network footprint — установить **NDI HX driver**;
  тогда NDI runtime будет передавать H.264 вместо SpeedHQ.

## Известные ограничения

- Аддон загружается **в renderer-процессе Electron** (нужно
  `nodeIntegration: true` или `contextIsolation: false` для конкретного окна).
  Это безопасно, потому что мы — операторский тул, а не браузер для произвольных
  сайтов.
- На Windows runtime DLL `Processing.NDI.Lib.x64.dll` должен быть рядом с
  `.node`-файлом или в `PATH`. `binding.gyp` копирует её автоматически после
  сборки.
- Linux: требуется `libndi.so` из NDI 6 SDK (положить в `/usr/local/lib`
  или указать `LD_LIBRARY_PATH`).
