v28 — human-readable NDI source names

Что меняет:
- NDI source теперь получает имя участника из <nick> / <display-name>, если оно уже пришло в presence.
- Камера и демонстрация остаются отдельными источниками:
  JitsiNativeNDI - ntcn camera
  JitsiNativeNDI - ntcn screen
  JitsiNativeNDI - vsdvsdvsdv camera
- Внутренние routing keys НЕ меняются и остаются endpoint-v0 / endpoint-v1, чтобы не сломать разделение camera/screen.
- Санитайзер имён теперь сохраняет UTF-8, поэтому русские имена не должны превращаться в подчёркивания.

Как применить:
  cd D:\MEDIA\Desktop\jitsi-ndi-native
  Expand-Archive -Force .\jitsi_ndi_native_display_names_v28_flat.zip .
  powershell -ExecutionPolicy Bypass -File .\patch_display_names_v28.ps1
  .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi

Rollback:
  powershell -ExecutionPolicy Bypass -File .\rollback_v28.ps1
