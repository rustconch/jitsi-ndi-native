# Jitsi NDI Native - simple Windows GUI launcher v30
# Place this file in the repository root and run:
# powershell -ExecutionPolicy Bypass -File .\JitsiNdiGui.ps1

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:proc = $null
$script:eventSubscribers = @()
$script:rowsByKey = @{}
$script:dominantEndpoint = ""
$script:runId = 0
$script:isStopping = $false
$script:repoRoot = $PSScriptRoot
$script:settingsPath = Join-Path $PSScriptRoot "JitsiNdiGui.settings.json"
$script:logDir = Join-Path $PSScriptRoot "logs"
$script:logFilePath = $null
$script:logLines = New-Object System.Collections.Generic.List[string]
$script:utf8NoBom = New-Object System.Text.UTF8Encoding -ArgumentList $false
$script:exePath = $null

function Ensure-LogDir {
    if (-not (Test-Path $script:logDir)) {
        [void](New-Item -ItemType Directory -Path $script:logDir -Force)
    }
}

function New-RunLogFile {
    Ensure-LogDir
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    return (Join-Path $script:logDir "jitsi_ndi_gui_$ts.log")
}

function Write-LogFile {
    param([string]$line)
    if ([string]::IsNullOrWhiteSpace($script:logFilePath)) { return }
    try {
        [System.IO.File]::AppendAllText($script:logFilePath, $line + [Environment]::NewLine, $script:utf8NoBom)
    } catch {
        # Do not break the GUI if the log file is temporarily locked.
    }
}

function Append-Log {
    param([string]$line)
    if ($null -eq $line) { return }

    if ($script:txtLog -and -not $script:txtLog.IsDisposed -and $script:txtLog.InvokeRequired) {
        $safeLine = [string]$line
        try {
            [void]$script:txtLog.BeginInvoke([System.Windows.Forms.MethodInvoker]{ Append-Log $safeLine })
        } catch {
            # UI is probably closing; ignore late log callbacks.
        }
        return
    }

    $script:logLines.Add($line)
    while ($script:logLines.Count -gt 1200) { $script:logLines.RemoveAt(0) }
    Write-LogFile $line

    if (-not $script:txtLog -or $script:txtLog.IsDisposed) { return }
    $script:txtLog.AppendText($line + [Environment]::NewLine)
    if ($script:txtLog.Lines.Count -gt 1200) {
        $script:txtLog.Lines = $script:txtLog.Lines | Select-Object -Last 1000
        $script:txtLog.SelectionStart = $script:txtLog.Text.Length
        $script:txtLog.ScrollToCaret()
    }
}

function Convert-JitsiInputToRoom {
    param([string]$InputText)
    $s = ($InputText | ForEach-Object { "$_" }).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Accept a MUC JID: room@conference.meet.jit.si
    if ($s -match "@conference\.") {
        return ($s -replace "@conference\..*$", "").Trim()
    }

    # Accept full URLs: https://meet.jit.si/room, including query/hash.
    if ($s -match "^https?://") {
        try {
            $uri = [System.Uri]$s
            $path = [System.Uri]::UnescapeDataString($uri.AbsolutePath.Trim("/"))
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                $segments = @($path.Split("/") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($segments.Count -gt 0) { return $segments[$segments.Count - 1].Trim() }
            }
        } catch {
            return $s
        }
    }

    # Accept meet.jit.si/room without protocol.
    if ($s -match "^[^/]+\.[^/]+/(.+)$") {
        $part = $Matches[1].Split("?")[0].Split("#")[0].Trim("/")
        if ($part) {
            $segments = @($part.Split("/") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($segments.Count -gt 0) { return [System.Uri]::UnescapeDataString($segments[$segments.Count - 1]) }
        }
    }

    return ($s.Split("?")[0].Split("#")[0].Trim("/"))
}

function Sanitize-Name {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }
    $x = $s.Trim()
    $x = $x -replace "[\r\n\t]+", " "
    $x = $x -replace '[\\/:*?"<>|]', '_'
    while ($x.Contains("  ")) { $x = $x.Replace("  ", " ") }
    if ($x.Length -gt 64) { $x = $x.Substring(0, 64) }
    return $x
}

