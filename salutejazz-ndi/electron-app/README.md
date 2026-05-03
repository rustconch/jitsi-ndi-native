# salutejazz-ndi-electron

Electron-приложение, которое присоединяется к комнате SaluteJazz и публикует
каждый медиа-поток каждого участника как отдельный NDI-источник.

## Что внутри

```
src/
├── main.ts                    # Electron main process, окно
├── preload.ts                 # mainBridge.log для headless-режима
├── index.html                 # минимальный UI (форма + лог + список источников)
├── renderer.ts                # оркестрация (UI ↔ Jazz ↔ NDI)
└── jazz/
    ├── jazzClient.ts          # SDK init, аутентификация, join комнаты
    ├── streamPipeline.ts      # подписка на per-participant потоки
    └── ndiPipeline.ts         # MediaStreamTrackProcessor → NDI bridge
```

## Установка и запуск

```bash
# 1. Сначала собрать нативный аддон (соседняя папка)
cd ../native-ndi-bridge
npm install      # собирает .node-файл из binding.gyp

# 2. Установить зависимости Electron-приложения
cd ../electron-app
npm install

# 3. Запустить (production-build + Electron)
npm run start

# 4. Headless-режим (без UI окна)
npm run start:headless
```

Перед запуском надо иметь:
- **NDI 6 SDK** установленный в систему (или `NDI_SDK_DIR` указывает на него).
- На Windows: `Processing.NDI.Lib.x64.dll` должна быть рядом с `.node` или в `PATH`.
- **SDK Key** SaluteJazz — получить на `developers.sber.ru`.

## Использование

1. Запускаем `npm run start`.
2. В UI вписываем:
   - Server URL — `https://salutejazz.ru` (или on-prem URL).
   - SDK Key — base64-строку (как показано на developers.sber.ru).
   - Имя в комнате — будет видно другим участникам.
   - Stable user id — любой stable идентификатор для JWT `sub`.
   - Room ID + Password — берутся из ссылки на конференцию вида
     `https://salutejazz.ru/calls/<RoomID>?psw=<Password>`.
     Например для `https://salutejazz.ru/calls/28zrlx?psw=ABCxyz` →
     Room ID = `28zrlx`, Password = `ABCxyz`.
3. Жмём "Войти и публиковать".
4. По мере того как участники появляются в комнате, в правом нижнем блоке
   появляются NDI-источники: `SaluteJazz NDI - <Имя>` и
   `SaluteJazz NDI - <Имя> Screen` (для демонстрации экрана).
5. В NDI Tools / OBS Studio / vMix эти источники сразу видны на сети.

## Headless-режим (для серверного развёртывания)

```bash
electron . --headless
```

В этом режиме окно скрыто, и логи/события идут в stdout главного процесса
(через `mainBridge.log` → IPC → `console.log`). Конфигурация в headless
читается из `process.env`:

| Переменная | Назначение |
|------------|-----------|
| `JAZZ_SDK_KEY` | SDK Key (base64) |
| `JAZZ_SERVER_URL` | URL сервера |
| `JAZZ_USER_NAME` | Имя в комнате |
| `JAZZ_USER_ID` | Stable user id |
| `JAZZ_ROOM_ID` | ID комнаты |
| `JAZZ_PASSWORD` | пароль |

> ⚠ В текущем POC headless-конфиг через env-переменные ещё **не подключён** —
> добавьте парсинг `process.env` в `renderer.ts` (или сделайте `--config file.json`)
> когда будете запускать на боевом сервере.

## Что POC уже умеет

- ✅ Аутентификация через SDK Key + JWT.
- ✅ Подключение к комнате анонимным участником (пароль обязателен только если
  у комнаты он включён).
- ✅ Подписка на `participantJoined`, `participantLeft`, `addTrack`, `removeTrack`,
  `trackMuteChanged`.
- ✅ Per-participant аудио → NDI sender в формате FLTP.
- ✅ Per-participant камера → NDI sender в NV12/I420.
- ✅ Demonstration экран (`displayScreen`) → отдельный NDI sender с суффиксом
  " Screen" в имени.
- ✅ Lifecycle: при выходе участника соответствующие NDI senders разрушаются.
- ✅ UI с живым логом и счётчиками fps на каждом источнике.

## Что POC ещё **не** делает (TODO для прода)

- ❌ Headless-конфиг через env / CLI args.
- ❌ Watchdog: переподключение при `room.event$ === 'kicked'` или потере связи
  (в Jitsi-плагине это `_v44_rejoin_lifecycle`, `_v95_same_device_protect` —
  здесь проще, потому что SDK сам ретраит, но финальную семантику надо
  проверить).
- ❌ Группировка аудио и видео одного участника в один NDI source (сейчас
  это два отдельных source name; для большинства NDI-приёмников это
  нормально, но vMix предпочитает один combined source).
- ❌ Интеграция с PowerShell-GUI из основного `jitsi-ndi-native` —
  `JitsiNdiGui.ps1` можно адаптировать почти без правок.
- ❌ Авто-определение оптимального FourCC по `VideoFrame.format`. Сейчас в
  `ndiPipeline.ts` только NV12/I420/BGRA/RGBA — добавить YV12, UYVY если
  Chromium вдруг отдаст их.

## Отладка

- **DevTools** открываются автоматически в non-headless режиме (`mode: detach`).
- Лог уровня `info` пишется и в DevTools console, и в правую панель UI, и в
  stdout главного процесса.
- Если NDI Tools не видит источники → проверить firewall (UDP mDNS 5353,
  TCP 5960+). Это NDI-проблема, не наша.
- Если приложение валится с `cannot find binding salutejazz_ndi_bridge` —
  значит native module не собрался. Запустить `npm run build` в
  `../native-ndi-bridge/` и посмотреть лог `node-gyp`.

## Лицензия

MIT для нашего кода. Для использования SaluteJazz SDK нужны лицензионные
условия Sber (см. `../docs/LICENSING.md`). Для использования NDI SDK —
условия Vizrt (см. `../../NDI 6 SDK/NDI SDK License Agreement.pdf`).
