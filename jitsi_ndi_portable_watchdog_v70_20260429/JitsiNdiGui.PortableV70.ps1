# Jitsi NDI Native GUI v70 portable watchdog - visual GUI with speaker quality link generator
# ASCII-only PowerShell script to avoid codepage/parser issues.
# Portable v70: native stdout is written to file only; GUI never displays native log live.
# Optional --nick remains exactly as in the working v59b flow.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

$ErrorActionPreference = 'Continue'
$script:proc = $null
$script:repoRoot = $PSScriptRoot
$script:selectedExePath = $null
$script:currentLogFile = $null
$script:logDir = Join-Path $script:repoRoot 'logs'
$script:lastCommand = ''
$script:isStopping = $false
$script:nativeStartedAt = $null
$script:fontCollection = $null
$script:fontFamily = $null
$script:nativeLogFile = $null
$script:nativeLogWriter = $null
$script:nativeLogSync = New-Object Object
$script:lastVideoFrameAt = $null
$script:videoSeen = $false
$script:watchdogEnabled = $true
$script:watchdogTimeoutSeconds = 45
$script:watchdogRestarting = $false

function Color-Hex {
    param([string]$Hex)
    $h = $Hex.Trim().TrimStart('#')
    if ($h.Length -ne 6) { return [System.Drawing.Color]::Black }
    return [System.Drawing.Color]::FromArgb(
        [Convert]::ToInt32($h.Substring(0,2),16),
        [Convert]::ToInt32($h.Substring(2,2),16),
        [Convert]::ToInt32($h.Substring(4,2),16)
    )
}

# Palette from supplied references.
$C_Asphalt = Color-Hex '#111111'
$C_Dark = Color-Hex '#182028'
$C_Dark2 = Color-Hex '#212B35'
$C_White = Color-Hex '#FFFA7D'
$C_Milk = Color-Hex '#FFFED6'
$C_Mel = Color-Hex '#F7F7F7'
$C_Purple = Color-Hex '#641FF1'
$C_Orange = Color-Hex '#FF9900'
$C_Lav = Color-Hex '#EEE5FF'
$C_Blue = Color-Hex '#71D2FF'
$C_Mint = Color-Hex '#D9FFD6'
$C_Green = Color-Hex '#6DDD65'
$C_Line = Color-Hex '#E7E2F2'
$C_TextSoft = Color-Hex '#6E7180'

function Load-CirceFont {
    try {
        $script:fontCollection = New-Object System.Drawing.Text.PrivateFontCollection
        $fontCandidates = @(
            (Join-Path $script:repoRoot 'gui\Circe-ExtraBold.otf'),
            (Join-Path $script:repoRoot 'gui\Circe-Bold.otf'),
            (Join-Path $script:repoRoot 'gui\Circe-Regular.otf'),
            (Join-Path $script:repoRoot 'fonts\Circe-ExtraBold.otf'),
            (Join-Path $script:repoRoot 'fonts\Circe-Bold.otf'),
            (Join-Path $script:repoRoot 'fonts\Circe-Regular.otf')
        )
        foreach ($fp in $fontCandidates) {
            if (Test-Path $fp) {
                try { $script:fontCollection.AddFontFile($fp) } catch {}
            }
        }
        if ($script:fontCollection.Families.Count -gt 0) {
            $script:fontFamily = $script:fontCollection.Families[0]
        }
    } catch {}
}

Load-CirceFont

