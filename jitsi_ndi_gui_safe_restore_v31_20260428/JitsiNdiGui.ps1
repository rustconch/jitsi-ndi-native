# Jitsi NDI Native - SAFE GUI launcher v31
# GUI-only patch. It does NOT touch src/, build files, DLLs, WebRTC, Jingle, NDI routing or decoding.
# Default native launch mode is intentionally conservative: --room only + optional --nick.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:proc = $null
$script:eventSubscribers = @()
$script:repoRoot = $PSScriptRoot
$script:rowsByKey = @{}
$script:logQueue = $null
$script:acceptProcessLog = $false
$script:sessionLogPath = $null
$script:exePath = $null
$script:lastExeCandidates = @()

function Convert-JitsiInputToRoom {
    param([string]$InputText)
    $s = ([string]$InputText).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }

    # Accept MUC JID: room@conference.meet.jit.si
    if ($s -match "@conference\.") {
        return ($s -replace "@conference\..*$", "").Trim()
    }

    # Accept full links: https://meet.jit.si/room#config...
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

function Sanitize-Nick {
    param([string]$s)
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }
    $x = $s.Trim()
    # Keep Cyrillic/Unicode letters, but remove XML/JID-hostile chars and Windows CLI-hostile punctuation.
    $x = $x -replace "[\x00-\x1F\\/:*?`"<>|&']", "_"
    if ($x.Length -gt 48) { $x = $x.Substring(0, 48) }
    return $x
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
        if ($ch -eq '\') { $bs++; continue }
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

function Find-NativeExe {
    $candidates = @(
        (Join-Path $script:repoRoot "build-ndi\Release\jitsi-ndi-native.exe"),
        (Join-Path $script:repoRoot "build\Release\jitsi-ndi-native.exe"),
        (Join-Path $script:repoRoot "build-ndi\RelWithDebInfo\jitsi-ndi-native.exe"),
        (Join-Path $script:repoRoot "build\RelWithDebInfo\jitsi-ndi-native.exe"),
        (Join-Path $script:repoRoot "jitsi-ndi-native.exe")
    )
    $script:lastExeCandidates = $candidates
    foreach ($p in $candidates) {
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $candidates[0]
}

function Update-ExeLabel {
    if (Test-Path -LiteralPath $script:exePath) {
        $lblExeState.Text = "Exe: найден"
    } else {
        $lblExeState.Text = "Exe: не найден — нажми Exe..."
    }
}

function Get-SourceKind {
    param([string]$sourceKey, [string]$sourceName)
    if ($sourceKey -match "-v1$" -or $sourceName -match "(?i)(screen|desktop|демонстр|share)") { return "screen" }
    if ($sourceKey -match "-v\d+$") { return "camera" }
    if ($sourceKey -match "-a\d+$") { return "audio" }
    return "video"
}

function Ensure-Row {
    param(
        [string]$key,
        [string]$endpoint,
        [string]$displayName,
        [string]$kind
    )
    if ([string]::IsNullOrWhiteSpace($key)) { return $null }

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
    return $row
}

function Update-EndpointRows {
    param([string]$endpoint, [object]$stats)
    if ([string]::IsNullOrWhiteSpace($endpoint)) { return }

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

    if ($line -match "created NDI participant source:\s*(.+?)\s+endpoint=([A-Za-z0-9_-]+)") {
        $sourceName = $Matches[1].Trim()
        $endpoint = $Matches[2].Trim()
        $displayName = ($sourceName -replace "^JitsiNativeNDI\s*-\s*", "").Trim()
        $kind = Get-SourceKind -sourceKey $endpoint -sourceName $sourceName
        Ensure-Row -key $endpoint -endpoint $endpoint -displayName $displayName -kind $kind | Out-Null
        return
    }

    if ($line -match "NDI video frame sent:\s*(.+?)\s+(\d+)x(\d+)") {
        $sourceName = $Matches[1].Trim()
        $w = $Matches[2]
        $h = $Matches[3]
        $displayName = ($sourceName -replace "^JitsiNativeNDI\s*-\s*", "").Trim()
        $key = $displayName
        if ($displayName -match "([A-Za-z0-9]{6,})(?:-|$)") { $key = $Matches[1] }
        $kind = Get-SourceKind -sourceKey $key -sourceName $sourceName
        $row = Ensure-Row -key $key -endpoint $key -displayName $displayName -kind $kind
        if ($row) { $row.Cells["Resolution"].Value = "${w}x${h}" }
        return
    }

    if ($line -match "video RTP endpoint=([A-Za-z0-9_-]+).*ssrc=(\d+)") {
        $endpoint = $Matches[1]
        Ensure-Row -key $endpoint -endpoint $endpoint -displayName "" -kind (Get-SourceKind -sourceKey $endpoint -sourceName "") | Out-Null
        return
    }

    if ($line -match "bridge datachannel text:\s*(\{.*\})") {
        try {
            $json = $Matches[1] | ConvertFrom-Json -ErrorAction Stop
            if ($json.colibriClass -eq "EndpointStats") {
                Update-EndpointRows -endpoint $json.from -stats $json
            } elseif ($json.colibriClass -eq "ForwardedSources") {
                foreach ($src in $json.forwardedSources) {
                    $endpoint = ($src -replace "-v\d+$", "")
                    $kind = Get-SourceKind -sourceKey $src -sourceName ""
                    Ensure-Row -key $src -endpoint $endpoint -displayName "" -kind $kind | Out-Null
                }
            } elseif ($json.colibriClass -eq "DominantSpeakerEndpointChangeEvent") {
                if (-not [string]::IsNullOrWhiteSpace([string]$json.dominantSpeakerEndpoint)) {
                    $lblDominant.Text = "Активный спикер: $($json.dominantSpeakerEndpoint)"
                }
            } elseif ($json.colibriClass -eq "ConnectionStats") {
                if ($null -ne $json.estimatedDownlinkBandwidth) {
                    $lblBandwidth.Text = "Downlink estimate: $($json.estimatedDownlinkBandwidth) bps"
                }
            }
        } catch {
            # ignore malformed/transient JSON
        }
        return
    }
}

function Append-Log {
    param([string]$line)
    if ($null -eq $line) { return }
    $stamp = (Get-Date).ToString("HH:mm:ss.fff")
    $out = "$stamp $line"

    if ($script:sessionLogPath) {
        try { Add-Content -LiteralPath $script:sessionLogPath -Value $out -Encoding UTF8 } catch {}
    }

    if ($txtLog -and -not $txtLog.IsDisposed) {
        $txtLog.AppendText($out + [Environment]::NewLine)
        if ($txtLog.Lines.Count -gt 1200) {
            $txtLog.Lines = $txtLog.Lines | Select-Object -Last 1000
            $txtLog.SelectionStart = $txtLog.Text.Length
        }
        $txtLog.ScrollToCaret()
    }
}

function Drain-LogQueue {
    if (-not $script:acceptProcessLog -or -not $script:logQueue) { return }
    $line = $null
    $count = 0
    while ($count -lt 200 -and $script:logQueue.TryDequeue([ref]$line)) {
        Append-Log $line
        Parse-Line $line
        $count++
    }
}

function Clear-ProcessEvents {
    foreach ($sub in @($script:eventSubscribers)) {
        try { Unregister-Event -SubscriptionId $sub.SubscriptionId -ErrorAction SilentlyContinue } catch {}
        try {
            if ($sub.Action) { Remove-Job -Id $sub.Action.Id -Force -ErrorAction SilentlyContinue }
        } catch {}
    }
    $script:eventSubscribers = @()
}

function New-SessionLogFile {
    $logDir = Join-Path $script:repoRoot "logs"
    if (-not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    return (Join-Path $logDir ("jitsi_ndi_gui_" + (Get-Date).ToString("yyyyMMdd_HHmmss") + ".log"))
}

function Start-Receiver {
    Clear-ProcessEvents
    if ($script:proc -and -not $script:proc.HasExited) {
        [System.Windows.Forms.MessageBox]::Show("Приёмник уже запущен.", "Jitsi NDI GUI") | Out-Null
        return
    }

    if (-not (Test-Path -LiteralPath $script:exePath)) {
        Update-ExeLabel
        $msg = "Не найден jitsi-ndi-native.exe.`n`nНажми Exe... и выбери рабочий exe из папки build-ndi\Release или build\Release."
        [System.Windows.Forms.MessageBox]::Show($msg, "Jitsi NDI GUI") | Out-Null
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

    if ($chkNick.Checked) {
        $nick = Sanitize-Nick $txtNick.Text
        if (-not [string]::IsNullOrWhiteSpace($nick)) {
            $args.Add("--nick")
            $args.Add($nick)
        }
    }

    # Deliberately DO NOT pass --ndi-name, --participant-filter, --width, --height or any custom quality flag here.
    # This keeps native receiver behavior as close as possible to the last working launch.

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $script:exePath
    $psi.WorkingDirectory = Split-Path $script:exePath -Parent
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.Arguments = Join-CliArgs $args

    $script:rowsByKey.Clear()
    $grid.Rows.Clear()
    $txtLog.Clear()
    $lblDominant.Text = "Активный спикер: —"
    $lblBandwidth.Text = "Downlink estimate: —"
    $script:logQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $script:sessionLogPath = New-SessionLogFile
    $script:acceptProcessLog = $true

    Append-Log "[GUI v31-safe] Starting receiver"
    Append-Log ("[GUI] Executable: " + $script:exePath)
    Append-Log ("[GUI] Arguments: " + $psi.Arguments)
    Append-Log ("[GUI] Parsed room: " + $room)
    Append-Log ("[GUI] Session log file: " + $script:sessionLogPath)
    Append-Log "[GUI] Safe mode: GUI passes only --room and optional --nick. Native media/NDI path is untouched."

    $script:proc = New-Object System.Diagnostics.Process
    $script:proc.StartInfo = $psi
    $script:proc.EnableRaisingEvents = $true

    $queue = $script:logQueue
    $subOut = Register-ObjectEvent -InputObject $script:proc -EventName OutputDataReceived -MessageData $queue -Action {
        $line = $EventArgs.Data
        if ($line) { $Event.MessageData.Enqueue([string]$line) }
    }
    $script:eventSubscribers += $subOut

    $subErr = Register-ObjectEvent -InputObject $script:proc -EventName ErrorDataReceived -MessageData $queue -Action {
        $line = $EventArgs.Data
        if ($line) { $Event.MessageData.Enqueue("[stderr] " + [string]$line) }
    }
    $script:eventSubscribers += $subErr

    $subExit = Register-ObjectEvent -InputObject $script:proc -EventName Exited -MessageData $queue -Action {
        $code = -1
        try { $code = $Event.Sender.ExitCode } catch {}
        $Event.MessageData.Enqueue("[GUI] Process exited with code $code")
    }
    $script:eventSubscribers += $subExit

    try {
        [void]$script:proc.Start()
        $script:proc.BeginOutputReadLine()
        $script:proc.BeginErrorReadLine()
        $btnStart.Enabled = $false
        $btnStop.Enabled = $true
        $lblState.Text = "Запущен"
    } catch {
        Append-Log ("[GUI][ERROR] " + $_.Exception.Message)
        $btnStart.Enabled = $true
        $btnStop.Enabled = $false
        $lblState.Text = "Ошибка запуска"
        $script:acceptProcessLog = $false
    }
}

function Stop-Receiver {
    $script:acceptProcessLog = $false
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
    $script:logQueue = $null

    if ($btnStart -and -not $btnStart.IsDisposed) { $btnStart.Enabled = $true }
    if ($btnStop -and -not $btnStop.IsDisposed) { $btnStop.Enabled = $false }
    if ($lblState -and -not $lblState.IsDisposed) { $lblState.Text = "Остановлен" }
}

# ---------------- UI ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Jitsi NDI Native GUI — safe v31"
$form.Size = New-Object System.Drawing.Size(1180, 760)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(980, 640)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$top = New-Object System.Windows.Forms.TableLayoutPanel
$top.Dock = "Top"
$top.Height = 145
$top.ColumnCount = 6
$top.RowCount = 4
$top.Padding = New-Object System.Windows.Forms.Padding(10)
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 125)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 45)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 95)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 25)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 110)))
[void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 110)))
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

