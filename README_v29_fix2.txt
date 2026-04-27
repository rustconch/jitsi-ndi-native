# Jitsi NDI Native GUI Launcher v29-fix2

Исправление относительно v29-fix1:

- исправлена ошибка `System.Reflection.TargetParameterCountException` при нажатии `Стоп`;
- все WinForms `BeginInvoke` переведены на безопасный no-arg `System.Action`;
- при остановке GUI отписывается от stdout/stderr/Exited событий процесса;
- старые строки лога после `Стоп` больше не должны массово добегать в нижнее окно;
- процесс аккуратно отключает чтение stdout/stderr перед `Kill()`.

## Установка

Скопируй `JitsiNdiGui.ps1` в корень проекта с заменой старого файла:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_gui_launcher_v29_fix2.zip .
powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1
```

Пока чекбокс `передавать --nick/--quality` лучше держать выключенным, если соответствующие CLI-флаги ещё не добавлены в native exe.
