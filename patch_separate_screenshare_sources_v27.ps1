$ErrorActionPreference = 'Stop'

function Fail($msg) {
  Write-Host "[v27][ERROR] $msg" -ForegroundColor Red
  exit 1
}

function Backup-File($path, $stamp) {
  if (Test-Path $path) {
    Copy-Item $path "$path.bak_v27_$stamp" -Force
    Write-Host "[v27] Backup: $path.bak_v27_$stamp"
  }
}

$root = (Get-Location).Path
Write-Host "[v27] Repository root: $root"

$router = Join-Path $root 'src\PerParticipantNdiRouter.cpp'
if (!(Test-Path $router)) { Fail "src\PerParticipantNdiRouter.cpp not found. Run this script from repository root." }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
Backup-File $router $stamp

$src = Get-Content $router -Raw -Encoding UTF8
$orig = $src

$newSourceNameFor = @'
std::string PerParticipantNdiRouter::sourceNameFor(const JitsiSourceInfo& source) const {
    std::string label;

    const std::string endpoint = source.endpointId.empty()
        ? (source.displayName.empty() ? source.sourceName : source.displayName)
        : source.endpointId;

    const std::string videoType = toLower(source.videoType);

    if (source.media == "video") {
        // v27: camera and screen share from one participant must be separate NDI sources.
        // Jitsi source names are stable per media source: endpoint-v0 = camera, endpoint-v1 = desktop.
        label = !source.sourceName.empty() ? source.sourceName : endpoint;

        if (videoType == "desktop" || videoType == "screen" || videoType == "screenshare") {
            label += " screen";
        } else if (videoType == "camera") {
            label += " camera";
        } else if (!videoType.empty()) {
            label += " " + videoType;
        } else {
            label += " video";
        }
    } else if (source.media == "audio") {
        // Keep participant audio attached to the participant camera pipeline.
        // If audio arrives before video, this creates the same key/name that the camera will reuse later.
        if (!endpoint.empty() && !isFallbackSsrcEndpoint(endpoint)) {
            label = endpoint + "-v0 camera";
        } else {
            label = endpoint.empty() ? source.sourceName : endpoint;
        }
    } else {
        label = source.displayName.empty()
            ? (endpoint.empty() ? source.sourceName : endpoint)
            : source.displayName;
    }

    const std::string safe = JitsiSourceMap::sanitizeForNdiName(label);
    return ndiBaseName_ + " - " + safe;
}
'@

$sourceNamePattern = '(?s)std::string\s+PerParticipantNdiRouter::sourceNameFor\s*\(\s*const\s+JitsiSourceInfo&\s+source\s*\)\s+const\s*\{.*?\n\}\s*(?=\r?\nstd::string\s+PerParticipantNdiRouter::pipelineKeyForLocked)'
$src2 = [regex]::Replace($src, $sourceNamePattern, $newSourceNameFor)
if ($src2 -eq $src) {
  Fail "Could not patch sourceNameFor. PerParticipantNdiRouter.cpp layout is different."
}
$src = $src2

$newPipelineKeyForLocked = @'
std::string PerParticipantNdiRouter::pipelineKeyForLocked(const JitsiSourceInfo& source) const {
    std::string endpoint = source.endpointId.empty()
        ? (source.displayName.empty() ? source.sourceName : source.displayName)
        : source.endpointId;

    if (endpoint.empty()) {
        endpoint = source.displayName;
    }

    // v27: route each Jitsi video source into its own independent pipeline.
    // This prevents camera RTP and desktop-share RTP from sharing one AV1/VP8 assembler/decoder.
    if (source.media == "video") {
        if (!source.sourceName.empty()) {
            return source.sourceName;
        }

        const std::string videoType = toLower(source.videoType);
        if (!endpoint.empty() && !videoType.empty()) {
            return endpoint + "-" + videoType;
        }

        if (!endpoint.empty()) {
            return endpoint + "-video";
        }
    }

    // Audio belongs to the participant camera NDI source, not to the desktop-share source.
    // Normal Jitsi camera source name is endpoint-v0, so this matches the video pipeline key.
    if (source.media == "audio" && !endpoint.empty() && !isFallbackSsrcEndpoint(endpoint)) {
        return endpoint + "-v0";
    }

    // If audio has only an orphan SSRC key, attach it to the one already-created
    // non-fallback sender instead of making "JitsiNDI - ssrc-..." audio-only sources.
    if ((source.media == "audio" || endpoint.empty() || isFallbackSsrcEndpoint(endpoint)) && isFallbackSsrcEndpoint(endpoint)) {
        std::string stableKey;
        for (const auto& kv : pipelines_) {
            if (!isFallbackSsrcEndpoint(kv.first)) {
                if (!stableKey.empty()) {
                    return endpoint;
                }
                stableKey = kv.first;
            }
        }
        if (!stableKey.empty()) {
            return stableKey;
        }
    }

    return endpoint.empty() ? "unknown" : endpoint;
}
'@