Add-Label "Ник в Jitsi:" 1 0 | Out-Null
$txtNick = New-Object System.Windows.Forms.TextBox
$txtNick.Dock = "Fill"
$txtNick.Text = "Jitsi NDI"
$top.Controls.Add($txtNick, 1, 1)

$chkNick = New-Object System.Windows.Forms.CheckBox
$chkNick.Text = "передавать --nick"
$chkNick.Dock = "Fill"
$chkNick.Checked = $true
$top.Controls.Add($chkNick, 2, 1)

Add-Label "Качество:" 1 3 | Out-Null
$cmbQuality = New-Object System.Windows.Forms.ComboBox
$cmbQuality.Dock = "Fill"
$cmbQuality.DropDownStyle = "DropDownList"
[void]$cmbQuality.Items.Add("native / не менять")
[void]$cmbQuality.Items.Add("только смотреть в таблице")
$cmbQuality.SelectedIndex = 0
$cmbQuality.Enabled = $false
$top.Controls.Add($cmbQuality, 4, 1)
$top.SetColumnSpan($cmbQuality, 2)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "Старт"
$btnStart.Dock = "Fill"
$btnStart.Add_Click({ Start-Receiver })
$top.Controls.Add($btnStart, 0, 2)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = "Стоп"
$btnStop.Dock = "Fill"
$btnStop.Enabled = $false
$btnStop.Add_Click({ Stop-Receiver })
$top.Controls.Add($btnStop, 1, 2)

