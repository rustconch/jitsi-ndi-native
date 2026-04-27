$ErrorActionPreference = 'Stop'

$root = (Get-Location).Path
$jitsi = Join-Path $root 'src\JitsiSignaling.cpp'
$jingle = Join-Path $root 'src\JingleSession.cpp'

if (!(Test-Path $jitsi)) { throw "Missing file: $jitsi" }
if (!(Test-Path $jingle)) { throw "Missing file: $jingle" }

$utf8 = New-Object System.Text.UTF8Encoding($false)
$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

Copy-Item $jitsi "$jitsi.bak_force_vp8_v17_$stamp" -Force
Copy-Item $jingle "$jingle.bak_force_vp8_v17_$stamp" -Force

# -----------------------------
# 1) JitsiSignaling.cpp
#    - advertise VP8+Opus only in MUC presence
#    - mutate parsed Jingle offer so all later SDP/session-accept builders see only VP8 for video
# -----------------------------
$src = [System.IO.File]::ReadAllText($jitsi)

# Clean previous malformed codec-list attempts too.
$src = $src -replace 'av1\s*,\s*vp8\s*,\s*opus', 'vp8,opus'
$src = $src -replace 'vp9\s*,\s*vp8\s*,\s*h264\s*,\s*opus', 'vp8,opus'
$src = $src -replace '<jitsi_participant_codecList>[^<"]*</jitsi_participant_codecList>(?:\s*vp8,opus)+', '<jitsi_participant_codecList>vp8,opus</jitsi_participant_codecList>'
$src = $src -replace '<jitsi_participant_codecList>[^<"]*</jitsi_participant_codecList>', '<jitsi_participant_codecList>vp8,opus</jitsi_participant_codecList>'

# Add includes needed by forceVp8Only().
if ($src -notmatch '#include\s+<algorithm>') {
    $src = [regex]::Replace($src, '(#include\s+"JitsiSignaling\.h"\s*)', '$1' + "`r`n#include <algorithm>`r`n#include <cctype>`r`n", 1)
}
if ($src -notmatch '#include\s+<cctype>') {
    $src = [regex]::Replace($src, '(#include\s+<algorithm>\s*)', '$1' + "#include <cctype>`r`n", 1)
}

$helper = @'

void forceVp8Only(JingleSession& session) {
    for (auto& content : session.contents) {
        const bool isVideo = (content.name == "video" || content.media == "video");
        if (!isVideo) {
            continue;
        }

        const std::size_t before = content.codecs.size();
        content.codecs.erase(
            std::remove_if(
                content.codecs.begin(),
                content.codecs.end(),
                [](const JingleCodec& codec) {
                    std::string name = codec.name;
                    std::transform(
                        name.begin(),
                        name.end(),
                        name.begin(),
                        [](unsigned char ch) { return static_cast<char>(std::tolower(ch)); }
                    );
                    return name != "vp8";
                }
            ),
            content.codecs.end()
        );

        if (before != content.codecs.size()) {
            Logger::info("JitsiSignaling: forced video codec negotiation to VP8 only; codecs left=", content.codecs.size());
        }
        if (content.codecs.empty()) {
            Logger::warn("JitsiSignaling: no VP8 codec remained in video content after filtering");
        }
    }
}
'@

if ($src -notmatch 'void\s+forceVp8Only\s*\(') {
    $src = [regex]::Replace($src, '\}\s*//\s*namespace', $helper + "`r`n} // namespace", 1)
}

if ($src -notmatch 'forceVp8Only\s*\(\s*session\s*\)') {
    $pattern = '(if\s*\(\s*!parseJingleSessionInitiate\s*\(\s*xml\s*,\s*session\s*\)\s*\)\s*\{[\s\S]*?return\s*;\s*\})'
    $newSrc = [regex]::Replace($src, $pattern, '$1' + "`r`n    forceVp8Only(session);", 1)
    if ($newSrc -eq $src) {
        throw 'Could not inject forceVp8Only(session) into JitsiSignaling.cpp'
    }
    $src = $newSrc
}

[System.IO.File]::WriteAllText($jitsi, $src, $utf8)

# -----------------------------
# 2) JingleSession.cpp
#    Safety net: all helper paths consider only VP8 as supported video.
# -----------------------------
$js = [System.IO.File]::ReadAllText($jingle)

$vp8Function = @'
bool isSupportedVideoCodec(const JingleCodec& codec) {
    // Force VP8. The current Windows FFmpeg build has no libdav1d and native AV1 fails.
    return toLower(codec.name) == "vp8";
}
'@

$oldJs = $js
$js = [regex]::Replace(
    $js,
    'bool\s+isSupportedVideoCodec\s*\(\s*const\s+JingleCodec&\s+codec\s*\)\s*\{[\s\S]*?\}',
    $vp8Function,
    1
)

# Remove AV1 from common ad-hoc checks if this file had previous experimental patches.
$js = $js -replace 'codecNameLower\s*!=\s*"av1"\s*&&\s*codecNameLower\s*!=\s*"vp8"', 'codecNameLower != "vp8"'
$js = $js -replace 'codecNameLower\s*==\s*"av1"\s*\|\|\s*codecNameLower\s*==\s*"vp8"', 'codecNameLower == "vp8"'
$js = $js -replace 'codecNameLower\s*==\s*"vp8"\s*\|\|\s*codecNameLower\s*==\s*"av1"', 'codecNameLower == "vp8"'

if ($js -eq $oldJs) {
    Write-Host 'Warning: JingleSession.cpp did not need changes or pattern was not found.'
}

[System.IO.File]::WriteAllText($jingle, $js, $utf8)

Write-Host 'v17 patch applied: forced VP8-only negotiation. Rebuild and run.'
Write-Host 'Expected session-accept video payload: VP8/100 only. Expected video RTP pt: 100, not 41.'
