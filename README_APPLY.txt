Как применить:

1) Скопируй CMakeLists.txt из этого архива в корень проекта:
   D:\MEDIA\Desktop\jitsi-ndi-native\CMakeLists.txt

2) FFmpeg ставь так, БЕЗ avutil в квадратных скобках:
   D:\vcpkg\vcpkg.exe install "ffmpeg[avcodec,swscale,swresample,opus,vpx]:x64-windows"

3) В CMakeLists.txt avutil оставлен в target_link_libraries:
   target_link_libraries(jitsi-ndi-native PRIVATE avcodec avutil swscale swresample)

Это правильно: avutil не feature для установки через vcpkg, но это библиотека FFmpeg, которую нужно линковать.
