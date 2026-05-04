@echo off
echo Jitsi NDI - Adding Windows Firewall rules (run as Administrator)
netsh advfirewall firewall add rule name="Jitsi NDI Native IN"  dir=in  action=allow program="%~dp0jitsi-ndi-native.exe" enable=yes profile=any
netsh advfirewall firewall add rule name="Jitsi NDI Native OUT" dir=out action=allow program="%~dp0jitsi-ndi-native.exe" enable=yes profile=any
echo Done.
pause