function Get-SourceKind {
    param([string]$sourceKey, [string]$sourceName)
    if ($sourceKey -match "-v1$" -or $sourceName -match "(?i)(screen|desktop|демонстр|share)") { return "screen" }
    if ($sourceKey -match "-v\d+$") { return "camera" }
    if ($sourceKey -match "-a\d+$") { return "audio" }
    return "video"
}

function Format-Bitrate {
    param($value)
    if ($null -eq $value) { return "" }
    try {
        $n = [double]$value
        if ($n -ge 1000000) { return ("{0:N1} Mbps" -f ($n / 1000000.0)) }
        if ($n -ge 1000) { return ("{0:N0} kbps" -f ($n / 1000.0)) }
        return ("{0:N0} bps" -f $n)
    } catch {
        return [string]$value
    }
}

function Find-DefaultExe {
    $candidates = @(
        (Join-Path $PSScriptRoot "build-ndi\Release\jitsi-ndi-native.exe"),
        (Join-Path $PSScriptRoot "build\Release\jitsi-ndi-native.exe"),
        (Join-Path $PSScriptRoot "build-ndi\RelWithDebInfo\jitsi-ndi-native.exe"),
        (Join-Path $PSScriptRoot "jitsi-ndi-native.exe")
    )
    foreach ($p in $candidates) {
        if (Test-Path $p) { return (Resolve-Path $p).Path }
    }
    return $candidates[0]
}