$keyPattern = '(?s)std::string\s+PerParticipantNdiRouter::pipelineKeyForLocked\s*\(\s*const\s+JitsiSourceInfo&\s+source\s*\)\s+const\s*\{.*?\n\}\s*(?=\r?\nPerParticipantNdiRouter::ParticipantPipeline&\s+PerParticipantNdiRouter::pipelineForLocked)'
$src2 = [regex]::Replace($src, $keyPattern, $newPipelineKeyForLocked)
if ($src2 -eq $src) {
  Fail "Could not patch pipelineKeyForLocked. PerParticipantNdiRouter.cpp layout is different."
}
$src = $src2

# Improve RTP logs so camera/screen routing is visible in the console.
$oldLogPart = @'
                "PerParticipantNdiRouter: video RTP endpoint=",
                p.endpointId,
                " pt=",
'@
$newLogPart = @'
                "PerParticipantNdiRouter: video RTP endpoint=",
                p.endpointId,
                " source=",
                source->sourceName,
                " type=",
                source->videoType,
                " pt=",
'@
$src = $src.Replace($oldLogPart, $newLogPart)

Set-Content $router $src -Encoding UTF8
Write-Host "[v27] Patched PerParticipantNdiRouter.cpp: camera and screen-share are separate NDI pipelines."

Write-Host "[v27] Building Release..."
cmake --build build --config Release
if ($LASTEXITCODE -ne 0) { Fail "Build failed" }

$copyScript = Join-Path $root 'copy_runtime_dlls_v21.ps1'
if (Test-Path $copyScript) {
  Write-Host "[v27] Running existing runtime DLL copier..."
  powershell -ExecutionPolicy Bypass -File $copyScript
} else {
  $dst = Join-Path $root 'build\Release'
  if (Test-Path "$root\build\_deps\libdatachannel-build\Release\datachannel.dll") {
    Copy-Item "$root\build\_deps\libdatachannel-build\Release\datachannel.dll" $dst -Force
  }

  $vcpkgBins = @(
    "$env:VCPKG_ROOT\installed\x64-windows\bin",
    "D:\MEDIA\Desktop\vcpkg\installed\x64-windows\bin",
    "C:\vcpkg\installed\x64-windows\bin"
  ) | Where-Object { $_ -and (Test-Path $_) }

  foreach ($bin in $vcpkgBins) {
    Write-Host "[v27] Copying DLLs from $bin"
    Copy-Item "$bin\*.dll" $dst -Force -ErrorAction SilentlyContinue
  }

  $ndiDll = Get-ChildItem "C:\Program Files", "C:\Program Files (x86)" -Recurse -Filter "Processing.NDI.Lib.x64.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($ndiDll) { Copy-Item $ndiDll.FullName $dst -Force }
}

Write-Host ""
Write-Host "[v27] Done." -ForegroundColor Green
Write-Host "Run:"
Write-Host "  .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi"
Write-Host ""
Write-Host "Expected log checks:"
Write-Host "  1) created NDI participant source: JitsiNativeNDI - <endpoint>-v0 camera endpoint=<endpoint>-v0"
Write-Host "  2) created NDI participant source: JitsiNativeNDI - <endpoint>-v1 screen endpoint=<endpoint>-v1"
Write-Host "  3) video RTP endpoint=<endpoint>-v0 source=<endpoint>-v0 type=camera"
Write-Host "  4) video RTP endpoint=<endpoint>-v1 source=<endpoint>-v1 type=desktop"
Write-Host "  5) The screen-share NDI source should keep updating instead of freezing after the first frame."
