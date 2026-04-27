$ErrorActionPreference = "Stop"

$PatchDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Resolve-Path (Join-Path $PatchDir "..")

if (!(Test-Path (Join-Path $ProjectRoot "src")) -or !(Test-Path (Join-Path $ProjectRoot "CMakeLists.txt"))) {
    $ProjectRoot = Resolve-Path (Get-Location)
}

if (!(Test-Path (Join-Path $ProjectRoot "src")) -or !(Test-Path (Join-Path $ProjectRoot "CMakeLists.txt"))) {
    throw "Не найден корень проекта. Распакуй архив внутрь D:\MEDIA\Desktop\jitsi-ndi-native и запусти этот скрипт оттуда."
}

$Stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupDir = Join-Path $ProjectRoot ".jnn_patch_backups\audio_same_source_quality_$Stamp"
New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null

$Files = @(
    "src\JitsiSourceMap.cpp",
    "src\JitsiSourceMap.h",
    "src\PerParticipantNdiRouter.cpp",
    "src\PerParticipantNdiRouter.h",
    "src\FfmpegMediaDecoder.cpp",
    "src\NDISender.cpp"
)

foreach ($Rel in $Files) {
    $Src = Join-Path $ProjectRoot $Rel
    $DstBackup = Join-Path $BackupDir $Rel
    $DstBackupDir = Split-Path -Parent $DstBackup
    New-Item -ItemType Directory -Force -Path $DstBackupDir | Out-Null
    if (Test-Path $Src) {
        Copy-Item -Force $Src $DstBackup
    }

    $PatchFile = Join-Path $PatchDir $Rel
    if (!(Test-Path $PatchFile)) {
        throw "В архиве не найден файл патча: $Rel"
    }
    Copy-Item -Force $PatchFile $Src
    Write-Host "patched $Rel"
}

Write-Host ""
Write-Host "Готово. Бэкап старых файлов: $BackupDir"
Write-Host "Теперь пересобери:"
Write-Host "  cd $ProjectRoot"
Write-Host "  cmake --build build --config Release"
Write-Host ""
Write-Host "Если CMake попросит реконфигурацию:"
Write-Host "  cmake -S . -B build -G \"Visual Studio 17 2022\" -A x64"
Write-Host "  cmake --build build --config Release"
