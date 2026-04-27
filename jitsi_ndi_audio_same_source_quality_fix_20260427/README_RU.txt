Патч от 2026-04-27: audio same-source + quality fix для jitsi-ndi-native.

Что меняет:
1. Audio SSRC больше не должен создавать отдельный NDI источник вида `JitsiNDI - ssrc-...`, если по Jitsi source name/owner можно определить того же участника, что и у video.
2. Если Jitsi не прислал owner для audio, код пытается извлечь endpoint из source name (`endpoint-a0`, `endpoint-v0`) и дополнительно мержит orphan-audio в единственный video endpoint в XML.
3. Router больше не декодирует любые audio RTP как Opus: он берёт payload type Opus из Jingle и отбрасывает non-Opus packets, чтобы не скармливать decoder'у RED/CN/telephone-event.
4. Opus decoder теперь настраивает raw RTP metadata до открытия FFmpeg decoder, пересоздаёт swresampler при изменении входного формата и выдаёт строго stereo float32 planar для NDI.
5. Убрано блокирование RTP callback через NDI clock_audio=true: входящий WebRTC RTP уже является clock source.
6. Исправлен баг с AV1 веткой, где из-за комментария с фигурной скобкой VP8 ветка могла стать недостижимой/логика была хрупкой.

Как применить:
1. Распакуй архив внутрь:
   D:\MEDIA\Desktop\jitsi-ndi-native
2. Запусти PowerShell из корня проекта:
   .\jitsi_ndi_audio_same_source_quality_fix_20260427\apply_audio_same_source_quality_fix.ps1
3. Пересобери:
   cmake --build build --config Release

После запуска в логах важно увидеть:
- PerParticipantNdiRouter: payload types opus=... av1=... vp8=...
- PerParticipantNdiRouter: created NDI participant source: JitsiNativeNDI - <один endpoint>
- audio packets endpoint=<тот же endpoint, что video>
- FfmpegOpusDecoder: decoded audio frame samples=...

В NDI/vMix должен появиться один источник на участника, а не отдельный audio-only source.
