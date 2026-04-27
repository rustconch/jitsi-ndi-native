Hotfix для ошибки:
PerParticipantNdiRouter.cpp(233,1): error C2059: синтаксическая ошибка: }

Причина:
Строка
 if ((p.videoPackets % 300) == 0) // PATCH_V10_AUDIO_PLANAR_CLOCK: throttle AV1 frame logs; do not spam console every frame {
закомментировала открывающую фигурную скобку {.

Применение из PowerShell:

cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_native_hotfix_line233_20260427.zip .
.\apply_hotfix_line233.ps1
cmake --build build --config Release

Альтернатива через git patch:

git apply --whitespace=nowarn .\jitsi_ndi_native_hotfix_line233.patch
cmake --build build --config Release

Если нужно откатить скрипт:
copy /Y .\src\PerParticipantNdiRouter.cpp.bak_hotfix_line233 .\src\PerParticipantNdiRouter.cpp
