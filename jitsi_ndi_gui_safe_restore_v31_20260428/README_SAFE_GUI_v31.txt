Jitsi NDI Native GUI safe restore v31
=====================================

Назначение
----------
Этот патч откатывает опасный подход GUI и ставит безопасный интерфейс:
- native exe, src/, CMake, DLL, build-ndi и WebRTC/NDI-часть НЕ трогаются;
- при запуске GUI передаёт только --room и, если включена галочка, --nick;
- GUI больше НЕ передаёт --quality, --width, --height, --ndi-name, --participant-filter;
- строка с полным расположением exe убрана из интерфейса;
- exe выбирается автоматически, но можно нажать Exe...;
- лог каждой сессии сохраняется в папку logs;
- таблица участников/качества заполняется только из логов native-программы.

Как применить
-------------
Из корня проекта:

cd D:\MEDIA\Desktop\jitsi-ndi-native
Expand-Archive -Force .\jitsi_ndi_gui_safe_restore_v31_20260428.zip .
.\jitsi_ndi_gui_safe_restore_v31_20260428\apply_gui_safe_restore_v31.ps1

Запуск:

powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Важно
-----
Если после запуска с ником Jitsi снова ведёт себя странно, просто сними галочку
"передавать --nick". Тогда GUI запускает native практически как старая рабочая версия:

jitsi-ndi-native.exe --room <room>

Это оставлено как аварийный режим, чтобы не ломать вход в конференцию и NDI-вывод.

Логи
----
Файлы логов появляются здесь:

D:\MEDIA\Desktop\jitsi-ndi-native\logs\jitsi_ndi_gui_YYYYMMDD_HHMMSS.log

Что делать, если Exe не найден
------------------------------
Нажми Exe... и выбери рабочий файл, обычно один из этих:

D:\MEDIA\Desktop\jitsi-ndi-native\build-ndi\Release\jitsi-ndi-native.exe
D:\MEDIA\Desktop\jitsi-ndi-native\build\Release\jitsi-ndi-native.exe
