v28b hotfix
===========
Fixes a single C++ raw-string typo in JitsiSourceMap.cpp from v28.

Run from repository root:

  powershell -ExecutionPolicy Bypass -File .\patch_display_names_v28b_fix_regex.ps1

No rollback is needed before applying this hotfix if v28 already failed at JitsiSourceMap.cpp line 128.