$lblState = New-Object System.Windows.Forms.Label
$lblState.Text = "Остановлен"
$lblState.Dock = "Fill"
$lblState.TextAlign = "MiddleLeft"
$top.Controls.Add($lblState, 2, 2)

$lblDominant = New-Object System.Windows.Forms.Label
$lblDominant.Text = "Активный спикер: —"
$lblDominant.Dock = "Fill"
$lblDominant.TextAlign = "MiddleLeft"
$top.Controls.Add($lblDominant, 3, 2)

$lblBandwidth = New-Object System.Windows.Forms.Label
$lblBandwidth.Text = "Downlink estimate: —"
$lblBandwidth.Dock = "Fill"
$lblBandwidth.TextAlign = "MiddleLeft"
$top.Controls.Add($lblBandwidth, 4, 2)
$top.SetColumnSpan($lblBandwidth, 2)

$lblExeState = New-Object System.Windows.Forms.Label
$lblExeState.Text = "Exe: —"
$lblExeState.Dock = "Fill"
$lblExeState.TextAlign = "MiddleLeft"
$top.Controls.Add($lblExeState, 0, 3)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Exe..."
$btnBrowse.Dock = "Fill"
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "jitsi-ndi-native.exe|jitsi-ndi-native.exe|Exe files|*.exe|All files|*.*"
    if ($script:exePath -and (Test-Path -LiteralPath (Split-Path $script:exePath -Parent))) {
        $dlg.InitialDirectory = Split-Path $script:exePath -Parent
    } else {
        $dlg.InitialDirectory = $script:repoRoot
    }
    if ($dlg.ShowDialog() -eq "OK") {
        $script:exePath = $dlg.FileName
        Update-ExeLabel
    }
})
$top.Controls.Add($btnBrowse, 1, 3)

