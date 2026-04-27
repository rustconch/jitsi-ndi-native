$ErrorActionPreference = 'Stop'

function Fail($msg) {
  Write-Host "[v28][ERROR] $msg" -ForegroundColor Red
  exit 1
}

function Backup-File($path, $stamp) {
  if (Test-Path $path) {
    Copy-Item $path "$path.bak_v28_$stamp" -Force
    Write-Host "[v28] Backup: $path.bak_v28_$stamp"
  }
}

$root = (Get-Location).Path
Write-Host "[v28] Repository root: $root"

$router = Join-Path $root 'src\PerParticipantNdiRouter.cpp'
$sourceMapH = Join-Path $root 'src\JitsiSourceMap.h'
$sourceMapCpp = Join-Path $root 'src\JitsiSourceMap.cpp'

if (!(Test-Path $router)) { Fail "src\PerParticipantNdiRouter.cpp not found. Run this script from repository root." }
if (!(Test-Path $sourceMapH)) { Fail "src\JitsiSourceMap.h not found. Run this script from repository root." }
if (!(Test-Path $sourceMapCpp)) { Fail "src\JitsiSourceMap.cpp not found. Run this script from repository root." }

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
Backup-File $router $stamp
Backup-File $sourceMapH $stamp
Backup-File $sourceMapCpp $stamp

# -----------------------------------------------------------------------------
# JitsiSourceMap.h: add display-name cache API and storage.
# -----------------------------------------------------------------------------
$h = Get-Content $sourceMapH -Raw -Encoding UTF8

if ($h -notmatch 'updateDisplayNamesFromXml') {
  $h = $h.Replace(
    '    void removeFromJingleXml(const std::string& xml);',
    "    void removeFromJingleXml(const std::string& xml);`r`n    void updateDisplayNamesFromXml(const std::string& xml);"
  )
}

if ($h -notmatch 'displayNameByEndpoint_') {
  $h = $h.Replace(
    '    std::unordered_map<std::uint32_t, JitsiSourceInfo> bySsrc_;',
    "    std::unordered_map<std::uint32_t, JitsiSourceInfo> bySsrc_;`r`n    std::unordered_map<std::string, std::string> displayNameByEndpoint_;"
  )
}

Set-Content $sourceMapH $h -Encoding UTF8
Write-Host "[v28] Patched JitsiSourceMap.h"

# -----------------------------------------------------------------------------
# JitsiSourceMap.cpp: parse <nick>, cache endpoint -> displayName, preserve UTF-8.
# -----------------------------------------------------------------------------
$cpp = Get-Content $sourceMapCpp -Raw -Encoding UTF8

# Preserve non-ASCII/UTF-8 bytes in NDI names. The old sanitizer turned Cyrillic
# and many real names into underscores.
$cpp = $cpp.Replace(
  'if (!(std::isalnum(u) || c == ''-'' || c == ''_'' || c == '' '')) c = ''_'';',
  'if (!(std::isalnum(u) || u >= 0x80 || c == ''-'' || c == ''_'' || c == '' '')) c = ''_'';'
)

if ($cpp -notmatch 'sourceNamesFromSourceInfo') {
$helpers = @'

std::string tagText(const std::string& xml, const std::string& name) {
    const std::regex re("<" + name + R"((?:\s[^>]*)?>([\s\S]*?)</)" + name + R"(>)", std::regex::icase);
    std::smatch m;
    if (std::regex_search(xml, m, re) && m.size() > 1) {
        return xmlUnescape(m[1].str());
    }
    return {};
}

std::string trimCopy(std::string s) {
    auto notSpace = [](unsigned char c) { return !std::isspace(c); };
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), notSpace));
    s.erase(std::find_if(s.rbegin(), s.rend(), notSpace).base(), s.end());
    return s;
}

