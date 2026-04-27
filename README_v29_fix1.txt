
# Jitsi NDI Native GUI Launcher v29-fix1

Исправление относительно v29:

- исправлена ошибка при нажатии "Старт" в Windows PowerShell 5.1:
  `ProcessStartInfo.ArgumentList` мог быть NULL;
- аргументы теперь передаются через `$psi.Arguments` с безопасным quoting;
- убран лишний вывод `0 1 2 3 4 5` при запуске GUI.

## Установка

Скопируй `JitsiNdiGui.ps1` в корень проекта с заменой старого файла:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_gui_launcher_v29_fix1.zip .
powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1
```

## Важно

Чекбокс `передавать --nick/--quality` пока оставь выключенным, пока в native exe не добавлены эти CLI-флаги.
