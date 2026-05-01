Jitsi NDI Portable v68
======================

Primary launch:
  JitsiNDI.exe

This portable build tries harder than v66:
  - Copies the full native Release folder.
  - Copies vcpkg/runtime DLLs found in the repo/build folders.
  - Copies common Visual C++ runtime DLLs from the working machine.
  - Copies Processing.NDI.Lib.x64.dll from known NDI Runtime locations if found.
  - Patches the portable GUI copy so native runs without a separate console window.
  - Adds the native exe folder to PATH before launching native.

If NDI does not appear on another PC:
  1. Run:
       powershell -ExecutionPolicy Bypass -File .\CHECK_PORTABLE.ps1
  2. Check that this file exists:
       build\Release\Processing.NDI.Lib.x64.dll
  3. Allow JitsiNDI.exe and build\Release\jitsi-ndi-native.exe in Windows Firewall.
  4. If the NDI DLL is missing, install NDI Tools/Runtime on the source PC and rebuild this portable archive.

Logs:
  GUI logs are stored in:
       logs\

Main project is not modified except dist output.
