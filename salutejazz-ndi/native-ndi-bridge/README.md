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

Аддон **не линкуется статически с NDI** — на всех платформах библиотека
загружается через `dlopen`/`LoadLibrary` при первом `createSender`. Это значит,
что для сборки достаточно только заголовочных файлов NDI SDK; runtime (`.so`,
`.dll`, `.dylib`) ставится отдельно и подгружается во время выполнения.

```bash
cd salutejazz-ndi/native-ndi-bridge
# По умолчанию заголовки ищутся в ../../NDI 6 SDK (рядом с salutejazz-ndi/).
npm install
```

Если путь к SDK содержит пробелы (как стандартный `NDI 6 SDK`), node-gyp может
сломаться — в этом случае создайте симлинк без пробелов и укажите его:

```bash
ln -sfn "../NDI 6 SDK" ../NDI6SDK
NDI_SDK_DIR="$PWD/../NDI6SDK" npm install
```

Для нестандартного пути:
```bash
NDI_SDK_DIR=/usr/local/ndisdk npm install
```

После сборки появится `build/Release/salutejazz_ndi_bridge.node`.
На Windows runtime DLL `Processing.NDI.Lib.x64.dll` копируется в тот же
каталог автоматически из NDI SDK.

## Runtime (важно!)

Аддон скомпилируется без NDI runtime, но `createSender` вернёт ошибку, пока
runtime не доступен в системе:

| OS      | Что должно быть установлено                          | Как указать путь                       |
|---------|------------------------------------------------------|----------------------------------------|
| Windows | `NDI 6 Runtime` инсталлятор (`Processing.NDI.Lib.x64.dll`) | `PATH` или папка с `.node`            |
| Linux   | `libndi.so.6` из NDI Linux SDK                       | `LD_LIBRARY_PATH` или `NDI_RUNTIME_DIR_V6` |
| macOS   | `libndi.dylib` из NDI macOS SDK                      | `DYLD_LIBRARY_PATH` или `NDI_RUNTIME_DIR_V6` |

Скачать NDI 6 SDK / Runtime можно на <https://ndi.video/>.

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
- Runtime NDI (`libndi.so.6` / `Processing.NDI.Lib.x64.dll` / `libndi.dylib`)
  должен быть установлен в системе или указан через `NDI_RUNTIME_DIR_V6`.
  Аддон загружает его динамически через `dlopen`/`LoadLibrary` при первом
  `createSender`, чтобы не блокировать сборку при отсутствии runtime.