function New-GuiFont {
    param(
        [float]$Size,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    try {
        if ($script:fontFamily) { return New-Object System.Drawing.Font($script:fontFamily, $Size, $Style, [System.Drawing.GraphicsUnit]::Point) }
    } catch {}
    try { return New-Object System.Drawing.Font('Circe', $Size, $Style, [System.Drawing.GraphicsUnit]::Point) } catch {}
    return New-Object System.Drawing.Font('Segoe UI', $Size, $Style, [System.Drawing.GraphicsUnit]::Point)
}

function Convert-JitsiInputToRoom {
    param([string]$InputText)
    $s = ("$InputText").Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return '' }
    if ($s -match '@conference\.') { return ($s -replace '@conference\..*$', '').Trim() }
    if ($s -match '^https?://') {
        try {
            $uri = [System.Uri]$s
            $path = [System.Uri]::UnescapeDataString($uri.AbsolutePath.Trim('/'))
            if (-not [string]::IsNullOrWhiteSpace($path)) { return ($path.Split('/')[0]).Trim() }
        } catch { return $s }
    }
    if ($s -match '^[^/]+\.[^/]+/(.+)$') {
        $part = $Matches[1].Split('?')[0].Split('#')[0].Trim('/')
        if ($part) { return [System.Uri]::UnescapeDataString($part.Split('/')[0]) }
    }
    return ($s.Split('?')[0].Split('#')[0].Trim('/'))
}

function Get-JitsiBaseFromInput {
    param([string]$InputText, [string]$Room)
    $s = ("$InputText").Trim()
    $encodedRoom = [System.Uri]::EscapeDataString($Room)
    if ($s -match '^https?://') {
        try {
            $uri = [System.Uri]$s
            $scheme = $uri.Scheme
            $host = $uri.Host
            if ($uri.Port -gt 0 -and -not (($scheme -eq 'https' -and $uri.Port -eq 443) -or ($scheme -eq 'http' -and $uri.Port -eq 80))) {
                $host = $host + ':' + $uri.Port
            }
            return ($scheme + '://' + $host + '/' + $encodedRoom)
        } catch {}
    }
    return ('https://meet.jit.si/' + $encodedRoom)
}

function Get-SpeakerQualityProfile {
    param([string]$QualityText)
    $q = ("$QualityText").Trim().ToLowerInvariant()
    switch ($q) {
        '480p' { return @{ Height = 480; Width = 854; Label = '480p' } }
        '540p' { return @{ Height = 540; Width = 960; Label = '540p' } }
        '720p' { return @{ Height = 720; Width = 1280; Label = '720p' } }
        default { return @{ Height = 1080; Width = 1920; Label = '1080p' } }
    }
}

function Get-SelectedSpeakerQuality {
    try {
        if ($script:cmbSpeakerQuality -and -not $script:cmbSpeakerQuality.IsDisposed -and $script:cmbSpeakerQuality.SelectedItem) {
            return [string]$script:cmbSpeakerQuality.SelectedItem
        }
    } catch {}
    return '1080p'
}

function Build-SpeakerLink {
    param([string]$InputText)
    $room = Convert-JitsiInputToRoom $InputText
    if ([string]::IsNullOrWhiteSpace($room)) { return '' }
    $base = Get-JitsiBaseFromInput $InputText $room
    $profile = Get-SpeakerQualityProfile (Get-SelectedSpeakerQuality)
    $h = [int]$profile.Height
    $w = [int]$profile.Width
    $params = @(
        "config.resolution=$h",
        "config.constraints.video.height.ideal=$h",
        "config.constraints.video.height.max=$h",
        "config.constraints.video.width.ideal=$w",
        "config.constraints.video.width.max=$w",
        'config.constraints.video.frameRate.ideal=30',
        'config.constraints.video.frameRate.max=30',
        'config.maxFullResolutionParticipants=10',
        'config.videoQuality.enableAdaptiveMode=false',
        'config.desktopSharingFrameRate.min=30',
        'config.desktopSharingFrameRate.max=30'
    )
    return ($base + '#' + ($params -join '&'))
}

function Update-SpeakerLink {
    try {
        if ($script:txtSpeakerLink -and -not $script:txtSpeakerLink.IsDisposed) {
            $script:txtSpeakerLink.Text = Build-SpeakerLink $txtRoom.Text
        }
    } catch {}
}

