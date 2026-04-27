$ErrorActionPreference = 'Stop'

$repo = Get-Location
$file = Join-Path $repo 'src\PerParticipantNdiRouter.cpp'

if (!(Test-Path $file)) {
  throw "Не найден файл: $file. Запусти скрипт из корня D:\MEDIA\Desktop\jitsi-ndi-native"
}

$text = Get-Content -Raw -Path $file
$bad = ' if ((p.videoPackets % 300) == 0) // PATCH_V10_AUDIO_PLANAR_CLOCK: throttle AV1 frame logs; do not spam console every frame {'
$good = " // PATCH_V10_AUDIO_PLANAR_CLOCK: throttle AV1 frame logs; do not spam console every frame.`r`n if ((p.videoPackets % 300) == 0) {"

if ($text.Contains($bad)) {
  $backup = "$file.bak_hotfix_line233"
  Copy-Item -Force $file $backup
  $text = $text.Replace($bad, $good)
  Set-Content -Path $file -Value $text -NoNewline
  Write-Host "OK: исправлена битая строка AV1-лога. Бэкап: $backup"
  exit 0
}

$alreadyFixedA = ' // PATCH_V10_AUDIO_PLANAR_CLOCK: throttle AV1 frame logs; do not spam console every frame.'
$alreadyFixedB = ' if ((p.videoPackets % 300) == 0) {'
if ($text.Contains($alreadyFixedA) -and $text.Contains($alreadyFixedB)) {
  Write-Host "OK: эта строка уже выглядит исправленной. Патч не применялся."
  exit 0
}

Write-Host "Не нашёл точную битую строку. Покажи этот фрагмент:"
Write-Host "powershell -NoProfile -Command \"`$i=0; Get-Content .\src\PerParticipantNdiRouter.cpp | ForEach-Object { `$i++; if (`$i -ge 205 -and `$i -le 235) { '{0,4}: {1}' -f `$i, `$_ } }\""
exit 2
