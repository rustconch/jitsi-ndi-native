# Jitsi NDI Native - simple Windows GUI launcher
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
}

function Parse-Line {
    param([string]$line)

    if ([string]::IsNullOrWhiteSpace($line)) { return }

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

        $key = $displayName
        if ($displayName -match "([A-Za-z0-9]{6,})(?:-|$)") { $key = $Matches[1] }

        $kind = Get-SourceKind -sourceKey $key -sourceName $sourceName
        $row = Ensure-Row -key $key -endpoint $key -displayName $displayName -kind $kind
        if ($row) { $row.Cells["Resolution"].Value = "${w}x${h}" }
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

    $exePath = $txtExe.Text.Trim()
    if (-not (Test-Path $exePath)) {
        [System.Windows.Forms.MessageBox]::Show("Не найден exe:`n$exePath", "Jitsi NDI GUI") | Out-Null
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

    if ($chkPassNativeFlags.Checked) {
        $nick = (Sanitize-Name $txtNick.Text)
        if (-not [string]::IsNullOrWhiteSpace($nick)) {
            $args.Add("--nick")
            $args.Add($nick)
        }

        $q = [string]$cmbQuality.SelectedItem
        if ($q -and $q -ne "current/native") {
            $height = ($q -replace "[^\d]", "")
            if ($height) {
                $args.Add("--quality")
                $args.Add($height)
            }
        }
    }

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
    $txtLog.Clear()
    Append-Log ("[GUI] Starting: " + $psi.FileName + " " + $psi.Arguments)
    Append-Log ("[GUI] Parsed room: " + $room)

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
            $btnStart.Enabled = $true
            $btnStop.Enabled = $false
            $lblState.Text = "Остановлен"
        }
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

    if ($btnStart -and -not $btnStart.IsDisposed) { $btnStart.Enabled = $true }
    if ($btnStop -and -not $btnStop.IsDisposed) { $btnStop.Enabled = $false }
    if ($lblState -and -not $lblState.IsDisposed) { $lblState.Text = "Остановлен" }
}

# ---------------- UI ----------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "Jitsi NDI Native GUI"
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

Add-Label "Exe:" 1 0 | Out-Null
$txtExe = New-Object System.Windows.Forms.TextBox
$txtExe.Dock = "Fill"
$txtExe.Text = (Join-Path $PSScriptRoot "build\Release\jitsi-ndi-native.exe")
$top.Controls.Add($txtExe, 1, 1)
$top.SetColumnSpan($txtExe, 3)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = "Обзор..."
$btnBrowse.Dock = "Fill"
$btnBrowse.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "jitsi-ndi-native.exe|jitsi-ndi-native.exe|Exe files|*.exe|All files|*.*"
    $dlg.InitialDirectory = Split-Path $txtExe.Text -Parent
    if ($dlg.ShowDialog() -eq "OK") { $txtExe.Text = $dlg.FileName }
})
$top.Controls.Add($btnBrowse, 4, 1)
$top.SetColumnSpan($btnBrowse, 2)

Add-Label "Ник в Jitsi:" 2 0 | Out-Null
$txtNick = New-Object System.Windows.Forms.TextBox
$txtNick.Dock = "Fill"
$txtNick.Text = "Jitsi NDI"
$top.Controls.Add($txtNick, 1, 2)

Add-Label "Качество:" 2 2 | Out-Null
$cmbQuality = New-Object System.Windows.Forms.ComboBox
$cmbQuality.Dock = "Fill"
$cmbQuality.DropDownStyle = "DropDownList"
[void]$cmbQuality.Items.Add("current/native")
[void]$cmbQuality.Items.Add("720p")
[void]$cmbQuality.Items.Add("1080p")
[void]$cmbQuality.Items.Add("2160p")
$cmbQuality.SelectedIndex = 0
$top.Controls.Add($cmbQuality, 3, 2)

$chkPassNativeFlags = New-Object System.Windows.Forms.CheckBox
$chkPassNativeFlags.Text = "передавать --nick/--quality"
$chkPassNativeFlags.Dock = "Fill"
$chkPassNativeFlags.Checked = $false
$top.Controls.Add($chkPassNativeFlags, 4, 2)
$top.SetColumnSpan($chkPassNativeFlags, 2)

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

$split.Panel1.Controls.Add($grid)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Dock = "Fill"
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Both"
$txtLog.ReadOnly = $true
$txtLog.WordWrap = $false
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$split.Panel2.Controls.Add($txtLog)

$form.Add_FormClosing({
    Stop-Receiver
})

Append-Log "[GUI v29-fix2] Готово. Вставь ссылку Jitsi и нажми Старт."
Append-Log "[GUI] Примечание: --nick/--quality включай только после добавления этих флагов в native exe."

[void][System.Windows.Forms.Application]::Run($form)
