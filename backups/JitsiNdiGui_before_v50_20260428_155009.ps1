# Jitsi NDI Native - safe visual monitoring GUI launcher v39
# Place this file in D:\MEDIA\Desktop\jitsi-ndi-native and run:
# powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:proc = $null
$script:rowsByKey = @{}
$script:dominantEndpoint = ""
$script:repoRoot = $PSScriptRoot
$script:logLines = New-Object System.Collections.Generic.List[string]
$script:eventSubscribers = @()
$script:runId = 0
$script:isStopping = $false
$script:selectedExePath = $null
$script:logDir = Join-Path $script:repoRoot "logs"
$script:currentLogFile = $null
$script:lastLaunchPreview = ""
$script:lastQualityRequest = "—"
$script:lastVideoFrameAt = "—"

function Convert-JitsiInputToRoom {
    param([string]$InputText)

    $s = ($InputText | ForEach-Object { "$_" }).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Accept raw room name, full https://meet.jit.si/room link, and MUC jid.
    if ($s -match "@conference\.") {
        return ($s -replace "@conference\..*$", "").Trim()
    }

    if ($s -match "^https?://") {
        try {
            $uri = [System.Uri]$s
            $path = [System.Uri]::UnescapeDataString($uri.AbsolutePath.Trim("/"))
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                return ($path.Split("/")[0]).Trim()
            }
        } catch {
            return $s
        }
    }

    # Accept meet.jit.si/room without protocol.
    if ($s -match "^[^/]+\.[^/]+/(.+)$") {
        $part = $Matches[1].Split("?")[0].Split("#")[0].Trim("/")
        if ($part) { return [System.Uri]::UnescapeDataString($part.Split("/")[0]) }
    }

    return ($s.Split("?")[0].Split("#")[0].Trim("/"))
}

function Get-SourceKind {
    param([string]$sourceKey, [string]$sourceName)

    if ($sourceKey -match "-v1$" -or $sourceName -match "(?i)(screen|desktop|демонстр|share)") {
        return "screen"
    }
    if ($sourceKey -match "-v\d+$") {
        return "camera"
    }
    if ($sourceKey -match "-a\d+$") {
        return "audio"
    }
    return "video"
}

function Sanitize-Name {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }
    $x = $s.Trim()
    $x = $x -replace "[\\/:*?`"<>|]", "_"
    if ($x.Length -gt 64) { $x = $x.Substring(0,64) }
    return $x
}


function Set-TextSafe {
    param([object]$Control, [string]$Text)
    if ($Control -and -not $Control.IsDisposed) {
        $Control.Text = $Text
    }
}

function Get-ResolutionClass {
    param([string]$Resolution)
    if ([string]::IsNullOrWhiteSpace($Resolution)) { return "unknown" }
    if ($Resolution -match "(\d+)x(\d+)") {
        $h = [int]$Matches[2]
        if ($h -ge 1000) { return "1080p" }
        if ($h -ge 700) { return "720p" }
        if ($h -gt 0) { return "<=540p" }
    }
    return "unknown"
}

function Find-RowByNdiDisplayName {
    param([string]$displayName)
    if ([string]::IsNullOrWhiteSpace($displayName)) { return $null }

    foreach ($key in @($script:rowsByKey.Keys)) {
        $row = $script:rowsByKey[$key]
        $name = $row.Cells["Name"].Value -as [string]
        if ($name -eq $displayName) { return $row }
    }

    return $null
}

function Update-StatsBar {
    if (-not $grid -or $grid.IsDisposed) { return }
    if ($grid.InvokeRequired) {
        try { [void]$grid.BeginInvoke([System.Action]{ Update-StatsBar }) } catch {}
        return
    }

    $sources = 0
    $cameras = 0
    $screens = 0
    $audio = 0
    $video = 0
    $r1080 = 0
    $r720 = 0
    $r540 = 0
    $rUnknown = 0

    foreach ($row in $grid.Rows) {
        if ($row.IsNewRow) { continue }
        $sources++
        $kind = ($row.Cells["Kind"].Value -as [string])
        if ($kind -eq "camera") { $cameras++ }
        elseif ($kind -eq "screen") { $screens++ }
        elseif ($kind -eq "audio") { $audio++ }
        elseif ($kind) { $video++ }

        $res = ($row.Cells["Resolution"].Value -as [string])
        $cls = Get-ResolutionClass $res
        if ($cls -eq "1080p") { $r1080++ }
        elseif ($cls -eq "720p") { $r720++ }
        elseif ($cls -eq "<=540p") { $r540++ }
        else { $rUnknown++ }
    }

    Set-TextSafe $lblSourceStats ("Источники: {0} | камеры: {1} | экраны: {2}" -f $sources, $cameras, $screens)
    Set-TextSafe $lblResolutionStats ("Разрешения: 1080p {0} | 720p {1} | <=540p {2} | ? {3}" -f $r1080, $r720, $r540, $rUnknown)
}

