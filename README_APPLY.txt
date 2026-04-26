Что исправляет этот патч
=======================

По логу видно, что программа всё ещё запускает старый status-pattern mode:
  Running Jitsi XMPP bootstrap + NDI status-pattern mode

Это означает, что один глобальный NDISender + TestPattern всё ещё активны в main.cpp.
Пока так, NDI будет показывать заглушку, а per-speaker pipeline не получит пакеты.

Патч делает три вещи:
1) Заменяет src/main.cpp: убирает TestPattern и один общий NDI sender.
2) Добавляет ndiBaseName и PerParticipantNdiRouter в JitsiSignaling.
3) Пробрасывает RTP из NativeWebRTCAnswerer в PerParticipantNdiRouter.

Как применить
=============

PowerShell:

cd $env:USERPROFILE\Downloads\jitsi-ndi-native-runtime-wiring-patch
.\apply_runtime_wiring_patch.ps1 -ProjectRoot "D:\MEDIA\Desktop\jitsi-ndi-native"

Потом пересобрать:

cd D:\MEDIA\Desktop\jitsi-ndi-native
cmake --build build --config Release

DLL снова рядом с exe, если нужно:

Copy-Item ".\build\_deps\libdatachannel-build\Release\datachannel.dll" ".\build\Release\" -Force

Запуск с логом:

New-Item -ItemType Directory -Force .\logs | Out-Null
$env:PATH = "D:\vcpkg\installed\x64-windows\bin;C:\Program Files\NDI\NDI 6 SDK\Bin\x64;D:\MEDIA\Desktop\jitsi-ndi-native\build\Release;$env:PATH"
$log = ".\logs\run_$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss').log"
.\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi --ndi-name JitsiNativeNDI 2>&1 | Tee-Object -FilePath $log

Ожидаемый лог после исправления
===============================

Не должно быть строки:
  Running Jitsi XMPP bootstrap + NDI status-pattern mode

Должна быть строка:
  Running Jitsi XMPP bootstrap + per-participant NDI media router

Когда реально пойдут RTP-пакеты, появятся строки вида:
  PerParticipantNdiRouter: created NDI participant source: JitsiNativeNDI - ...
  NativeWebRTCAnswerer: RTP audio packets=...
  NativeWebRTCAnswerer: RTP video packets=...
