# Jitsi NDI GUI v30 — nick/log/quality safe fix

Что исправлено:

1. Ник в Jitsi теперь передаётся всегда через `--nick`, без выключенного чекбокса.
2. Из верхней части GUI убрана видимая строка с путём к exe.
   GUI сам ищет `jitsi-ndi-native.exe` в:
   - `build-ndi\Release\jitsi-ndi-native.exe`
   - `build\Release\jitsi-ndi-native.exe`
   - `build-ndi\RelWithDebInfo\jitsi-ndi-native.exe`
   - корне репозитория

   Если авто-поиск не сработал, есть маленькая кнопка `Exe…`, но путь больше не занимает отдельную строку интерфейса.
3. Лог каждой сессии сохраняется в отдельный файл:
   `logs\jitsi_ndi_gui_YYYYMMDD_HHMMSS.log`
4. Выбор качества больше не использует несуществующий флаг `--quality`.
   Вместо этого GUI передаёт поддерживаемые native exe флаги:
   - `--width`
   - `--height`
5. Добавлены удобные поля:
   - ссылка/room Jitsi;
   - ник в конференции;
   - базовое имя NDI-источников;
   - фильтр участника;
   - выбор выходного разрешения;
   - кнопка «Фильтр из строки» для заполнения фильтра из таблицы участников.

Важно: это безопасный GUI-патч. Он не трогает C++/WebRTC/NDI-часть, чтобы не сломать уже работающие видео и звук.

## Как применить

Из корня проекта:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_gui_v30_nick_log_quality_fix_20260428.zip .
.\jitsi_ndi_gui_v30_nick_log_quality_fix_20260428\apply_gui_v30.ps1
```

Запуск GUI:

```powershell
powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1
```

Пересобирать native exe только из-за этого GUI-патча не нужно.

## Про выбор качества участников

GUI уже показывает качество участников, если native exe пишет в лог JVB/datachannel-статистику (`EndpointStats`, `ConnectionStats`, `ForwardedSources`).

Реальное управление качеством входящих потоков участников — это отдельная native-функция: нужно отправлять корректные receiver/video constraints в Jitsi bridge через datachannel/signaling. В этот патч я это не добавлял, чтобы не рисковать рабочим WebRTC/NDI-пайплайном.