function Update-RoomPreview {
    if (-not $lblRoomPreview -or $lblRoomPreview.IsDisposed) { return }
    $room = Convert-JitsiInputToRoom $txtRoom.Text
    if ([string]::IsNullOrWhiteSpace($room)) {
        $lblRoomPreview.Text = "Room: —"
    } else {
        $lblRoomPreview.Text = "Room: " + $room
    }
}

function Copy-TextToClipboard {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText($Text)
        Append-Log ("[GUI] Copied to clipboard: " + $Text)
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Clipboard copy failed.`n" + $_.Exception.Message, "Jitsi NDI GUI") | Out-Null
    }
}

function Get-SelectedGridValue {
    param([string]$ColumnName)
    if (-not $grid -or $grid.IsDisposed -or $grid.SelectedRows.Count -lt 1) { return "" }
    try { return [string]$grid.SelectedRows[0].Cells[$ColumnName].Value } catch { return "" }
}

function Build-LaunchPreview {
    $exePath = $script:selectedExePath
    if ([string]::IsNullOrWhiteSpace($exePath)) { $exePath = Find-NativeExe }

    $room = Convert-JitsiInputToRoom $txtRoom.Text
    if ([string]::IsNullOrWhiteSpace($room)) { $room = "<room>" }

    $args = New-Object System.Collections.Generic.List[string]
    $args.Add("--room")
    $args.Add($room)

    # v39 safety rule: do not pass --nick from GUI.
    # In the current native build --nick can change the MUC join resource and may break media/NDI.
    # The text box is kept for the next native-side display-name fix, but launch stays --room-only.

    $preview = (Quote-CliArg $exePath) + " " + (Join-CliArgs $args)
    $script:lastLaunchPreview = $preview
    return $preview
}

function Append-Log {
    param([string]$line)
    if ($null -eq $line) { return }

    if ($txtLog -and -not $txtLog.IsDisposed -and $txtLog.InvokeRequired) {
        $safeLine = [string]$line
        try {
            [void]$txtLog.BeginInvoke([System.Action]{ Append-Log $safeLine })
        } catch {
            # UI is probably closing; ignore late log callbacks.
        }
        return
    }

    if ($script:currentLogFile) {
        try {
            $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff")
            Add-Content -LiteralPath $script:currentLogFile -Value ("{0} {1}" -f $stamp, $line) -Encoding UTF8
        } catch {
            # Logging to file is helpful, but should never break the receiver.
        }
    }

    $script:logLines.Add($line)
    while ($script:logLines.Count -gt 1200) {
        $script:logLines.RemoveAt(0)
    }

    if (-not $txtLog -or $txtLog.IsDisposed) { return }

    $txtLog.AppendText($line + [Environment]::NewLine)
    if ($txtLog.Lines.Count -gt 1200) {
        $txtLog.Lines = $txtLog.Lines | Select-Object -Last 1000
        $txtLog.SelectionStart = $txtLog.Text.Length
        $txtLog.ScrollToCaret()
    }
}

function Ensure-Row {
    param(
        [string]$key,
        [string]$endpoint,
        [string]$displayName,
        [string]$kind
    )

    if ([string]::IsNullOrWhiteSpace($key)) { return $null }

    if ($grid.InvokeRequired) {
        $k = [string]$key
        $e = [string]$endpoint
        $d = [string]$displayName
        $kind2 = [string]$kind
        return $grid.Invoke([System.Func[object]]{
            return Ensure-Row -key $k -endpoint $e -displayName $d -kind $kind2
        })
    }

    if ($script:rowsByKey.ContainsKey($key)) {
        $row = $script:rowsByKey[$key]
    } else {
        $idx = $grid.Rows.Add()
        $row = $grid.Rows[$idx]
        $script:rowsByKey[$key] = $row
        $row.Cells["Key"].Value = $key
    }

    if ($endpoint) { $row.Cells["Endpoint"].Value = $endpoint }
    if ($displayName) { $row.Cells["Name"].Value = $displayName }
    if ($kind) { $row.Cells["Kind"].Value = $kind }
    $row.Cells["Updated"].Value = (Get-Date).ToString("HH:mm:ss")

    Update-StatsBar
    return $row
}

function Update-EndpointRows {
    param(
        [string]$endpoint,
        [object]$stats
    )

    if ([string]::IsNullOrWhiteSpace($endpoint)) { return }

    if ($grid.InvokeRequired) {
        $e = [string]$endpoint
        $s = $stats
        try {
            [void]$grid.BeginInvoke([System.Action]{ Update-EndpointRows -endpoint $e -stats $s })
        } catch {
            # UI is probably closing; ignore late callbacks.
        }
        return
    }

    $matched = $false
    foreach ($key in @($script:rowsByKey.Keys)) {
        $row = $script:rowsByKey[$key]
        if (($row.Cells["Endpoint"].Value -as [string]) -eq $endpoint -or $key -like "$endpoint*") {
            $matched = $true
            if ($stats.bitrate) {
                $row.Cells["Down"].Value = [string]$stats.bitrate.download
                $row.Cells["Up"].Value = [string]$stats.bitrate.upload
                if ($stats.bitrate.video) {
                    $row.Cells["VideoDown"].Value = [string]$stats.bitrate.video.download
                    $row.Cells["VideoUp"].Value = [string]$stats.bitrate.video.upload
                }
            }
            if ($null -ne $stats.connectionQuality) {
                $row.Cells["Quality"].Value = ("{0:N0}%" -f [double]$stats.connectionQuality)
            }
            if ($null -ne $stats.jvbRTT) { $row.Cells["RTT"].Value = "$($stats.jvbRTT) ms" }
            if ($stats.packetLoss -and $null -ne $stats.packetLoss.download) {
                $row.Cells["Loss"].Value = "$($stats.packetLoss.download)"
            }
            if ($null -ne $stats.maxEnabledResolution) {
                $row.Cells["MaxRes"].Value = "$($stats.maxEnabledResolution)p"
            }
            $row.Cells["Updated"].Value = (Get-Date).ToString("HH:mm:ss")
        }
    }

    if (-not $matched) {
        $row = Ensure-Row -key $endpoint -endpoint $endpoint -displayName "" -kind "endpoint"
        if ($stats.connectionQuality) { $row.Cells["Quality"].Value = ("{0:N0}%" -f [double]$stats.connectionQuality) }
        if ($stats.jvbRTT) { $row.Cells["RTT"].Value = "$($stats.jvbRTT) ms" }
    }

    Update-StatsBar
}

function Parse-Line {
    param([string]$line)

    if ([string]::IsNullOrWhiteSpace($line)) { return }

    if ($line -match "ReceiverVideoConstraints|requesting .*1080p|LastN/unlimited") {
        if ($line -match "all-on-stage") { $script:lastQualityRequest = "all-on-stage 1080p" }
        elseif ($line -match "equal-priority") { $script:lastQualityRequest = "equal-priority 1080p" }
        elseif ($line -match "1080p") { $script:lastQualityRequest = "1080p requested" }
        elseif ($line -match "LastN/unlimited") { $script:lastQualityRequest = "LastN unlimited" }
        Set-TextSafe $lblQualityRequest ("Quality request: " + $script:lastQualityRequest)
    }

    # NDI source created
    if ($line -match "created NDI participant source:\s*(.+?)\s+endpoint=([A-Za-z0-9_-]+)") {
        $sourceName = $Matches[1].Trim()
        $endpoint = $Matches[2].Trim()
        $displayName = $sourceName -replace "^JitsiNativeNDI\s*-\s*", ""
        $displayName = $displayName.Trim()
        $kind = Get-SourceKind -sourceKey $endpoint -sourceName $sourceName
        Ensure-Row -key $endpoint -endpoint $endpoint -displayName $displayName -kind $kind | Out-Null
        return
    }

    # NDI frame sent: source name + resolution
    if ($line -match "NDI video frame sent:\s*(.+?)\s+(\d+)x(\d+)") {
        $sourceName = $Matches[1].Trim()
        $w = $Matches[2]
        $h = $Matches[3]
        $displayName = $sourceName -replace "^JitsiNativeNDI\s*-\s*", ""
        $displayName = $displayName.Trim()

        $row = Find-RowByNdiDisplayName $displayName
        if (-not $row) {
            $key = $displayName
            if ($displayName -match "([A-Za-z0-9]{6,})(?:-|$)") { $key = $Matches[1] }
            $kind = Get-SourceKind -sourceKey $key -sourceName $sourceName
            $row = Ensure-Row -key $key -endpoint $key -displayName $displayName -kind $kind
        }
        if ($row) {
            $row.Cells["Resolution"].Value = "${w}x${h}"
            $row.Cells["Updated"].Value = (Get-Date).ToString("HH:mm:ss")
            $script:lastVideoFrameAt = (Get-Date).ToString("HH:mm:ss")
            Set-TextSafe $lblLastFrame ("Последний NDI кадр: " + $script:lastVideoFrameAt)
            Update-StatsBar
        }
        return
    }

    # Raw video source lines include source key and ssrc; useful for screen/camera split.
    if ($line -match "video RTP endpoint=([A-Za-z0-9_-]+).*ssrc=(\d+)") {
        $endpoint = $Matches[1]
        Ensure-Row -key $endpoint -endpoint $endpoint -displayName "" -kind (Get-SourceKind -sourceKey $endpoint -sourceName "") | Out-Null
        return
    }

    # JSON messages from JVB.
    if ($line -match "bridge datachannel text:\s*(\{.*\})") {
        try {
            $json = $Matches[1] | ConvertFrom-Json -ErrorAction Stop
            if ($json.colibriClass -eq "EndpointStats") {
                Update-EndpointRows -endpoint $json.from -stats $json
            } elseif ($json.colibriClass -eq "ForwardedSources") {
                foreach ($src in $json.forwardedSources) {
                    $endpoint = ($src -replace "-v\d+$","")
                    $kind = Get-SourceKind -sourceKey $src -sourceName ""
                    Ensure-Row -key $src -endpoint $endpoint -displayName "" -kind $kind | Out-Null
                }
            } elseif ($json.colibriClass -eq "DominantSpeakerEndpointChangeEvent") {
                $script:dominantEndpoint = [string]$json.dominantSpeakerEndpoint
                if (-not [string]::IsNullOrWhiteSpace($script:dominantEndpoint)) {
                    $lblDominant.Text = "Активный спикер: $script:dominantEndpoint"
                }
            } elseif ($json.colibriClass -eq "ConnectionStats") {
                if ($null -ne $json.estimatedDownlinkBandwidth) {
                    $lblBandwidth.Text = "Downlink estimate: $($json.estimatedDownlinkBandwidth) bps"
                }
            }
        } catch {
            # Ignore malformed/transient JSON.
        }
        return
    }

    # Display source map logs, if native app has name mapping logs.
    if ($line -match "SourceInfo.*&quot;([^&]+)&quot;") {
        # SourceInfo is usually already handled by native; keep raw log.
        return
    }
}


function Quote-CliArg {
    param([string]$Arg)

    if ($null -eq $Arg) { return '""' }
    $s = [string]$Arg

    if ($s.Length -eq 0) { return '""' }

    # Windows command-line quoting compatible with CreateProcess/CommandLineToArgvW.
    if ($s -notmatch '[\s"]') { return $s }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0

    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq '\') {
            $bs++
            continue
        }

        if ($ch -eq '"') {
            [void]$sb.Append(('\' * ($bs * 2 + 1)))
            [void]$sb.Append('"')
            $bs = 0
            continue
        }

        if ($bs -gt 0) {
            [void]$sb.Append(('\' * $bs))
            $bs = 0
        }

        [void]$sb.Append($ch)
    }

    if ($bs -gt 0) {
        [void]$sb.Append(('\' * ($bs * 2)))
    }

    [void]$sb.Append('"')
    return $sb.ToString()
}

function Join-CliArgs {
    param([System.Collections.Generic.List[string]]$ArgsList)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($a in $ArgsList) {
        $parts.Add((Quote-CliArg $a))
    }

    return ($parts -join " ")
}




function Find-NativeExe {
    $candidates = @(
        (Join-Path $PSScriptRoot "build\Release\jitsi-ndi-native.exe"),
        (Join-Path $PSScriptRoot "build-ndi\Release\jitsi-ndi-native.exe"),
        (Join-Path $PSScriptRoot "build\RelWithDebInfo\jitsi-ndi-native.exe"),
        (Join-Path $PSScriptRoot "build-ndi\RelWithDebInfo\jitsi-ndi-native.exe"),
        (Join-Path $PSScriptRoot "jitsi-ndi-native.exe")
    )

    foreach ($p in $candidates) {
        if (Test-Path $p) { return $p }
    }

    return (Join-Path $PSScriptRoot "build\Release\jitsi-ndi-native.exe")
}

function Set-ExePath {
    param([string]$Path)

    $script:selectedExePath = $Path

    if ($lblExe -and -not $lblExe.IsDisposed) {
        if ([string]::IsNullOrWhiteSpace($Path)) {
            $lblExe.Text = "не выбран"
        } elseif (Test-Path $Path) {
            $lblExe.Text = "выбран: " + (Split-Path $Path -Leaf)
        } else {
            $lblExe.Text = "не найден: " + (Split-Path $Path -Leaf)
        }
    }
}

function Start-SessionLog {
    try {
        if (-not (Test-Path $script:logDir)) {
            [void](New-Item -ItemType Directory -Path $script:logDir -Force)
        }
        $name = "jitsi-ndi-gui_{0}.log" -f (Get-Date).ToString("yyyyMMdd_HHmmss")
        $script:currentLogFile = Join-Path $script:logDir $name
        "# Jitsi NDI GUI session log" | Set-Content -LiteralPath $script:currentLogFile -Encoding UTF8
        "# Started: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))" | Add-Content -LiteralPath $script:currentLogFile -Encoding UTF8
    } catch {
        $script:currentLogFile = $null
    }
}

function Open-LogFolder {
    try {
        if (-not (Test-Path $script:logDir)) {
            [void](New-Item -ItemType Directory -Path $script:logDir -Force)
        }
        Start-Process explorer.exe $script:logDir
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Не удалось открыть папку логов.`n" + $_.Exception.Message, "Jitsi NDI GUI") | Out-Null
    }
}