std::vector<std::string> sourceNamesFromSourceInfo(const std::string& xml) {
    std::vector<std::string> out;
    const std::string sourceInfo = xmlUnescape(tagText(xml, "SourceInfo"));
    if (sourceInfo.empty()) {
        return out;
    }

    const std::regex keyRe(R"("([^"]+)"\s*:)");
    for (auto it = std::sregex_iterator(sourceInfo.begin(), sourceInfo.end(), keyRe);
         it != std::sregex_iterator();
         ++it) {
        if ((*it).size() > 1) {
            out.push_back((*it)[1].str());
        }
    }

    return out;
}
'@
  $cpp = $cpp.Replace("`n} // namespace", $helpers + "`n} // namespace")
}

if ($cpp -notmatch 'JitsiSourceMap::updateDisplayNamesFromXml') {
$newMethod = @'

void JitsiSourceMap::updateDisplayNamesFromXml(const std::string& xml) {
    if (xml.find("<presence") == std::string::npos && xml.find("<message") == std::string::npos) {
        return;
    }

    std::string displayName = trimCopy(tagText(xml, "nick"));
    if (displayName.empty()) {
        displayName = trimCopy(tagText(xml, "display-name"));
    }

    if (displayName.empty()) {
        return;
    }

    displayName = sanitizeForNdiName(displayName);
    if (displayName.empty() || displayName == "unknown") {
        return;
    }

    const std::string presenceTag = firstTag(xml, "presence");
    std::string endpoint = resourceFromJid(attr(presenceTag, "from"));

    std::lock_guard<std::mutex> lock(mutex_);

    if (!endpoint.empty() && !isFallbackSsrcEndpoint(endpoint)) {
        displayNameByEndpoint_[endpoint] = displayName;
    }

    for (const auto& sourceName : sourceNamesFromSourceInfo(xml)) {
        const std::string sourceEndpoint = endpointFromSourceName(sourceName);
        if (!sourceEndpoint.empty() && !isFallbackSsrcEndpoint(sourceEndpoint)) {
            displayNameByEndpoint_[sourceEndpoint] = displayName;
        }
    }
}
'@
  $cpp = $cpp.Replace("`nvoid JitsiSourceMap::updateFromJingleXml", $newMethod + "`nvoid JitsiSourceMap::updateFromJingleXml")
}

$newUpdateFromJingle = @'
void JitsiSourceMap::updateFromJingleXml(const std::string& xml) {
    updateDisplayNamesFromXml(xml);

    const auto sources = parseSources(xml);
    if (sources.empty()) return;

    std::lock_guard<std::mutex> lock(mutex_);
    for (auto s : sources) {
        const auto it = displayNameByEndpoint_.find(s.endpointId);
        if (it != displayNameByEndpoint_.end() && !it->second.empty()) {
            s.displayName = it->second;
        }
        bySsrc_[s.ssrc] = std::move(s);
    }
}
'@
$updatePattern = '(?s)void\s+JitsiSourceMap::updateFromJingleXml\s*\(\s*const\s+std::string&\s+xml\s*\)\s*\{.*?\n\}\s*(?=\r?\nvoid\s+JitsiSourceMap::removeFromJingleXml)'
$cpp2 = [regex]::Replace($cpp, $updatePattern, $newUpdateFromJingle)
if ($cpp2 -eq $cpp) {
  Fail "Could not patch JitsiSourceMap::updateFromJingleXml. File layout is different."
}
$cpp = $cpp2

Set-Content $sourceMapCpp $cpp -Encoding UTF8
Write-Host "[v28] Patched JitsiSourceMap.cpp"

# -----------------------------------------------------------------------------
# PerParticipantNdiRouter.cpp: update display names from presence and use names in NDI labels.
# Routing keys remain technical source names endpoint-v0 / endpoint-v1.
# -----------------------------------------------------------------------------
$r = Get-Content $router -Raw -Encoding UTF8

$oldReturnNoSource = @'
    if (xml.find("<source") == std::string::npos) {
        return;
    }

    sourceMap_.updateFromJingleXml(xml);
'@
$newReturnNoSource = @'
    sourceMap_.updateDisplayNamesFromXml(xml);

    if (xml.find("<source") == std::string::npos) {
        return;
    }

    sourceMap_.updateFromJingleXml(xml);
'@
if ($r.Contains($oldReturnNoSource) -and $r -notmatch 'updateDisplayNamesFromXml\(xml\)') {
  $r = $r.Replace($oldReturnNoSource, $newReturnNoSource)
} elseif ($r -notmatch 'updateDisplayNamesFromXml\(xml\)') {
  Fail "Could not add display-name update call to PerParticipantNdiRouter::updateSourcesFromJingleXml."
}

$newSourceNameFor = @'
std::string PerParticipantNdiRouter::sourceNameFor(const JitsiSourceInfo& source) const {
    std::string label;

    const std::string endpoint = source.endpointId.empty()
        ? (source.displayName.empty() ? source.sourceName : source.displayName)
        : source.endpointId;

    const std::string videoType = toLower(source.videoType);

    std::string humanName = source.displayName;
    if (humanName.empty() || humanName == endpoint || isFallbackSsrcEndpoint(humanName)) {
        humanName = endpoint;
    }
    if (humanName.empty()) {
        humanName = !source.sourceName.empty() ? source.sourceName : "unknown";
    }

    if (source.media == "video") {
        // v28: NDI display name uses the participant nick/name, while the internal
        // pipeline key still remains the stable Jitsi source name, e.g. endpoint-v0/v1.
        label = humanName;

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
        // Audio is attached to the camera pipeline; if it creates the pipeline first,
        // it must get the same human-readable NDI source name as the later camera video.
        label = humanName + " camera";
    } else {
        label = humanName;
    }

    const std::string safe = JitsiSourceMap::sanitizeForNdiName(label);
    return ndiBaseName_ + " - " + safe;
}
'@
$sourceNamePattern = '(?s)std::string\s+PerParticipantNdiRouter::sourceNameFor\s*\(\s*const\s+JitsiSourceInfo&\s+source\s*\)\s+const\s*\{.*?\n\}\s*(?=\r?\nstd::string\s+PerParticipantNdiRouter::pipelineKeyForLocked)'
$r2 = [regex]::Replace($r, $sourceNamePattern, $newSourceNameFor)
if ($r2 -eq $r) {
  Fail "Could not patch PerParticipantNdiRouter::sourceNameFor. File layout is different."
}
$r = $r2

Set-Content $router $r -Encoding UTF8
Write-Host "[v28] Patched PerParticipantNdiRouter.cpp"

Write-Host "[v28] Building Release..."
cmake --build build --config Release
if ($LASTEXITCODE -ne 0) { Fail "Build failed" }

$copyScript = Join-Path $root 'copy_runtime_dlls_v21.ps1'
if (Test-Path $copyScript) {
  Write-Host "[v28] Running existing runtime DLL copier..."
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
    Write-Host "[v28] Copying DLLs from $bin"
    Copy-Item "$bin\*.dll" $dst -Force -ErrorAction SilentlyContinue
  }

  $ndiDll = Get-ChildItem "C:\Program Files", "C:\Program Files (x86)" -Recurse -Filter "Processing.NDI.Lib.x64.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($ndiDll) { Copy-Item $ndiDll.FullName $dst -Force }
}

Write-Host ""
Write-Host "[v28] Done." -ForegroundColor Green
Write-Host "Run:"
Write-Host "  .\build\Release\jitsi-ndi-native.exe --room 6767676766767penxyi"
Write-Host ""
Write-Host "Expected NDI names:"
Write-Host "  JitsiNativeNDI - ntcn camera"
Write-Host "  JitsiNativeNDI - ntcn screen"
Write-Host "  JitsiNativeNDI - vsdvsdvsdv camera"
Write-Host ""
Write-Host "Technical routing keys should still look like endpoint-v0 / endpoint-v1 in logs; that is correct."
