Jitsi NDI portable complete packager v68
=======================================

Run from the repository root:

  powershell -ExecutionPolicy Bypass -File .\jitsi_ndi_portable_complete_v68_20260429\make_portable.ps1

It creates a portable ZIP in:

  dist\JitsiNDI_Portable_v68_YYYYMMDD_HHMMSS.zip

Primary launch inside portable package:

  JitsiNDI.exe

This version copies more runtime DLLs and patches the portable GUI copy so native runs without a visible console.
