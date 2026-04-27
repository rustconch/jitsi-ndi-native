# Jitsi NDI Native GUI Launcher v29

Это безопасный GUI-лаунчер поверх уже рабочей сборки `jitsi-ndi-native.exe`.

## Что умеет сейчас

- вставить полную ссылку Jitsi, например `https://meet.jit.si/6767676766767penxyi`;
- автоматически вытащить room name и запустить `jitsi-ndi-native.exe --room ...`;
- остановить процесс;
- показывать stdout/stderr лог;
- собирать таблицу участников/источников из логов:
  - endpoint/source key;
  - camera/screen, если source key выглядит как `...-v0` / `...-v1`;
  - последнее отправленное NDI-разрешение;
  - EndpointStats: bitrate, connectionQuality, packetLoss, RTT, maxEnabledResolution.

## Важно про ник и качество

В интерфейсе уже есть поля "Ник" и "Качество", но они реально начнут управлять нативным приложением только после того, как в C++ будут добавлены CLI-флаги:

```powershell
--nick "Jitsi NDI"
--quality 1080
```

Поэтому чекбокс `передавать --nick/--quality` по умолчанию выключен, чтобы случайно не сломать запуск текущей стабильной сборки.

## Установка

Скопируй `JitsiNdiGui.ps1` в корень проекта:

```powershell
D:\MEDIA\Desktop\jitsi-ndi-native\JitsiNdiGui.ps1
```

Запуск:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native
powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1
```

## Следующий шаг

v30/native flags:
1. добавить `--nick` в `main.cpp` / config / `JitsiSignaling`;
2. заменить hardcoded `probe123` на выбранный ник;
3. добавить `--quality 720|1080|2160|auto`;
4. прокинуть это в `NativeWebRTCAnswerer` для `ReceiverVideoConstraints`;
5. позже сделать live per-source quality через control-команды без рестарта.
