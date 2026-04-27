Патч: jitsi_ndi_native_nudnye_fixes.patch

Что исправляет:
1) src/PerParticipantNdiRouter.cpp
   Исправляет синтаксическую ошибку в AV1-ветке: открывающая скобка if оказалась внутри //-комментария, из-за чего MSVC ломает сборку на PerParticipantNdiRouter.cpp.

2) src/NDISender.cpp
   Делает инициализацию/деинициализацию NDI SDK ref-counted для нескольких NDI-источников. Это безопаснее для режима "один NDI source на участника": закрытие одного отправителя больше не вызывает NDIlib_destroy(), пока живы другие отправители.

Команда применения из PowerShell:

cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force "$env:USERPROFILE\Downloads\jitsi_ndi_native_nudnye_fixes_20260427.zip" .
git apply --whitespace=nowarn .\jitsi_ndi_native_nudnye_fixes.patch
cmake --build build --config Release

Альтернатива: после распаковки можно запустить:

.\apply_nudnye_fixes.ps1

Если нужно откатить после применения:

git apply -R --whitespace=nowarn .\jitsi_ndi_native_nudnye_fixes.patch