function Find-NativeExe {
    if ($script:selectedExePath -and (Test-Path $script:selectedExePath)) { return $script:selectedExePath }
    $candidates = @(
        (Join-Path $script:repoRoot 'build\Release\jitsi-ndi-native.exe'),
        (Join-Path $script:repoRoot 'build-ndi\Release\jitsi-ndi-native.exe'),
        (Join-Path $script:repoRoot 'build\RelWithDebInfo\jitsi-ndi-native.exe'),
        (Join-Path $script:repoRoot 'build-ndi\RelWithDebInfo\jitsi-ndi-native.exe'),
        (Join-Path $script:repoRoot 'jitsi-ndi-native.exe')
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}

function Quote-Arg {
    param([string]$s)
    if ($null -eq $s) { return '""' }
    $escaped = $s -replace '\\(?=(\\*)")', '\\'
    $escaped = $escaped -replace '"', '\"'
    return '"' + $escaped + '"'
}

function Join-ProcessArgs {
    param([string[]]$ArgsList)
    $parts = @()
    foreach ($a in $ArgsList) {
        $s = [string]$a
        if ($s -match '[\s"]') { $parts += (Quote-Arg $s) } else { $parts += $s }
    }
    return ($parts -join ' ')
}

function Append-Log {
    param([string]$line)
    try {
        $stamp = Get-Date -Format 'HH:mm:ss.fff'
        $text = "$stamp $line"
        if ($script:currentLogFile) {
            try { Add-Content -LiteralPath $script:currentLogFile -Value $text -Encoding UTF8 } catch {}
        }
        if ($script:txtLog -and -not $script:txtLog.IsDisposed) {
            try {
                $script:txtLog.AppendText($text + [Environment]::NewLine)
                if ($script:txtLog.TextLength -gt 20000) {
                    $script:txtLog.Text = $script:txtLog.Text.Substring([Math]::Max(0, $script:txtLog.TextLength - 12000))
                    $script:txtLog.SelectionStart = $script:txtLog.TextLength
                    $script:txtLog.ScrollToCaret()
                }
            } catch {}
        }
    } catch {}
}

function Close-NativeLogWriter {
    try {
        if ($script:nativeLogWriter) {
            [System.Threading.Monitor]::Enter($script:nativeLogSync)
            try {
                $script:nativeLogWriter.Flush()
                $script:nativeLogWriter.Close()
                $script:nativeLogWriter.Dispose()
            } finally {
                $script:nativeLogWriter = $null
                [System.Threading.Monitor]::Exit($script:nativeLogSync)
            }
        }
    } catch {}
}

function Write-NativeLogLine {
    param([string]$line)
    try {
        if ($null -eq $line) { return }
        if ($line -match 'NDI video frame sent:') {
            $script:videoSeen = $true
            $script:lastVideoFrameAt = Get-Date
        }
        if ($script:nativeLogWriter) {
            [System.Threading.Monitor]::Enter($script:nativeLogSync)
            try {
                $stamp = Get-Date -Format 'HH:mm:ss.fff'
                $script:nativeLogWriter.WriteLine("$stamp $line")
            } finally {
                [System.Threading.Monitor]::Exit($script:nativeLogSync)
            }
        }
    } catch {}
}

function Start-NativeFromUi {
    try {
        if ($script:proc -and -not $script:proc.HasExited) {
            Append-Log '[GUI] Native is already running.'
            return
        }
        $room = Convert-JitsiInputToRoom $txtRoom.Text
        if ([string]::IsNullOrWhiteSpace($room)) {
            [System.Windows.Forms.MessageBox]::Show($form, 'Enter Jitsi link or room name.', 'Missing room', 'OK', 'Warning') | Out-Null
            return
        }
        $exe = Find-NativeExe
        if (-not $exe) {
            [System.Windows.Forms.MessageBox]::Show($form, 'jitsi-ndi-native.exe not found in build folders.', 'Missing exe', 'OK', 'Error') | Out-Null
            return
        }
        if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $script:currentLogFile = Join-Path $script:logDir "jitsi-ndi-gui_$stamp.log"
        $script:nativeLogFile = Join-Path $script:logDir "jitsi-ndi-native_$stamp.log"
        Set-Content -LiteralPath $script:currentLogFile -Value '# Jitsi NDI GUI session log' -Encoding UTF8
        Close-NativeLogWriter
        try {
            $enc = New-Object System.Text.UTF8Encoding($false)
            $script:nativeLogWriter = New-Object System.IO.StreamWriter($script:nativeLogFile, $false, $enc)
            $script:nativeLogWriter.AutoFlush = $true
            Write-NativeLogLine "# native log redirected by portable GUI v70"
        } catch { Append-Log "[GUI] Native log file open failed: $($_.Exception.Message)" }
        $argsList = @('--room', $room)
        $nick = ("$($txtNick.Text)").Trim()
        if ($chkNick.Checked -and -not [string]::IsNullOrWhiteSpace($nick)) { $argsList += @('--nick', $nick) }
        $arguments = Join-ProcessArgs $argsList
        $script:lastCommand = (Quote-Arg $exe) + ' ' + $arguments
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = $arguments
        $psi.WorkingDirectory = Split-Path -Parent $exe
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.CreateNoWindow = $true
        try { $psi.EnvironmentVariables['PATH'] = (Split-Path -Parent $exe) + ';' + $script:repoRoot + ';' + $psi.EnvironmentVariables['PATH'] } catch {}
        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $p.EnableRaisingEvents = $true
        $p.add_OutputDataReceived({ param($sender,$e) Write-NativeLogLine $e.Data })
        $p.add_ErrorDataReceived({ param($sender,$e) Write-NativeLogLine $e.Data })
        $ok = $p.Start()
        if (-not $ok) { throw 'Process.Start returned false.' }
        try { $p.BeginOutputReadLine() } catch {}
        try { $p.BeginErrorReadLine() } catch {}
        $script:proc = $p
        $script:nativeStartedAt = Get-Date
        $script:lastVideoFrameAt = $null
        $script:videoSeen = $false
        $script:isStopping = $false
        Set-RunningUi $true
        Append-Log "[GUI] Started. PID=$($p.Id)"
        Append-Log "[GUI] Native log: $script:nativeLogFile"
    } catch {
        Append-Log "[GUI] Start failed: $($_.Exception.Message)"
        Close-NativeLogWriter
        Set-RunningUi $false
        Update-VisualLayout
    }
}

function Set-ButtonStyle {
    param(
        [System.Windows.Forms.Button]$Button,
        [System.Drawing.Color]$Back,
        [System.Drawing.Color]$Fore,
        [bool]$Primary = $false
    )
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.FlatAppearance.BorderSize = 0
    $Button.BackColor = $Back
    $Button.ForeColor = $Fore
    $Button.Font = New-GuiFont $(if ($Primary) { 11 } else { 9.5 }) ([System.Drawing.FontStyle]::Bold)
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
}

function New-Label {
    param([string]$Text, [int]$X, [int]$Y, [int]$W, [int]$H, [float]$Size = 9.5, [object]$Fore = $null, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    $l.Size = New-Object System.Drawing.Size($W, $H)
    $l.Font = New-GuiFont $Size $Style
    $l.BackColor = [System.Drawing.Color]::Transparent
    if ($null -ne $Fore) { $l.ForeColor = [System.Drawing.Color]$Fore } else { $l.ForeColor = $C_Asphalt }
    return $l
}

function Set-RunningUi {
    param([bool]$running)
    try {
        $btnStart.Enabled = -not $running
        $btnStop.Enabled = $running
        $txtRoom.Enabled = -not $running
        $txtNick.Enabled = -not $running
        $chkNick.Enabled = -not $running
        if ($running) {
            $lblStatus.Text = 'CONNECTED'
            $lblStatus.BackColor = $C_Mint
            $lblStatus.ForeColor = Color-Hex '#207A1E'
            $lblStatusHint.Text = 'native process is running'
        } else {
            $lblStatus.Text = 'STOP'
            $lblStatus.BackColor = $C_Lav
            $lblStatus.ForeColor = $C_Orange
            $lblStatusHint.Text = 'ready to connect'
        }
    } catch {}
}

function Stop-NativeProcess {
    param([string]$Reason)
    try {
        $script:isStopping = $true
        if ($script:proc -and -not $script:proc.HasExited) {
            Append-Log "[GUI] Stopping native process... $Reason"
            try { $script:proc.Kill() } catch {}
            try { $script:proc.WaitForExit(3000) | Out-Null } catch {}
        }
    } catch {}
    Close-NativeLogWriter
    Set-RunningUi $false
Update-VisualLayout
}

# UI shell
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Jitsi NDI'
$form.Size = New-Object System.Drawing.Size(760, 690)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(740, 650)
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
$form.SizeGripStyle = [System.Windows.Forms.SizeGripStyle]::Show
$form.Font = New-GuiFont 9.5
$form.BackColor = $C_Mel

$form.Add_Paint({
    param($sender, $e)
    try {
        $rect = $form.ClientRectangle
        $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $C_Lav, $C_Milk, 35)
        $e.Graphics.FillRectangle($b, $rect)
        $b.Dispose()
        $accentRect = New-Object System.Drawing.Rectangle(0, 0, $form.ClientSize.Width, 150)
        $b2 = New-Object System.Drawing.Drawing2D.LinearGradientBrush($accentRect, [System.Drawing.Color]::FromArgb(95, $C_Orange), [System.Drawing.Color]::FromArgb(45, $C_Purple), 0)
        $e.Graphics.FillRectangle($b2, $accentRect)
        $b2.Dispose()
    } catch {}
})

# Top title
$lblLogo = New-Label 'Jitsi NDI' 0 26 760 70 33 $C_Orange ([System.Drawing.FontStyle]::Bold)
$lblLogo.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$form.Controls.Add($lblLogo)

$lblSub = New-Label '' 0 88 760 24 11 $C_Asphalt ([System.Drawing.FontStyle]::Regular)
$lblSub.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$form.Controls.Add($lblSub)

# Main white card
$card = New-Object System.Windows.Forms.Panel
$card.Location = New-Object System.Drawing.Point(82, 128)
$card.Size = New-Object System.Drawing.Size(596, 350)
$card.BackColor = [System.Drawing.Color]::FromArgb(248, 248, 248)
$card.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$card.Add_Paint({
    param($sender, $e)
    try {
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $r = New-Object System.Drawing.Rectangle(0,0,($card.Width-1),($card.Height-1))
        $pen = New-Object System.Drawing.Pen($C_Line, 1)
        $g.DrawRectangle($pen, $r)
        $pen.Dispose()
    } catch {}
})
$form.Controls.Add($card)

# Form fields inside card
$lblRoom = New-Label 'Meeting link' 36 32 130 24 10 $C_TextSoft
$card.Controls.Add($lblRoom)

$txtRoom = New-Object System.Windows.Forms.TextBox
$txtRoom.Location = New-Object System.Drawing.Point(170, 29)
$txtRoom.Size = New-Object System.Drawing.Size(370, 28)
$txtRoom.Font = New-GuiFont 10
$txtRoom.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$txtRoom.BackColor = [System.Drawing.Color]::White
$txtRoom.Text = ''
$card.Controls.Add($txtRoom)

$lblParsed = New-Label 'Room:' 170 61 370 20 8.8 $C_TextSoft
$card.Controls.Add($lblParsed)

$lblSpeaker = New-Label 'Speaker link' 36 92 130 24 10 $C_TextSoft
$card.Controls.Add($lblSpeaker)

$txtSpeakerLink = New-Object System.Windows.Forms.TextBox
$script:txtSpeakerLink = $txtSpeakerLink
$txtSpeakerLink.Location = New-Object System.Drawing.Point(170, 89)
$txtSpeakerLink.Size = New-Object System.Drawing.Size(292, 28)
$txtSpeakerLink.Font = New-GuiFont 8.8
$txtSpeakerLink.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$txtSpeakerLink.BackColor = [System.Drawing.Color]::White
$txtSpeakerLink.ReadOnly = $true
$card.Controls.Add($txtSpeakerLink)

$cmbSpeakerQuality = New-Object System.Windows.Forms.ComboBox
$script:cmbSpeakerQuality = $cmbSpeakerQuality
$cmbSpeakerQuality.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$cmbSpeakerQuality.Items.Add('480p')
[void]$cmbSpeakerQuality.Items.Add('540p')
[void]$cmbSpeakerQuality.Items.Add('720p')
[void]$cmbSpeakerQuality.Items.Add('1080p')
$cmbSpeakerQuality.SelectedItem = '1080p'
$cmbSpeakerQuality.Location = New-Object System.Drawing.Point(468, 89)
$cmbSpeakerQuality.Size = New-Object System.Drawing.Size(78, 28)
$cmbSpeakerQuality.Font = New-GuiFont 9
$cmbSpeakerQuality.BackColor = [System.Drawing.Color]::White
$cmbSpeakerQuality.ForeColor = $C_Asphalt
$card.Controls.Add($cmbSpeakerQuality)

$btnCopySpeaker = New-Object System.Windows.Forms.Button
$btnCopySpeaker.Text = 'Copy'
$btnCopySpeaker.Location = New-Object System.Drawing.Point(552, 87)
$btnCopySpeaker.Size = New-Object System.Drawing.Size(68, 31)
Set-ButtonStyle $btnCopySpeaker $C_Orange $C_Asphalt
$card.Controls.Add($btnCopySpeaker)

$lblNick = New-Label 'Your name' 36 148 130 24 10 $C_TextSoft
$card.Controls.Add($lblNick)

$txtNick = New-Object System.Windows.Forms.TextBox
$txtNick.Location = New-Object System.Drawing.Point(170, 145)
$txtNick.Size = New-Object System.Drawing.Size(370, 28)
$txtNick.Font = New-GuiFont 10
$txtNick.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$txtNick.BackColor = [System.Drawing.Color]::White
$txtNick.Text = 'STREAM'
$card.Controls.Add($txtNick)

$chkNick = New-Object System.Windows.Forms.CheckBox
$chkNick.Text = 'send display name on next start'
$chkNick.Location = New-Object System.Drawing.Point(170, 179)
$chkNick.Size = New-Object System.Drawing.Size(260, 24)
$chkNick.Font = New-GuiFont 9.5
$chkNick.BackColor = [System.Drawing.Color]::Transparent
$chkNick.ForeColor = $C_Asphalt
$chkNick.Checked = $true
$card.Controls.Add($chkNick)

$lblNickNote = New-Label '' 170 206 370 22 8.8 $C_TextSoft
$card.Controls.Add($lblNickNote)

$statusBox = New-Object System.Windows.Forms.Panel
$statusBox.Location = New-Object System.Drawing.Point(36, 246)
$statusBox.Size = New-Object System.Drawing.Size(504, 62)
$statusBox.BackColor = [System.Drawing.Color]::White
$statusBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$card.Controls.Add($statusBox)

$lblStatusTitle = New-Label 'STATUS' 18 10 90 22 8.5 $C_TextSoft ([System.Drawing.FontStyle]::Bold)
$statusBox.Controls.Add($lblStatusTitle)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(112, 12)
$lblStatus.Size = New-Object System.Drawing.Size(120, 30)
$lblStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$lblStatus.Font = New-GuiFont 11 ([System.Drawing.FontStyle]::Bold)
$statusBox.Controls.Add($lblStatus)

$lblStatusHint = New-Label 'ready to connect' 246 16 230 22 9 $C_TextSoft
$statusBox.Controls.Add($lblStatusHint)

# Footer with existing controls
$footer = New-Object System.Windows.Forms.Panel
$footer.Location = New-Object System.Drawing.Point(0, 462)
$footer.Size = New-Object System.Drawing.Size(760, 88)
$footer.Anchor = 'Left,Right,Bottom'
$footer.BackColor = $C_Dark
$form.Controls.Add($footer)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = 'CONNECT'
$btnStart.Location = New-Object System.Drawing.Point(24, 22)
$btnStart.Size = New-Object System.Drawing.Size(132, 42)
Set-ButtonStyle $btnStart $C_Orange $C_Asphalt $true
$footer.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = 'STOP'
$btnStop.Location = New-Object System.Drawing.Point(166, 22)
$btnStop.Size = New-Object System.Drawing.Size(108, 42)
$btnStop.Enabled = $false
Set-ButtonStyle $btnStop $C_Dark2 $C_Milk $true
$footer.Controls.Add($btnStop)



$btnOpenLog = New-Object System.Windows.Forms.Button
$btnOpenLog.Text = 'Open log'
$btnOpenLog.Location = New-Object System.Drawing.Point(520, 22)
$btnOpenLog.Size = New-Object System.Drawing.Size(96, 42)
Set-ButtonStyle $btnOpenLog $C_Dark2 $C_Milk
$footer.Controls.Add($btnOpenLog)

$btnLogs = New-Object System.Windows.Forms.Button
$btnLogs.Text = 'Logs folder'
$btnLogs.Location = New-Object System.Drawing.Point(626, 22)
$btnLogs.Size = New-Object System.Drawing.Size(110, 42)
Set-ButtonStyle $btnLogs $C_Dark2 $C_Milk
$footer.Controls.Add($btnLogs)


# Compact GUI log
$txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog = $txtLog
$txtLog.Location = New-Object System.Drawing.Point(82, 438)
$txtLog.Size = New-Object System.Drawing.Size(596, 16)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'None'
$txtLog.ReadOnly = $true
$txtLog.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$txtLog.BackColor = $C_Mel
$txtLog.ForeColor = $C_TextSoft
$txtLog.Font = New-GuiFont 8.5
$form.Controls.Add($txtLog)

function Update-VisualLayout {
    try {
        $w = [int]$form.ClientSize.Width
        if ($w -lt 740) { $w = 740 }
        $lblLogo.Width = $w
        $lblSub.Width = $w
        $cardW = [Math]::Min(680, [Math]::Max(596, $w - 96))
        $card.Left = [int](($w - $cardW) / 2)
        $card.Width = $cardW
        $fieldW = [Math]::Max(260, $card.Width - 226)
        $txtRoom.Width = $fieldW
        $lblParsed.Width = $fieldW
        $copyW = 68
        $qualityW = 78
        $gap = 10
        $txtSpeakerLink.Width = [Math]::Max(150, $fieldW - $qualityW - $copyW - ($gap * 2))
        $cmbSpeakerQuality.Left = 170 + $txtSpeakerLink.Width + $gap
        $cmbSpeakerQuality.Width = $qualityW
        $btnCopySpeaker.Left = $cmbSpeakerQuality.Left + $qualityW + $gap
        $txtNick.Width = $fieldW
        $chkNick.Width = $fieldW
        $lblNickNote.Width = $fieldW
        $statusBox.Width = $card.Width - 72
        $lblStatusHint.Width = [Math]::Max(120, $statusBox.Width - 266)
        $footer.Top = $form.ClientSize.Height - 88
        $footer.Width = $form.ClientSize.Width
        $right = $form.ClientSize.Width - 24
        $btnLogs.Left = $right - $btnLogs.Width
        $btnOpenLog.Left = $btnLogs.Left - 10 - $btnOpenLog.Width
        $txtLog.Left = $card.Left
        $txtLog.Width = $card.Width
        $txtLog.Top = $footer.Top - 20
        $form.Invalidate()
        $card.Invalidate()
    } catch {}
}

$form.Add_Resize({ Update-VisualLayout })

$cmbSpeakerQuality.Add_SelectedIndexChanged({ Update-SpeakerLink })

$txtRoom.Add_TextChanged({
    try {
        $room = Convert-JitsiInputToRoom $txtRoom.Text
        if ($room) { $lblParsed.Text = "Room: $room" } else { $lblParsed.Text = 'Room:' }
        Update-SpeakerLink
    } catch {}
})
$lblParsed.Text = 'Room: ' + (Convert-JitsiInputToRoom $txtRoom.Text)
Update-SpeakerLink

$btnCopySpeaker.Add_Click({
    try {
        $link = Build-SpeakerLink $txtRoom.Text
        if ([string]::IsNullOrWhiteSpace($link)) {
            [System.Windows.Forms.MessageBox]::Show($form, 'Enter Jitsi link or room name first.', 'Speaker link', 'OK', 'Warning') | Out-Null
            return
        }
        [System.Windows.Forms.Clipboard]::SetText($link)
        Append-Log ("[GUI] Speaker link copied. Quality=" + (Get-SelectedSpeakerQuality))
    } catch { Append-Log "[GUI] Copy speaker link failed: $($_.Exception.Message)" }
})

$btnOpenLog.Add_Click({
    try {
        if ($script:currentLogFile -and (Test-Path $script:currentLogFile)) {
            Start-Process notepad.exe $script:currentLogFile
        } else { Append-Log '[GUI] No GUI log file yet.' }
    } catch { Append-Log "[GUI] Open log failed: $($_.Exception.Message)" }
})

$btnLogs.Add_Click({
    try {
        if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null }
        Start-Process explorer.exe $script:logDir
    } catch { Append-Log "[GUI] Open logs folder failed: $($_.Exception.Message)" }
})