function Open-CurrentLogFile {
    try {
        if ($script:currentLogFile -and (Test-Path $script:currentLogFile)) {
            Start-Process notepad.exe $script:currentLogFile
        } else {
            Open-LogFolder
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not open current log.`n" + $_.Exception.Message, "Jitsi NDI GUI") | Out-Null
    }
}

function Clear-VisibleLog {
    try {
        $txtLog.Clear()
        $script:logLines.Clear()
        Append-Log "[GUI] Visible log cleared. File log is not deleted."
    } catch {}
}

function Set-UiRunning {
    param([bool]$Running)

    foreach ($ctrl in @($txtRoom, $txtNick, $chkNickOnStart, $btnBrowse)) {
        if ($ctrl -and -not $ctrl.IsDisposed) { $ctrl.Enabled = (-not $Running) }
    }

    if ($btnStart -and -not $btnStart.IsDisposed) { $btnStart.Enabled = (-not $Running) }
    if ($btnStop -and -not $btnStop.IsDisposed) { $btnStop.Enabled = $Running }
    if ($lblState -and -not $lblState.IsDisposed) {
        if ($Running) { $lblState.Text = "Запущен" } else { $lblState.Text = "Остановлен" }
    }
}

function Clear-ProcessEvents {
    foreach ($sub in @($script:eventSubscribers)) {
        try {
            Unregister-Event -SubscriptionId $sub.SubscriptionId -ErrorAction SilentlyContinue
        } catch {}
        try {
            if ($sub.Action) {
                Remove-Job -Id $sub.Action.Id -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
    $script:eventSubscribers = @()
}

function Invoke-UiSafe {
    param([scriptblock]$Block)

    if (-not $form -or $form.IsDisposed -or -not $form.IsHandleCreated) { return }

    try {
        if ($form.InvokeRequired) {
            [void]$form.BeginInvoke([System.Action]$Block)
        } else {
            & $Block
        }
    } catch {
        # Form is closing or callback arrived after Stop; ignore safely.
    }
}

function Start-Receiver {
    Clear-ProcessEvents
    $script:runId++
    $script:isStopping = $false

    if ($script:proc -and -not $script:proc.HasExited) {
        [System.Windows.Forms.MessageBox]::Show("Приёмник уже запущен.", "Jitsi NDI GUI") | Out-Null
        return
    }

    $exePath = $script:selectedExePath
    if ([string]::IsNullOrWhiteSpace($exePath)) {
        $exePath = Find-NativeExe
        Set-ExePath $exePath
    }

    if (-not (Test-Path $exePath)) {
        [System.Windows.Forms.MessageBox]::Show("Не найден jitsi-ndi-native.exe. Нажми Exe... и выбери рабочий exe из твоей сборки.", "Jitsi NDI GUI") | Out-Null
        return
    }

    $room = Convert-JitsiInputToRoom $txtRoom.Text
    if ([string]::IsNullOrWhiteSpace($room)) {
        [System.Windows.Forms.MessageBox]::Show("Вставь ссылку Jitsi или имя комнаты.", "Jitsi NDI GUI") | Out-Null
        return
    }

    $args = New-Object System.Collections.Generic.List[string]
    $args.Add("--room")
    $args.Add($room)

    # Keep the native/WebRTC/NDI path as close to the working build as possible.
    # Do NOT pass --quality/--width/--height/--ndi-name here.
    # v39 safety rule: do NOT pass --nick from GUI either, because this build may break MUC/media routing when nick changes.

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exePath
    $psi.WorkingDirectory = Split-Path $exePath -Parent
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    # Windows PowerShell 5.1 / .NET Framework safe path:
    # ProcessStartInfo.ArgumentList may be unavailable or NULL, so use Arguments.
    $psi.Arguments = Join-CliArgs $args

    $script:rowsByKey.Clear()
    $grid.Rows.Clear()
    Update-StatsBar
    Set-TextSafe $lblLastFrame "Последний NDI кадр: —"
    Set-TextSafe $lblQualityRequest "Quality request: —"
    $txtLog.Clear()
    Start-SessionLog
    $script:lastLaunchPreview = (Quote-CliArg $psi.FileName) + " " + $psi.Arguments
    Append-Log ("[GUI] Starting: " + $psi.FileName + " " + $psi.Arguments)
    Append-Log ("[GUI] Parsed room: " + $room)
    Append-Log ("[GUI] Nick field is UI-only in v39. No --nick is sent; native uses its working default nick/resource.")
    Append-Log ("[GUI] Quality selector is monitoring-only in this GUI build; no quality flags are sent.")
    if ($script:currentLogFile) { Append-Log ("[GUI] Session log file: " + $script:currentLogFile) }

    $script:proc = New-Object System.Diagnostics.Process
    $script:proc.StartInfo = $psi
    $script:proc.EnableRaisingEvents = $true

    $rid = $script:runId

    $subOut = Register-ObjectEvent -InputObject $script:proc -EventName OutputDataReceived -MessageData $rid -Action {
        if ($Event.MessageData -ne $script:runId -or $script:isStopping) { return }
        $line = $EventArgs.Data
        if ($line) {
            $safeLine = [string]$line
            Invoke-UiSafe {
                Append-Log $safeLine
                Parse-Line $safeLine
            }
        }
    }
    $script:eventSubscribers += $subOut

    $subErr = Register-ObjectEvent -InputObject $script:proc -EventName ErrorDataReceived -MessageData $rid -Action {
        if ($Event.MessageData -ne $script:runId -or $script:isStopping) { return }
        $line = $EventArgs.Data
        if ($line) {
            $safeLine = [string]$line
            Invoke-UiSafe {
                Append-Log ("[stderr] " + $safeLine)
                Parse-Line $safeLine
            }
        }
    }
    $script:eventSubscribers += $subErr

    $subExit = Register-ObjectEvent -InputObject $script:proc -EventName Exited -MessageData $rid -Action {
        if ($Event.MessageData -ne $script:runId -or $script:isStopping) { return }
        $code = -1
        try { $code = $Event.Sender.ExitCode } catch {}
        Invoke-UiSafe {
            Append-Log "[GUI] Process exited with code $code"
            Set-UiRunning $false
        }
    }
    $script:eventSubscribers += $subExit

    try {
        [void]$script:proc.Start()
        $script:proc.BeginOutputReadLine()
        $script:proc.BeginErrorReadLine()

        Set-UiRunning $true
    } catch {
        Append-Log ("[GUI][ERROR] " + $_.Exception.Message)
        Set-UiRunning $false
        $lblState.Text = "Ошибка запуска"
    }
}

function Stop-Receiver {
    $script:isStopping = $true
    $script:runId++

    # Do not let old stdout/stderr event callbacks repaint the log after Stop.
    Clear-ProcessEvents

    if ($script:proc -and -not $script:proc.HasExited) {
        Append-Log "[GUI] Stopping receiver..."
        try { $script:proc.CancelOutputRead() } catch {}
        try { $script:proc.CancelErrorRead() } catch {}
        try {
            $script:proc.Kill()
            [void]$script:proc.WaitForExit(3000)
        } catch {
            Append-Log ("[GUI][WARN] " + $_.Exception.Message)
        }
    }

    try {
        if ($script:proc) { $script:proc.Dispose() }
    } catch {}
    $script:proc = $null

    Set-UiRunning $false
}

# ---------------- UI ----------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "Jitsi NDI Native GUI v38"
$form.Size = New-Object System.Drawing.Size(1180, 760)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(980, 640)

$font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Font = $font

$top = New-Object System.Windows.Forms.TableLayoutPanel
$top.Dock = "Top"
$top.Height = 150
$top.ColumnCount = 6
$top.RowCount = 4
$top.Padding = New-Object System.Windows.Forms.Padding(10)
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 120)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 90)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 20)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 100)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 100)))
$form.Controls.Add($top)

function Add-Label($text, $row, $col) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Dock = "Fill"
    $l.TextAlign = "MiddleLeft"
    $top.Controls.Add($l, $col, $row)
    return $l
}

Add-Label "Jitsi ссылка/room:" 0 0 | Out-Null
$txtRoom = New-Object System.Windows.Forms.TextBox
$txtRoom.Dock = "Fill"
$txtRoom.Text = "https://meet.jit.si/6767676766767penxyi"
$top.Controls.Add($txtRoom, 1, 0)
$top.SetColumnSpan($txtRoom, 5)
$txtRoom.Add_TextChanged({ Update-RoomPreview })

Add-Label "Exe:" 1 0 | Out-Null
$lblExe = New-Object System.Windows.Forms.Label
$lblExe.Dock = "Fill"
$lblExe.TextAlign = "MiddleLeft"
$lblExe.Text = "автопоиск..."
$top.Controls.Add($lblExe, 1, 1)
$top.SetColumnSpan($lblExe, 3)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Exe..."
$btnBrowse.Dock = "Fill"
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "jitsi-ndi-native.exe|jitsi-ndi-native.exe|Exe files|*.exe|All files|*.*"
    $initial = $PSScriptRoot
    if (-not [string]::IsNullOrWhiteSpace($script:selectedExePath)) {
        try {
            $candidateDir = Split-Path $script:selectedExePath -Parent
            if ($candidateDir -and (Test-Path $candidateDir)) { $initial = $candidateDir }
        } catch {}
    }
    $dlg.InitialDirectory = $initial
    if ($dlg.ShowDialog() -eq "OK") { Set-ExePath $dlg.FileName }
})
$top.Controls.Add($btnBrowse, 4, 1)

$btnLogs = New-Object System.Windows.Forms.Button
$btnLogs.Text = "Логи"
$btnLogs.Dock = "Fill"
$btnLogs.Add_Click({ Open-LogFolder })
$top.Controls.Add($btnLogs, 5, 1)

Set-ExePath (Find-NativeExe)

Add-Label "Ник в интерфейсе:" 2 0 | Out-Null
$txtNick = New-Object System.Windows.Forms.TextBox
$txtNick.Dock = "Fill"
$txtNick.Text = "Jitsi NDI"
$txtNick.Add_TextChanged({ [void](Build-LaunchPreview) })
$top.Controls.Add($txtNick, 1, 2)

Add-Label "Качество:" 2 2 | Out-Null
$cmbQuality = New-Object System.Windows.Forms.ComboBox
$cmbQuality.Dock = "Fill"
$cmbQuality.DropDownStyle = "DropDownList"
[void]$cmbQuality.Items.Add("только мониторинг")
[void]$cmbQuality.Items.Add("управление качеством пока не поддерживается native")
$cmbQuality.SelectedIndex = 0
$cmbQuality.Enabled = $false
$top.Controls.Add($cmbQuality, 3, 2)

$chkNickOnStart = New-Object System.Windows.Forms.CheckBox
$chkNickOnStart.Text = "ник пока не передаётся (--nick отключён)"
$chkNickOnStart.Dock = "Fill"
$chkNickOnStart.Checked = $false
$chkNickOnStart.Enabled = $false
$chkNickOnStart.Add_CheckedChanged({ [void](Build-LaunchPreview) })
$top.Controls.Add($chkNickOnStart, 4, 2)
$top.SetColumnSpan($chkNickOnStart, 2)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "Старт"
$btnStart.Dock = "Fill"
$btnStart.Add_Click({ Start-Receiver })
$top.Controls.Add($btnStart, 0, 3)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = "Стоп"
$btnStop.Dock = "Fill"
$btnStop.Enabled = $false
$btnStop.Add_Click({ Stop-Receiver })
$top.Controls.Add($btnStop, 1, 3)

$lblState = New-Object System.Windows.Forms.Label
$lblState.Text = "Остановлен"
$lblState.Dock = "Fill"
$lblState.TextAlign = "MiddleLeft"
$top.Controls.Add($lblState, 2, 3)

$lblDominant = New-Object System.Windows.Forms.Label
$lblDominant.Text = "Активный спикер: —"
$lblDominant.Dock = "Fill"
$lblDominant.TextAlign = "MiddleLeft"
$top.Controls.Add($lblDominant, 3, 3)

$lblBandwidth = New-Object System.Windows.Forms.Label
$lblBandwidth.Text = "Downlink estimate: —"
$lblBandwidth.Dock = "Fill"
$lblBandwidth.TextAlign = "MiddleLeft"
$top.Controls.Add($lblBandwidth, 4, 3)
$top.SetColumnSpan($lblBandwidth, 2)

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = "Fill"
$split.Orientation = "Horizontal"
$split.SplitterDistance = 300
$form.Controls.Add($split)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = "Fill"
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.RowHeadersVisible = $false
$grid.AutoSizeColumnsMode = "Fill"
$grid.SelectionMode = "FullRowSelect"

$columns = @(
    @{Name="Key"; Header="Source key"},
    @{Name="Endpoint"; Header="Endpoint"},
    @{Name="Name"; Header="Имя/NDI"},
    @{Name="Kind"; Header="Тип"},
    @{Name="Resolution"; Header="Разрешение"},
    @{Name="MaxRes"; Header="Max"},
    @{Name="Down"; Header="Down"},
    @{Name="Up"; Header="Up"},
    @{Name="VideoDown"; Header="V Down"},
    @{Name="VideoUp"; Header="V Up"},
    @{Name="Quality"; Header="CQ"},
    @{Name="Loss"; Header="Loss"},
    @{Name="RTT"; Header="RTT"},
    @{Name="Updated"; Header="Обновлено"}
)

foreach ($c in $columns) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $c.Name
    $col.HeaderText = $c.Header
    [void]$grid.Columns.Add($col)
}


$panel1Layout = New-Object System.Windows.Forms.TableLayoutPanel
$panel1Layout.Dock = "Fill"
$panel1Layout.ColumnCount = 1
$panel1Layout.RowCount = 2
[void]$panel1Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$panel1Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$split.Panel1.Controls.Add($panel1Layout)

$sourceBar = New-Object System.Windows.Forms.TableLayoutPanel
$sourceBar.Dock = "Fill"
$sourceBar.ColumnCount = 4
$sourceBar.RowCount = 1
[void]$sourceBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 26)))
[void]$sourceBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 30)))
[void]$sourceBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 24)))
[void]$sourceBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 20)))

$lblRoomPreview = New-Object System.Windows.Forms.Label
$lblRoomPreview.Dock = "Fill"
$lblRoomPreview.TextAlign = "MiddleLeft"
$lblRoomPreview.Text = "Room: —"
$sourceBar.Controls.Add($lblRoomPreview, 0, 0)

$lblSourceStats = New-Object System.Windows.Forms.Label
$lblSourceStats.Dock = "Fill"
$lblSourceStats.TextAlign = "MiddleLeft"
$lblSourceStats.Text = "Источники: 0 | камеры: 0 | экраны: 0"
$sourceBar.Controls.Add($lblSourceStats, 1, 0)

$lblResolutionStats = New-Object System.Windows.Forms.Label
$lblResolutionStats.Dock = "Fill"
$lblResolutionStats.TextAlign = "MiddleLeft"
$lblResolutionStats.Text = "Разрешения: 1080p 0 | 720p 0 | <=540p 0 | ? 0"
$sourceBar.Controls.Add($lblResolutionStats, 2, 0)

$lblLastFrame = New-Object System.Windows.Forms.Label
$lblLastFrame.Dock = "Fill"
$lblLastFrame.TextAlign = "MiddleLeft"
$lblLastFrame.Text = "Последний NDI кадр: —"
$sourceBar.Controls.Add($lblLastFrame, 3, 0)

$panel1Layout.Controls.Add($sourceBar, 0, 0)
$panel1Layout.Controls.Add($grid, 0, 1)

$gridMenu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$gridMenu.Items.Add("Копировать NDI/имя", $null, { Copy-TextToClipboard (Get-SelectedGridValue "Name") })
[void]$gridMenu.Items.Add("Копировать endpoint", $null, { Copy-TextToClipboard (Get-SelectedGridValue "Endpoint") })
[void]$gridMenu.Items.Add("Копировать разрешение", $null, { Copy-TextToClipboard (Get-SelectedGridValue "Resolution") })
[void]$gridMenu.Items.Add("Копировать source key", $null, { Copy-TextToClipboard (Get-SelectedGridValue "Key") })
$grid.ContextMenuStrip = $gridMenu

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Dock = "Fill"
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Both"
$txtLog.ReadOnly = $true
$txtLog.WordWrap = $false
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)

$panel2Layout = New-Object System.Windows.Forms.TableLayoutPanel
$panel2Layout.Dock = "Fill"
$panel2Layout.ColumnCount = 1
$panel2Layout.RowCount = 2
[void]$panel2Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 34)))
[void]$panel2Layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$split.Panel2.Controls.Add($panel2Layout)

$logBar = New-Object System.Windows.Forms.TableLayoutPanel
$logBar.Dock = "Fill"
$logBar.ColumnCount = 5
$logBar.RowCount = 1
[void]$logBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 170)))
[void]$logBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 150)))
[void]$logBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
[void]$logBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$logBar.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 300)))

$btnCopyCommand = New-Object System.Windows.Forms.Button
$btnCopyCommand.Text = "Копировать команду"
$btnCopyCommand.Dock = "Fill"
$btnCopyCommand.Add_Click({ Copy-TextToClipboard (Build-LaunchPreview) })
$logBar.Controls.Add($btnCopyCommand, 0, 0)

$btnOpenCurrentLog = New-Object System.Windows.Forms.Button
$btnOpenCurrentLog.Text = "Текущий лог"
$btnOpenCurrentLog.Dock = "Fill"
$btnOpenCurrentLog.Add_Click({ Open-CurrentLogFile })
$logBar.Controls.Add($btnOpenCurrentLog, 1, 0)

$btnClearLog = New-Object System.Windows.Forms.Button
$btnClearLog.Text = "Очистить лог"
$btnClearLog.Dock = "Fill"
$btnClearLog.Add_Click({ Clear-VisibleLog })
$logBar.Controls.Add($btnClearLog, 2, 0)

$lblQualityRequest = New-Object System.Windows.Forms.Label
$lblQualityRequest.Dock = "Fill"
$lblQualityRequest.TextAlign = "MiddleRight"
$lblQualityRequest.Text = "Quality request: —"
$logBar.Controls.Add($lblQualityRequest, 4, 0)

$panel2Layout.Controls.Add($logBar, 0, 0)
$panel2Layout.Controls.Add($txtLog, 0, 1)

$form.Add_FormClosing({
    Stop-Receiver
})

Update-RoomPreview
Update-StatsBar
[void](Build-LaunchPreview)
Append-Log "[GUI v38-visual-monitoring] Готово. Вставь ссылку Jitsi и нажми Старт."
Append-Log "[GUI] Основа запуска сохранена: GUI не передаёт --quality/--width/--height/--ndi-name и не меняет WebRTC/NDI-часть."
Append-Log "[GUI] v39: --nick отключён в GUI, потому что галочка ломала рабочий вход/NDI."
Append-Log "[GUI] Новые элементы v38 только читают лог и помогают копировать данные; запуск native оставлен как в рабочей v37."
Append-Log "[GUI] Ник применяется только при новом входе в комнату: измени ник, затем Стоп -> Старт."

[void][System.Windows.Forms.Application]::Run($form)