function Load-Settings {
    if (-not (Test-Path $script:settingsPath)) { return $null }
    try {
        return (Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Save-Settings {
    try {
        $obj = [ordered]@{
            room = $script:txtRoom.Text
            nick = $script:txtNick.Text
            ndiName = $script:txtNdiName.Text
            participantFilter = $script:txtFilter.Text
            quality = [string]$script:cmbQuality.SelectedItem
            exePath = $script:exePath
        }
        ($obj | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $script:settingsPath -Encoding UTF8
    } catch {
        # Settings are only convenience; never break start/stop because of them.
    }
}

function Quote-CliArg {
    param([string]$Arg)
    if ($null -eq $Arg) { return '""' }
    $s = [string]$Arg
    if ($s.Length -eq 0) { return '""' }
    if ($s -notmatch '[\s"]') { return $s }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq [char]92) {
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
    if ($bs -gt 0) { [void]$sb.Append(('\' * ($bs * 2))) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function Join-CliArgs {
    param([System.Collections.Generic.List[string]]$ArgsList)
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($a in $ArgsList) { $parts.Add((Quote-CliArg $a)) }
    return ($parts -join " ")
}

function Clear-ProcessEvents {
    foreach ($sub in @($script:eventSubscribers)) {
        try { Unregister-Event -SubscriptionId $sub.SubscriptionId -ErrorAction SilentlyContinue } catch {}
        try { if ($sub.Action) { Remove-Job -Id $sub.Action.Id -Force -ErrorAction SilentlyContinue } } catch {}
    }
    $script:eventSubscribers = @()
}

function Invoke-UiSafe {
    param([scriptblock]$Block)
    if (-not $script:form -or $script:form.IsDisposed -or -not $script:form.IsHandleCreated) { return }
    try {
        if ($script:form.InvokeRequired) {
            [void]$script:form.BeginInvoke([System.Windows.Forms.MethodInvoker]$Block)
        } else {
            & $Block
        }
    } catch {
        # Form is closing or callback arrived after Stop; ignore safely.
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

    if ($script:grid.InvokeRequired) {
        $k = [string]$key
        $e = [string]$endpoint
        $d = [string]$displayName
        $kind2 = [string]$kind
        return $script:grid.Invoke([System.Func[object]]{ return Ensure-Row -key $k -endpoint $e -displayName $d -kind $kind2 })
    }

    if ($script:rowsByKey.ContainsKey($key)) {
        $row = $script:rowsByKey[$key]
    } else {
        $idx = $script:grid.Rows.Add()
        $row = $script:grid.Rows[$idx]
        $script:rowsByKey[$key] = $row
        $row.Cells["Key"].Value = $key
    }

    if ($endpoint) { $row.Cells["Endpoint"].Value = $endpoint }
    if ($displayName) { $row.Cells["Name"].Value = $displayName }
    if ($kind) { $row.Cells["Kind"].Value = $kind }
    $row.Cells["Updated"].Value = (Get-Date).ToString("HH:mm:ss")
    return $row
}

function Update-EndpointRows {
    param([string]$endpoint, [object]$stats)
    if ([string]::IsNullOrWhiteSpace($endpoint)) { return }

    if ($script:grid.InvokeRequired) {
        $e = [string]$endpoint
        $s = $stats
        try { [void]$script:grid.BeginInvoke([System.Windows.Forms.MethodInvoker]{ Update-EndpointRows -endpoint $e -stats $s }) } catch {}
        return
    }

    $matched = $false
    foreach ($key in @($script:rowsByKey.Keys)) {
        $row = $script:rowsByKey[$key]
        if (($row.Cells["Endpoint"].Value -as [string]) -eq $endpoint -or $key -like "$endpoint*") {
            $matched = $true
            if ($stats.bitrate) {
                $row.Cells["Down"].Value = Format-Bitrate $stats.bitrate.download
                $row.Cells["Up"].Value = Format-Bitrate $stats.bitrate.upload
                if ($stats.bitrate.video) {
                    $row.Cells["VideoDown"].Value = Format-Bitrate $stats.bitrate.video.download
                    $row.Cells["VideoUp"].Value = Format-Bitrate $stats.bitrate.video.upload
                }
            }
            if ($null -ne $stats.connectionQuality) { $row.Cells["Quality"].Value = ("{0:N0}%" -f [double]$stats.connectionQuality) }
            if ($null -ne $stats.jvbRTT) { $row.Cells["RTT"].Value = "$($stats.jvbRTT) ms" }
            if ($stats.packetLoss -and $null -ne $stats.packetLoss.download) { $row.Cells["Loss"].Value = "$($stats.packetLoss.download)" }
            if ($null -ne $stats.maxEnabledResolution) { $row.Cells["MaxRes"].Value = "$($stats.maxEnabledResolution)p" }
            $row.Cells["Updated"].Value = (Get-Date).ToString("HH:mm:ss")
        }
    }

    if (-not $matched) {
        $row = Ensure-Row -key $endpoint -endpoint $endpoint -displayName "" -kind "endpoint"
        if ($row) {
            if ($null -ne $stats.connectionQuality) { $row.Cells["Quality"].Value = ("{0:N0}%" -f [double]$stats.connectionQuality) }
            if ($null -ne $stats.jvbRTT) { $row.Cells["RTT"].Value = "$($stats.jvbRTT) ms" }
        }
    }
}

function Parse-Line {
    param([string]$line)
    if ([string]::IsNullOrWhiteSpace($line)) { return }

    if ($line -match 'created NDI participant source:\s*(.+?)\s+endpoint=([A-Za-z0-9_-]+)') {
        $sourceName = $Matches[1].Trim()
        $endpoint = $Matches[2].Trim()
        $displayName = $sourceName -replace '^JitsiNativeNDI\s*-\s*', ''
        $displayName = $displayName.Trim()
        $kind = Get-SourceKind -sourceKey $endpoint -sourceName $sourceName
        Ensure-Row -key $endpoint -endpoint $endpoint -displayName $displayName -kind $kind | Out-Null
        return
    }

    if ($line -match 'NDI video frame sent:\s*(.+?)\s+(\d+)x(\d+)') {
        $sourceName = $Matches[1].Trim()
        $w = $Matches[2]
        $h = $Matches[3]
        $displayName = $sourceName -replace '^JitsiNativeNDI\s*-\s*', ''
        $displayName = $displayName.Trim()
        $key = $displayName
        if ($displayName -match '([A-Za-z0-9]{6,})(?:-|$)') { $key = $Matches[1] }
        $kind = Get-SourceKind -sourceKey $key -sourceName $sourceName
        $row = Ensure-Row -key $key -endpoint $key -displayName $displayName -kind $kind
        if ($row) { $row.Cells["Resolution"].Value = "${w}x${h}" }
        return
    }

    if ($line -match 'video RTP endpoint=([A-Za-z0-9_-]+).*ssrc=(\d+)') {
        $endpoint = $Matches[1]
        Ensure-Row -key $endpoint -endpoint $endpoint -displayName "" -kind (Get-SourceKind -sourceKey $endpoint -sourceName "") | Out-Null
        return
    }

    if ($line -match 'bridge datachannel text:\s*(\{.*\})') {
        try {
            $json = $Matches[1] | ConvertFrom-Json -ErrorAction Stop
            if ($json.colibriClass -eq "EndpointStats") {
                Update-EndpointRows -endpoint $json.from -stats $json
            } elseif ($json.colibriClass -eq "ForwardedSources") {
                foreach ($src in $json.forwardedSources) {
                    $endpoint = ($src -replace '-v\d+$', '')
                    $kind = Get-SourceKind -sourceKey $src -sourceName ""
                    Ensure-Row -key $src -endpoint $endpoint -displayName "" -kind $kind | Out-Null
                }
            } elseif ($json.colibriClass -eq "DominantSpeakerEndpointChangeEvent") {
                $script:dominantEndpoint = [string]$json.dominantSpeakerEndpoint
                if (-not [string]::IsNullOrWhiteSpace($script:dominantEndpoint)) {
                    $script:lblDominant.Text = "Активный спикер: $script:dominantEndpoint"
                }
            } elseif ($json.colibriClass -eq "ConnectionStats") {
                if ($null -ne $json.estimatedDownlinkBandwidth) {
                    $script:lblBandwidth.Text = "Downlink: $(Format-Bitrate $json.estimatedDownlinkBandwidth)"
                }
            }
        } catch {
            # Ignore malformed/transient JSON.
        }
        return
    }
}

function Get-SelectedQualitySize {
    $q = [string]$script:cmbQuality.SelectedItem
    switch -Regex ($q) {
        '360'  { return @{ Width = 640;  Height = 360  } }
        '540'  { return @{ Width = 960;  Height = 540  } }
        '720'  { return @{ Width = 1280; Height = 720  } }
        '1080' { return @{ Width = 1920; Height = 1080 } }
        default { return $null }
    }
}

function Select-ExeFile {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "jitsi-ndi-native.exe|jitsi-ndi-native.exe|Exe files|*.exe|All files|*.*"
    $current = $script:exePath
    if (-not [string]::IsNullOrWhiteSpace($current)) {
        try { $dlg.InitialDirectory = Split-Path $current -Parent } catch {}
    }
    if ($dlg.ShowDialog() -eq "OK") {
        $script:exePath = $dlg.FileName
        Append-Log ("[GUI] Native exe selected: " + $script:exePath)
        Save-Settings
    }
}

function Use-SelectedRowAsFilter {
    if (-not $script:grid -or $script:grid.SelectedRows.Count -lt 1) { return }
    $row = $script:grid.SelectedRows[0]
    $name = [string]$row.Cells["Name"].Value
    $endpoint = [string]$row.Cells["Endpoint"].Value
    if (-not [string]::IsNullOrWhiteSpace($name)) {
        $script:txtFilter.Text = $name
    } elseif (-not [string]::IsNullOrWhiteSpace($endpoint)) {
        $script:txtFilter.Text = $endpoint
    }
    Append-Log "[GUI] Фильтр участника заполнен из выбранной строки. Перезапусти приёмник, чтобы применить фильтр."
}

function Start-Receiver {
    Clear-ProcessEvents
    $script:runId++
    $script:isStopping = $false

    if ($script:proc -and -not $script:proc.HasExited) {
        [System.Windows.Forms.MessageBox]::Show("Приёмник уже запущен.", "Jitsi NDI GUI") | Out-Null
        return
    }

    if ([string]::IsNullOrWhiteSpace($script:exePath)) { $script:exePath = Find-DefaultExe }
    $exePath = $script:exePath
    if (-not (Test-Path $exePath)) {
        $msg = "Не найден jitsi-ndi-native.exe.`n`nОжидал здесь:`n$exePath`n`nНажми «Exe…» и выбери собранный файл вручную."
        [System.Windows.Forms.MessageBox]::Show($msg, "Jitsi NDI GUI") | Out-Null
        return
    }

    $room = Convert-JitsiInputToRoom $script:txtRoom.Text
    if ([string]::IsNullOrWhiteSpace($room)) {
        [System.Windows.Forms.MessageBox]::Show("Вставь ссылку Jitsi или имя комнаты.", "Jitsi NDI GUI") | Out-Null
        return
    }

    Save-Settings
    $script:logFilePath = New-RunLogFile
    if ($script:txtLog) { $script:txtLog.Clear() }
    $script:rowsByKey.Clear()
    if ($script:grid) { $script:grid.Rows.Clear() }
    if ($script:lblLogFile) { $script:lblLogFile.Text = "Лог: " + $script:logFilePath }

    $args = New-Object System.Collections.Generic.List[string]
    $args.Add("--room"); $args.Add($room)

    $nick = Sanitize-Name $script:txtNick.Text
    if (-not [string]::IsNullOrWhiteSpace($nick)) {
        $args.Add("--nick"); $args.Add($nick)
    }

    $ndiName = Sanitize-Name $script:txtNdiName.Text
    if (-not [string]::IsNullOrWhiteSpace($ndiName)) {
        $args.Add("--ndi-name"); $args.Add($ndiName)
    }

    $filter = ($script:txtFilter.Text | ForEach-Object { "$_" }).Trim()
    if (-not [string]::IsNullOrWhiteSpace($filter)) {
        $args.Add("--participant-filter"); $args.Add($filter)
    }

    $size = Get-SelectedQualitySize
    if ($null -ne $size) {
        $args.Add("--width");  $args.Add([string]$size.Width)
        $args.Add("--height"); $args.Add([string]$size.Height)
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exePath
    $psi.WorkingDirectory = Split-Path $exePath -Parent
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Arguments = Join-CliArgs $args

    Append-Log "[GUI v30] Starting receiver"
    Append-Log ("[GUI] Log file: " + $script:logFilePath)
    Append-Log ("[GUI] Parsed room: " + $room)
    $nickForLog = if ($nick) { $nick } else { '<empty>' }
    Append-Log ("[GUI] Nick passed to native: " + $nickForLog)
    Append-Log ("[GUI] Command: " + $psi.FileName + " " + $psi.Arguments)

    $script:proc = New-Object System.Diagnostics.Process
    $script:proc.StartInfo = $psi
    $script:proc.EnableRaisingEvents = $true
    $rid = $script:runId

    $subOut = Register-ObjectEvent -InputObject $script:proc -EventName OutputDataReceived -MessageData $rid -Action {
        if ($Event.MessageData -ne $script:runId -or $script:isStopping) { return }
        $line = $EventArgs.Data
        if ($line) {
            $safeLine = [string]$line
            Invoke-UiSafe { Append-Log $safeLine; Parse-Line $safeLine }
        }
    }
    $script:eventSubscribers += $subOut

    $subErr = Register-ObjectEvent -InputObject $script:proc -EventName ErrorDataReceived -MessageData $rid -Action {
        if ($Event.MessageData -ne $script:runId -or $script:isStopping) { return }
        $line = $EventArgs.Data
        if ($line) {
            $safeLine = "[stderr] " + [string]$line
            Invoke-UiSafe { Append-Log $safeLine; Parse-Line $safeLine }
        }
    }
    $script:eventSubscribers += $subErr

    $subExit = Register-ObjectEvent -InputObject $script:proc -EventName Exited -MessageData $rid -Action {
        if ($Event.MessageData -ne $script:runId -or $script:isStopping) { return }
        $code = -1
        try { $code = $Event.Sender.ExitCode } catch {}
        Invoke-UiSafe {
            Append-Log "[GUI] Process exited with code $code"
            $script:btnStart.Enabled = $true
            $script:btnStop.Enabled = $false
            $script:lblState.Text = "Остановлен"
        }
    }
    $script:eventSubscribers += $subExit

    try {
        [void]$script:proc.Start()
        $script:proc.BeginOutputReadLine()
        $script:proc.BeginErrorReadLine()
        $script:btnStart.Enabled = $false
        $script:btnStop.Enabled = $true
        $script:lblState.Text = "Запущен"
    } catch {
        Append-Log ("[GUI][ERROR] " + $_.Exception.Message)
        $script:btnStart.Enabled = $true
        $script:btnStop.Enabled = $false
        $script:lblState.Text = "Ошибка запуска"
    }
}

function Stop-Receiver {
    $script:isStopping = $true
    $script:runId++
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

    try { if ($script:proc) { $script:proc.Dispose() } } catch {}
    $script:proc = $null

    if ($script:btnStart -and -not $script:btnStart.IsDisposed) { $script:btnStart.Enabled = $true }
    if ($script:btnStop -and -not $script:btnStop.IsDisposed) { $script:btnStop.Enabled = $false }
    if ($script:lblState -and -not $script:lblState.IsDisposed) { $script:lblState.Text = "Остановлен" }
}

# ---------------- UI ----------------
$script:logFilePath = New-RunLogFile
$settings = Load-Settings
$script:exePath = if ($settings -and $settings.exePath) { [string]$settings.exePath } else { Find-DefaultExe }

$script:form = New-Object System.Windows.Forms.Form
$script:form.Text = "Jitsi NDI Native GUI"
$script:form.Size = New-Object System.Drawing.Size(1180, 780)
$script:form.StartPosition = "CenterScreen"
$script:form.MinimumSize = New-Object System.Drawing.Size(980, 650)
$script:form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$tip = New-Object System.Windows.Forms.ToolTip

$top = New-Object System.Windows.Forms.TableLayoutPanel
$top.Dock = "Top"
$top.Height = 185
$top.ColumnCount = 6
$top.RowCount = 5
$top.Padding = New-Object System.Windows.Forms.Padding(10)
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 46)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 110)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 24)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 130)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 140)))
$script:form.Controls.Add($top)

function Add-Label($text, $row, $col) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Dock = "Fill"
    $l.TextAlign = "MiddleLeft"
    $top.Controls.Add($l, $col, $row)
    return $l
}

Add-Label "Jitsi ссылка/room:" 0 0 | Out-Null
$script:txtRoom = New-Object System.Windows.Forms.TextBox
$script:txtRoom.Dock = "Fill"
$script:txtRoom.Text = if ($settings -and $settings.room) { [string]$settings.room } else { "https://meet.jit.si/6767676766767penxyi" }
$top.Controls.Add($script:txtRoom, 1, 0)
$top.SetColumnSpan($script:txtRoom, 5)

Add-Label "Ник в Jitsi:" 1 0 | Out-Null
$script:txtNick = New-Object System.Windows.Forms.TextBox
$script:txtNick.Dock = "Fill"
$script:txtNick.Text = if ($settings -and $settings.nick) { [string]$settings.nick } else { "Jitsi NDI" }
$top.Controls.Add($script:txtNick, 1, 1)

Add-Label "NDI имя:" 1 2 | Out-Null
$script:txtNdiName = New-Object System.Windows.Forms.TextBox
$script:txtNdiName.Dock = "Fill"
$script:txtNdiName.Text = if ($settings -and $settings.ndiName) { [string]$settings.ndiName } else { "JitsiNativeNDI" }
$top.Controls.Add($script:txtNdiName, 3, 1)
$top.SetColumnSpan($script:txtNdiName, 3)

Add-Label "Фильтр участника:" 2 0 | Out-Null
$script:txtFilter = New-Object System.Windows.Forms.TextBox
$script:txtFilter.Dock = "Fill"
$script:txtFilter.Text = if ($settings -and $settings.participantFilter) { [string]$settings.participantFilter } else { "" }
$top.Controls.Add($script:txtFilter, 1, 2)

Add-Label "Качество:" 2 2 | Out-Null
$script:cmbQuality = New-Object System.Windows.Forms.ComboBox
$script:cmbQuality.Dock = "Fill"
$script:cmbQuality.DropDownStyle = "DropDownList"
[void]$script:cmbQuality.Items.Add("native/default")
[void]$script:cmbQuality.Items.Add("360p")
[void]$script:cmbQuality.Items.Add("540p")
[void]$script:cmbQuality.Items.Add("720p")
[void]$script:cmbQuality.Items.Add("1080p")
$wantedQuality = if ($settings -and $settings.quality) { [string]$settings.quality } else { "1080p" }
$idx = $script:cmbQuality.Items.IndexOf($wantedQuality)
if ($idx -lt 0) { $idx = 4 }
$script:cmbQuality.SelectedIndex = $idx
$top.Controls.Add($script:cmbQuality, 3, 2)

$btnUseSelected = New-Object System.Windows.Forms.Button
$btnUseSelected.Text = "Фильтр из строки"
$btnUseSelected.Dock = "Fill"
$btnUseSelected.Add_Click({ Use-SelectedRowAsFilter })
$top.Controls.Add($btnUseSelected, 4, 2)
$top.SetColumnSpan($btnUseSelected, 2)
$tip.SetToolTip($btnUseSelected, "Выбери участника в таблице и нажми эту кнопку. Фильтр применится после перезапуска приёмника.")

$script:btnStart = New-Object System.Windows.Forms.Button
$script:btnStart.Text = "Старт"
$script:btnStart.Dock = "Fill"
$script:btnStart.Add_Click({ Start-Receiver })
$top.Controls.Add($script:btnStart, 0, 3)

$script:btnStop = New-Object System.Windows.Forms.Button
$script:btnStop.Text = "Стоп"
$script:btnStop.Dock = "Fill"
$script:btnStop.Enabled = $false
$script:btnStop.Add_Click({ Stop-Receiver })
$top.Controls.Add($script:btnStop, 1, 3)

$script:lblState = New-Object System.Windows.Forms.Label
$script:lblState.Text = "Остановлен"
$script:lblState.Dock = "Fill"
$script:lblState.TextAlign = "MiddleLeft"
$top.Controls.Add($script:lblState, 2, 3)

$script:lblDominant = New-Object System.Windows.Forms.Label
$script:lblDominant.Text = "Активный спикер: —"
$script:lblDominant.Dock = "Fill"
$script:lblDominant.TextAlign = "MiddleLeft"
$top.Controls.Add($script:lblDominant, 3, 3)

$script:lblBandwidth = New-Object System.Windows.Forms.Label
$script:lblBandwidth.Text = "Downlink: —"
$script:lblBandwidth.Dock = "Fill"
$script:lblBandwidth.TextAlign = "MiddleLeft"
$top.Controls.Add($script:lblBandwidth, 4, 3)

$btnExe = New-Object System.Windows.Forms.Button
$btnExe.Text = "Exe…"
$btnExe.Dock = "Fill"
$btnExe.Add_Click({ Select-ExeFile })
$top.Controls.Add($btnExe, 5, 3)
$tip.SetToolTip($btnExe, "Скрытая настройка: выбрать jitsi-ndi-native.exe вручную, если авто-поиск не нашёл сборку.")

$script:lblLogFile = New-Object System.Windows.Forms.Label
$script:lblLogFile.Text = "Лог: " + $script:logFilePath
$script:lblLogFile.Dock = "Fill"
$script:lblLogFile.TextAlign = "MiddleLeft"
$top.Controls.Add($script:lblLogFile, 0, 4)
$top.SetColumnSpan($script:lblLogFile, 5)

$btnOpenLogs = New-Object System.Windows.Forms.Button
$btnOpenLogs.Text = "Открыть логи"
$btnOpenLogs.Dock = "Fill"
$btnOpenLogs.Add_Click({ Ensure-LogDir; Start-Process explorer.exe $script:logDir })
$top.Controls.Add($btnOpenLogs, 5, 4)

$split = New-Object System.Windows.Forms.SplitContainer
$split.Dock = "Fill"
$split.Orientation = "Horizontal"
$split.SplitterDistance = 315
$script:form.Controls.Add($split)

$script:grid = New-Object System.Windows.Forms.DataGridView
$script:grid.Dock = "Fill"
$script:grid.ReadOnly = $true
$script:grid.AllowUserToAddRows = $false
$script:grid.AllowUserToDeleteRows = $false
$script:grid.RowHeadersVisible = $false
$script:grid.AutoSizeColumnsMode = "Fill"
$script:grid.SelectionMode = "FullRowSelect"
$script:grid.MultiSelect = $false
$script:grid.Add_CellDoubleClick({ Use-SelectedRowAsFilter })

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
    [void]$script:grid.Columns.Add($col)
}
$split.Panel1.Controls.Add($script:grid)

$script:txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog.Dock = "Fill"
$script:txtLog.Multiline = $true
$script:txtLog.ScrollBars = "Both"
$script:txtLog.ReadOnly = $true
$script:txtLog.WordWrap = $false
$script:txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$split.Panel2.Controls.Add($script:txtLog)

$script:form.Add_FormClosing({ Save-Settings; Stop-Receiver })

Append-Log "[GUI v30] Готово. Вставь ссылку Jitsi и нажми Старт."
Append-Log "[GUI] Ник теперь передаётся в native exe всегда, без отдельного чекбокса."
Append-Log "[GUI] Качество передаётся безопасно через --width/--height, без несуществующего --quality."
Append-Log "[GUI] Строка с путём exe убрана из интерфейса; если авто-поиск не сработал, нажми Exe…"
Append-Log ("[GUI] Текущий файл лога: " + $script:logFilePath)

[void][System.Windows.Forms.Application]::Run($script:form)
