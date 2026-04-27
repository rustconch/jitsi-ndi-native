Что чинит патч
================

Лог показывает, что RTP и AV1-сборщик уже работают:
  Av1RtpFrameAssembler: produced AV1 temporal units=1 sequenceHeaderCached=1 key=1

Но FFmpeg дальше падает на выборе аппаратного AV1:
  Your platform doesn't support hardware accelerated AV1 decoding.
  Failed to get pixel format.

Патч заставляет FFmpeg выбирать software pixel format и, если доступен, предпочитать libdav1d для AV1.

Как применить
=============

1. Распакуй архив в корень проекта:
   D:\MEDIA\Desktop\jitsi-ndi-native

2. В PowerShell:
   cd D:\MEDIA\Desktop\jitsi-ndi-native
   powershell -ExecutionPolicy Bypass -File .\patch_av1_software_decode.ps1

3. Пересобери:
   cmake --build build --config Release

4. Запусти:
   .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

Ожидаемый результат
===================

В логе должны исчезнуть строки:
  Your platform doesn't support hardware accelerated AV1 decoding
  Failed to get pixel format

И должны появиться/остаться строки AV1 temporal units + NDI video frames.
