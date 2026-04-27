Jitsi NDI GUI v33 interface-only

Этот патч меняет только файл:
  JitsiNdiGui.ps1

Он НЕ меняет:
  src/*
  CMakeLists.txt
  build / build-ndi
  jitsi-ndi-native.exe
  WebRTC / Jitsi signaling / NDI-роутер

Что исправлено:
  1. Убран режим, где галочка отправляла --quality.
     В текущей native-версии такого рабочего флага нет, поэтому это могло ломать запуск.

  2. Поля/галочки больше не применяются к уже запущенному процессу.
     Пока идёт приём, room/nick/exe блокируются. Изменения применяются только после Stop -> Start.

  3. Ник передаётся только через поддерживаемый --nick и только при старте.
     Если нужно поменять ник: остановить, изменить ник, снова старт.
     Если с --nick конкретно у тебя снова будет проблема, сними галочку "передать ник при следующем старте".
     Тогда запуск будет базовый: --room <room>.

  4. Качество оставлено только как мониторинг по таблице участников.
     GUI не отправляет параметры качества в native, потому что выбор качества входящих потоков требует отдельной поддержки в native/WebRTC-части.

  5. Строка с полным путём exe убрана из интерфейса.
     Осталась кнопка Exe... для ручного выбора.

  6. Каждая сессия пишет отдельный лог в папку logs.
     Есть кнопка "Логи".

Как применить:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_gui_interface_only_v33_20260428.zip .
  .\jitsi_ndi_gui_interface_only_v33_20260428\apply_gui_interface_only_v33.ps1

Запуск:
  powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Откат:
  .\jitsi_ndi_gui_interface_only_v33_20260428\restore_latest_gui_backup.ps1
