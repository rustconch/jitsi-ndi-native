# Jitsi NDI Native v72b stability optimization patch
# ASCII-only PowerShell script. Applies conservative native changes only.
# v72b fixes repo-root detection and uses absolute paths for .NET file IO.

$ErrorActionPreference = "Stop"

function Write-Step($msg) { Write-Host "[v72b] $msg" }
function Is-RepoRoot($p) {
    if (-not $p) { return $false }
    return ((Test-Path (Join-Path $p "src\PerParticipantNdiRouter.cpp")) -and (Test-Path (Join-Path $p "CMakeLists.txt")))
}
function Find-RepoRoot() {
    $starts = @()
    $starts += (Get-Location).Path
    if ($PSScriptRoot) { $starts += $PSScriptRoot; $starts += (Split-Path -Parent $PSScriptRoot) }
    foreach ($s in $starts) {
        if (-not $s) { continue }
        $d = [System.IO.DirectoryInfo](Resolve-Path -LiteralPath $s)
        while ($d -ne $null) {
            if (Is-RepoRoot $d.FullName) { return $d.FullName }
            $d = $d.Parent
        }
    }
    throw "Could not find repo root. Run this script from inside jitsi-ndi-native."
}
function Read-Text($path) { return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) }
function Write-Text($path, $text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text, $enc)
}
function Backup-File($repo, $rel, $backupRoot) {
    $src = Join-Path $repo $rel
    if (-not (Test-Path $src)) { throw "Missing file: $src" }
    $dst = Join-Path $backupRoot $rel
    $dir = Split-Path -Parent $dst
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item $src $dst -Force
}
function Replace-Literal([string]$text, [string]$old, [string]$new, [string]$label) {
    if ($text.Contains($old)) {
        Write-Step "patched: $label"
        return $text.Replace($old, $new)
    }
    Write-Step "skip/not found: $label"
    return $text
}
function Replace-Regex([string]$text, [string]$pattern, [string]$new, [string]$label) {
    $count = ([regex]::Matches($text, $pattern)).Count
    if ($count -gt 0) {
        Write-Step "patched: $label ($count)"
        return [regex]::Replace($text, $pattern, $new)
    }
    Write-Step "skip/not found: $label"
    return $text
}

$repo = Find-RepoRoot
[System.IO.Directory]::SetCurrentDirectory($repo)
Set-Location $repo
Write-Step "repo root: $repo"

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupRoot = Join-Path $repo ".jnn_patch_backups\stability_opt_v72b_$stamp"
New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null

$files = @(
    "src\PerParticipantNdiRouter.cpp",
    "src\Av1RtpFrameAssembler.cpp",
    "src\FfmpegMediaDecoder.cpp"
)
foreach ($f in $files) { Backup-File $repo $f $backupRoot }

# 1) Router: reduce hot-path log spam and drop decoder burst backlog.
$routerPath = Join-Path $repo "src\PerParticipantNdiRouter.cpp"
$router = Read-Text $routerPath

# Throttle frequently repeated logs. Old builds logged AV1 producedFrames on nearly every decoded frame.
$router = Replace-Literal $router "(dropped % 200) == 0" "(dropped % 2000) == 0" "non-Opus audio drop log throttle"
$router = Replace-Literal $router "(p.audioPackets % 500) == 0" "(p.audioPackets % 2000) == 0" "audio packet log throttle"
$router = Replace-Literal $router "(p.videoPackets % 300) == 0" "(p.videoPackets % 1500) == 0" "video packet log throttle"
$router = Replace-Literal $router "(dropped % 300) == 0" "(dropped % 1500) == 0" "unsupported video drop log throttle"
$router = Replace-Literal $router "if ((p.videoPackets % 1500) == 0 || !frames.empty())" "if ((p.videoPackets % 1500) == 0)" "remove per-frame AV1 producedFrames log"
$router = Replace-Literal $router "if ((p.videoPackets % 300) == 0 || !frames.empty())" "if ((p.videoPackets % 1500) == 0)" "remove per-frame AV1 producedFrames log legacy"

# Live-output safety: if decoder releases a burst after backlog, send only the latest decoded frame.
# This prevents temporary CPU/network stalls from becoming permanent NDI latency.
$router = Replace-Regex $router 'for\s*\(\s*const\s+auto&\s+decoded\s*:\s*p\.av1Decoder\.decode\(encoded\)\s*\)\s*\{\s*p\.ndi->sendVideoFrame\(decoded,\s*30,\s*1\);\s*\}' 'auto decodedFrames = p.av1Decoder.decode(encoded); if (!decodedFrames.empty()) { p.ndi->sendVideoFrame(decodedFrames.back(), 30, 1); }' "AV1 decoded burst drop-oldest"
$router = Replace-Regex $router 'for\s*\(\s*const\s+auto&\s+decoded\s*:\s*p\.videoDecoder\.decode\(\*encoded\)\s*\)\s*\{\s*p\.ndi->sendVideoFrame\(decoded,\s*30,\s*1\);\s*\}' 'auto decodedFrames = p.videoDecoder.decode(*encoded); if (!decodedFrames.empty()) { p.ndi->sendVideoFrame(decodedFrames.back(), 30, 1); }' "VP8 decoded burst drop-oldest"

# Add marker once.
if ($router -notmatch "PATCH_V72_STABILITY_OPT") {
    $router = "// PATCH_V72_STABILITY_OPT: hot-path log throttling + live video burst trimming`r`n" + $router
}
Write-Text $routerPath $router

# 2) AV1 assembler: reduce produced-frame telemetry from every ~1 second/source to every ~10 seconds/source.
$av1Path = Join-Path $repo "src\Av1RtpFrameAssembler.cpp"
$av1 = Read-Text $av1Path
$av1 = Replace-Literal $av1 "(producedFrames_ % 30) == 0" "(producedFrames_ % 300) == 0" "AV1 produced temporal-unit log throttle"
if ($av1 -notmatch "PATCH_V72_STABILITY_OPT") {
    $av1 = "// PATCH_V72_STABILITY_OPT: reduced AV1 telemetry frequency`r`n" + $av1
}
Write-Text $av1Path $av1

# 3) FFmpeg conversion: use fast conversion path for YUV->BGRA; no protocol changes.
$ffPath = Join-Path $repo "src\FfmpegMediaDecoder.cpp"
$ff = Read-Text $ffPath
$ff = Replace-Literal $ff "SWS_BILINEAR" "SWS_FAST_BILINEAR" "swscale fast conversion"
if ($ff -notmatch "PATCH_V72_STABILITY_OPT") {
    $ff = "// PATCH_V72_STABILITY_OPT: faster swscale conversion path`r`n" + $ff
}
Write-Text $ffPath $ff

Write-Step "backup: $backupRoot"
Write-Step "done. Rebuild native after this patch. Recommended: .\rebuild_with_dav1d_v21.ps1"