$btnStart.Add_Click({ Start-NativeFromUi })

$btnStop.Add_Click({ Stop-NativeProcess 'Stop button' })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        if ($script:proc) {
            if ($script:proc.HasExited) {
                if (-not $script:isStopping) { Append-Log "[GUI] Native exited with code $($script:proc.ExitCode)." }
                Close-NativeLogWriter
                $script:proc = $null
                Set-RunningUi $false
Update-VisualLayout
            } else {
                if ($script:nativeStartedAt) {
                    $elapsed = [int]((Get-Date) - $script:nativeStartedAt).TotalSeconds
                    $hint = "native process running: ${elapsed}s"
                    if ($script:videoSeen -and $script:lastVideoFrameAt) {
                        $age = [int]((Get-Date) - $script:lastVideoFrameAt).TotalSeconds
                        $hint = $hint + " | video age: ${age}s"
                        if ($script:watchdogEnabled -and -not $script:watchdogRestarting -and $age -gt $script:watchdogTimeoutSeconds) {
                            $script:watchdogRestarting = $true
                            Append-Log "[GUI] Video watchdog: no NDI video frames for ${age}s. Restarting native."
                            Stop-NativeProcess 'video watchdog'
                            Start-NativeFromUi
                            $script:watchdogRestarting = $false
                            return
                        }
                    }
                    $lblStatusHint.Text = $hint
                }
            }
        }
    } catch {}
})
$timer.Start()

$form.Add_FormClosing({
    param($sender, $e)
    try {
        if ($script:proc -and -not $script:proc.HasExited) {
            $result = [System.Windows.Forms.MessageBox]::Show(
                $form,
                'Native process is still running. YES = stop native and close. NO = keep GUI open.',
                'Close GUI?',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                Stop-NativeProcess 'GUI closing'
            } else {
                $e.Cancel = $true
                return
            }
        }
    } catch {}
})

Set-RunningUi $false
Update-VisualLayout
[void]$form.ShowDialog()
