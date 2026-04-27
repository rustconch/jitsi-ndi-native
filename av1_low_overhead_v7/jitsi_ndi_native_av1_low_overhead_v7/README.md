# AV1 low-overhead v7 fix

Заменяет `Av1RtpFrameAssembler` на более строгий AV1 RTP depacketizer:

- убирает AV1 aggregation header;
- собирает фрагментированные OBU;
- добавляет `obu_has_size_field` и LEB128 size для low-overhead AV1 stream;
- ждёт sequence header/keyframe перед отдачей кадров в `dav1d`;
- добавляет temporal delimiter перед temporal unit;
- уменьшает спам логов payload type.

Применение из корня проекта:

```powershell
cd D:\MEDIA\Desktop\jitsi-ndi-native

Remove-Item .\av1_low_overhead_v7 -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive .\jitsi_ndi_native_av1_low_overhead_v7.zip -DestinationPath .\av1_low_overhead_v7 -Force

python .\av1_low_overhead_v7\jitsi_ndi_native_av1_low_overhead_v7\apply_av1_low_overhead_v7.py

cmake --build build --config Release
```

После запуска ищи строки:

```text
Av1RtpFrameAssembler: produced AV1 temporal units=1
```

Если вместо этого долго идут только `dropping AV1 temporal unit until sequence header/keyframe arrives`, значит WebRTC-соединение получает delta frames, но не получает keyframe/sequence header. Тогда следующий шаг — принудительный RTCP PLI/FIR запрос keyframe.
