v75 stable reset + portable packager

Recommended order:

1. Restore stable native source:
   .\rollback_to_stable_v75.ps1

2. Rebuild native:
   .\rebuild_with_dav1d_v21.ps1

3. Quick local test from normal GUI/project, not portable.

4. Build portable:
   .\make_portable_v75_stable.ps1

The portable output is written to dist and starts with JitsiNDI.exe only.
No cmd launcher is created.
