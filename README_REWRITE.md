# jitsi-ndi-native per-speaker NDI rewrite kit

Цель: уйти от DOM/canvas/test-pattern и сделать путь:

Jitsi SFU RTP -> SSRC demux -> participant pipeline -> decoder -> NDI source per participant.

## Что меняется концептуально

1. Jitsi не нужно принимать как «один общий экран». Он отдаёт RTP-пакеты аудио/видео от разных участников внутри одного PeerConnection.
2. Разделение участников делается по SSRC, а не по DOM-элементам.
3. Для каждого endpoint/участника создаётся свой NDI sender:
   - `<baseName> - <participant>`, внутри этого NDI source есть видео и аудио этого участника.
4. `NDISender` расширяется: теперь он умеет отправлять не только BGRA video, но и float32 planar audio.
5. `NativeWebRTCAnswerer` больше не только считает RTP-пакеты. Он передаёт сырые RTP в `PerParticipantNdiRouter`.
6. Декодирование — отдельный слой: VP8/H264/Opus. В этом kit заложен VP8/Opus путь как основной для meet.jit.si.

## Как внедрять

1. Скопировать файлы из `src/` в `D:\MEDIA\Desktop\jitsi-ndi-native\src`.
2. Заменить текущие `NDISender.h/.cpp` и `NativeWebRTCAnswerer.h/.cpp` версиями из kit.
3. Добавить новые `.cpp` в `SOURCES` в `CMakeLists.txt`:

```cmake
src/RtpPacket.cpp
src/JitsiSourceMap.cpp
src/PerParticipantNdiRouter.cpp
src/Vp8RtpDepacketizer.cpp
src/FfmpegMediaDecoder.cpp
```

4. Добавить зависимости FFmpeg через vcpkg:

```powershell
D:\vcpkg\vcpkg.exe install ffmpeg[avcodec,avutil,swscale,swresample]:x64-windows
```

5. В `CMakeLists.txt` добавить поиск FFmpeg. Пример:

```cmake
find_package(FFMPEG REQUIRED COMPONENTS avcodec avutil swscale swresample)
target_include_directories(jitsi-ndi-native PRIVATE ${FFMPEG_INCLUDE_DIRS})
target_link_libraries(jitsi-ndi-native PRIVATE ${FFMPEG_LIBRARIES})
```

Если твой vcpkg не даёт `find_package(FFMPEG)`, можно временно прописать include/lib руками из `D:/vcpkg/installed/x64-windows`.

## Интеграция в JitsiSignaling

В `JitsiSignaling` надо добавить поле:

```cpp
std::unique_ptr<PerParticipantNdiRouter> ndiRouter_;
```

После создания/инициализации `answerer_`:

```cpp
ndiRouter_ = std::make_unique<PerParticipantNdiRouter>(config_.ndiBaseName.empty() ? "JitsiNDI" : config_.ndiBaseName);
answerer_.setMediaPacketCallback([this](const std::string& mid, const std::uint8_t* data, std::size_t size) {
    if (ndiRouter_) ndiRouter_->handleRtp(mid, data, size);
});
```

В `handleXmppMessage()` для каждого входящего XML:

```cpp
if (ndiRouter_) ndiRouter_->updateSourcesFromJingleXml(xml);
```

Важно: это нужно вызывать на `session-initiate`, `source-add` и `source-remove`, потому что Jitsi добавляет/убирает SSRC динамически.

## Ограничение

Это инженерный rewrite-kit, а не собранный бинарник: я не могу проверить сборку против твоего локального NDI SDK и версии FFmpeg в этой среде. Логика разделения по SSRC, per-participant NDI и аудио API вынесена в код.