$btnOpenLogs = New-Object System.Windows.Forms.Button
$btnOpenLogs.Text = "Логи"
$btnOpenLogs.Dock = "Fill"
$btnOpenLogs.Add_Click({
    $logDir = Join-Path $script:repoRoot "logs"
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    Start-Process explorer.exe $logDir
})
$top.Controls.Add($btnOpenLogs, 2, 3)

$lblSafe = New-Object System.Windows.Forms.Label
$lblSafe.Text = "Safe GUI: не меняет качество/NDI/native, только --room и опционально --nick"
$lblSafe.Dock = "Fill"
$lblSafe.TextAlign = "MiddleLeft"
$top.Controls.Add($lblSafe, 3, 3)
$top.SetColumnSpan($lblSafe, 3)

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
$split.Panel1.Controls.Add($grid)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Dock = "Fill"
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Both"
$txtLog.ReadOnly = $true
$txtLog.WordWrap = $false
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$split.Panel2.Controls.Add($txtLog)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$timer.Add_Tick({ Drain-LogQueue })
$timer.Start()

$form.Add_FormClosing({
    $timer.Stop()
    Stop-Receiver
})

$script:exePath = Find-NativeExe
Update-ExeLabel
Append-Log "[GUI v31-safe] Готово. Вставь ссылку Jitsi и нажми Старт."
Append-Log "[GUI] Этот интерфейс не трогает native-часть и не передаёт флаги качества. Если ник мешает входу, сними галочку 'передавать --nick' — останется старый режим --room."

[void][System.Windows.Forms.Application]::Run($form)
