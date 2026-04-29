$ErrorActionPreference = "Stop"

function Find-ProjectRoot {
    $candidates = @((Get-Location).Path, (Split-Path -Parent $PSScriptRoot), (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
    foreach ($c in $candidates) {
        if (-not $c) { continue }
        $p = (Resolve-Path -LiteralPath $c -ErrorAction SilentlyContinue)
        if (-not $p) { continue }
        $s = $p.ProviderPath
        if ((Test-Path -LiteralPath (Join-Path $s "CMakeLists.txt")) -and (Test-Path -LiteralPath (Join-Path $s "src\JitsiSignaling.cpp"))) {
            return $s
        }
    }
    $d = New-Object System.IO.DirectoryInfo((Get-Location).Path)
    while ($d -ne $null) {
        if ((Test-Path -LiteralPath (Join-Path $d.FullName "CMakeLists.txt")) -and (Test-Path -LiteralPath (Join-Path $d.FullName "src\JitsiSignaling.cpp"))) {
            return $d.FullName
        }
        $d = $d.Parent
    }
    throw "Project root not found. Run this from jitsi-ndi-native root."
}

function Read-Utf8NoBom($path) {
    return [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
}

function Write-Utf8NoBom($path, $text) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($path, $text, $enc)
}

function Replace-Once($text, $pattern, $replacement, $label) {
    $matches = [regex]::Matches($text, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($matches.Count -ne 1) {
        throw "Patch anchor failed for $label. Matches: $($matches.Count)"
    }
    return [regex]::Replace($text, $pattern, $replacement, [System.Text.RegularExpressions.RegexOptions]::Singleline)
}

$root = Find-ProjectRoot
$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$backupDir = Join-Path $root ("backup_turn_udp_stability_v76_" + $stamp)
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$signalPath = Join-Path $root "src\JitsiSignaling.cpp"
$answererPath = Join-Path $root "src\NativeWebRTCAnswerer.cpp"
Copy-Item -Force $signalPath (Join-Path $backupDir "JitsiSignaling.cpp")
Copy-Item -Force $answererPath (Join-Path $backupDir "NativeWebRTCAnswerer.cpp")

$signal = Read-Utf8NoBom $signalPath
$answerer = Read-Utf8NoBom $answererPath

if ($signal -notmatch "percentEncodeTurnUserInfo") {
$helpers = @'

bool isTurnUserInfoUnreserved(unsigned char c) {
    return (c >= 'A' && c <= 'Z')
        || (c >= 'a' && c <= 'z')
        || (c >= '0' && c <= '9')
        || c == '-'
        || c == '_'
        || c == '.'
        || c == '~';
}

std::string percentEncodeTurnUserInfo(const std::string& value) {
    static const char* hex = "0123456789ABCDEF";
    std::string out;
    out.reserve(value.size());

    for (unsigned char c : value) {
        if (isTurnUserInfoUnreserved(c)) {
            out.push_back(static_cast<char>(c));
            continue;
        }

        out.push_back('%');
        out.push_back(hex[(c >> 4) & 0x0F]);
        out.push_back(hex[c & 0x0F]);
    }

    return out;
}
'@
    $replacement = "std::string xmlBool(bool value) {`r`n    return value ? `"true`" : `"false`";`r`n}`r`n" + $helpers + "`r`n"
    $signal = Replace-Once $signal "std::string xmlBool\(bool value\) \{\s*return value \? `"true`" : `"false`";\s*\}\s*" $replacement "insert TURN URI helpers"
}

$newHandleRoomMetadata = @'
void JitsiSignaling::handleRoomMetadata(const std::string& xml) {
    if (!contains(xml, "room_metadata") || !contains(xml, "services")) {
        return;
    }

    const std::string decoded = jsonUnescape(xml);

    std::vector<NativeWebRTCAnswerer::IceServer> servers;

    const std::string username = extractJsonString(decoded, "username");
    const std::string password = extractJsonString(decoded, "password");

    bool turnUdpAdded = false;

    if (
        contains(decoded, "meet-jit-si-turnrelay.jitsi.net")
        && contains(decoded, "\"type\":\"turn\"")
        && contains(decoded, "\"transport\":\"udp\"")
        && !username.empty()
        && !password.empty()
    ) {
        NativeWebRTCAnswerer::IceServer turnServer;
        turnServer.uri = "turn:"
            + percentEncodeTurnUserInfo(username)
            + ":"
            + percentEncodeTurnUserInfo(password)
            + "@meet-jit-si-turnrelay.jitsi.net:443?transport=udp";
        servers.push_back(turnServer);
        turnUdpAdded = true;

        Logger::info("Jitsi TURN/UDP metadata parsed and passed to libdatachannel");
    }

    if (contains(decoded, "meet-jit-si-turnrelay.jitsi.net")) {
        NativeWebRTCAnswerer::IceServer stunServer;
        stunServer.uri = "stun:meet-jit-si-turnrelay.jitsi.net:443";
        servers.push_back(stunServer);
    }

    if (!servers.empty()) {
        answerer_.setIceServers(servers);

        Logger::info("Jitsi ICE metadata parsed. ICE servers count=", servers.size());

        for (const auto& server : servers) {
            if (server.uri.find("turn:") == 0) {
                Logger::info("Jitsi ICE server: turn:***@meet-jit-si-turnrelay.jitsi.net:443?transport=udp");
            } else {
                Logger::info("Jitsi ICE server: ", server.uri);
            }
        }
    }

    if (contains(decoded, "\"type\":\"turns\"")) {
        Logger::warn("Jitsi TURNS service skipped because libjuice backend does not support TURN/TLS");
    }

    if (!turnUdpAdded && !username.empty() && !password.empty()) {
        Logger::warn("Jitsi TURN credentials present but TURN/UDP server was not added; using STUN fallback only");
    }
}
'@

$signal = Replace-Once $signal "void JitsiSignaling::handleRoomMetadata\(const std::string& xml\) \{.*?\r?\n\}\s*\r?\nvoid JitsiSignaling::handleJingleInitiate" ($newHandleRoomMetadata + "`r`n`r`nvoid JitsiSignaling::handleJingleInitiate") "replace handleRoomMetadata"

if ($answerer -notmatch "v76: WebRTC PeerConnection failed/closed") {
$newState = @'
pc->onStateChange([](rtc::PeerConnection::State state) {
        const int numericState = static_cast<int>(state);
        Logger::info("NativeWebRTCAnswerer: PeerConnection state=", numericState);

        if (numericState == 4 || numericState == 5) {
            Logger::warn("NativeWebRTCAnswerer: v76: WebRTC PeerConnection failed/closed; RTP will stop until the Jitsi session reconnects");
        }
    });
'@
    $answerer = Replace-Once $answerer "pc->onStateChange\(\[\]\(rtc::PeerConnection::State state\) \{\s*Logger::info\(""NativeWebRTCAnswerer: PeerConnection state="", static_cast<int>\(state\)\);\s*\}\);" $newState "replace PeerConnection state logger"
}

Write-Utf8NoBom $signalPath $signal
Write-Utf8NoBom $answererPath $answerer

Write-Host "[v76] Applied TURN/UDP stability patch. Backup: $backupDir"
Write-Host "[v76] Now rebuild: .\rebuild_with_dav1d_v21.ps1"
