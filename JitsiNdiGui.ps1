# Jitsi NDI Native GUI v68 - Full Dark UI Rebuild (Reference: htathtyc.png)
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
$script:logoFontFamily = $null
$script:statusRunning = $false

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

$C_BgPurple    = Color-Hex '#211654'
$C_BgGlow      = Color-Hex '#FF9900'
$C_InputBg     = Color-Hex '#1B143D'
$C_InputBorder = Color-Hex '#3E346E'
$C_LabelText   = Color-Hex '#FFFFFF'
$C_WhiteText   = Color-Hex '#FFFFFF'
$C_Orange      = Color-Hex '#FF8C00'
$C_OrangeHover = Color-Hex '#FFAD40'
$C_IconBg      = Color-Hex '#31266B'
$C_DarkButton  = Color-Hex '#1C153E'
$C_Green       = Color-Hex '#6DDD65'

function New-RoundedPath {
    param([System.Drawing.Rectangle]$Rect, [int]$Radius)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    if ($d -le 0) { $d = 1 }
    $path.AddArc($Rect.X,            $Rect.Y,             $d, $d, 180, 90)
    $path.AddArc(($Rect.Right - $d), $Rect.Y,             $d, $d, 270, 90)
    $path.AddArc(($Rect.Right - $d), ($Rect.Bottom - $d), $d, $d,   0, 90)
    $path.AddArc($Rect.X,            ($Rect.Bottom - $d), $d, $d,  90, 90)
    $path.CloseFigure()
    return $path
}

function Load-Fonts {
    try {
        $script:fontCollection = New-Object System.Drawing.Text.PrivateFontCollection
        $fontCandidates = @(
            (Join-Path $script:repoRoot 'gui\TT Foxford ExtraBold.otf'),
            (Join-Path $script:repoRoot 'gui\Circe-ExtraBold.otf'),
            (Join-Path $script:repoRoot 'gui\Circe-Bold.otf'),
            (Join-Path $script:repoRoot 'gui\Circe-Regular.otf'),
            (Join-Path $script:repoRoot 'fonts\TT Foxford ExtraBold.otf'),
            (Join-Path $script:repoRoot 'fonts\Circe-ExtraBold.otf')
        )
        foreach ($fp in $fontCandidates) {
            if (Test-Path $fp) {
                try { $script:fontCollection.AddFontFile($fp) } catch {}
            }
        }
        foreach ($fam in $script:fontCollection.Families) {
            if ($fam.Name -match 'Foxford') { $script:logoFontFamily = $fam }
            if ($fam.Name -match 'Circe' -and -not $script:fontFamily) { $script:fontFamily = $fam }
        }
        if (-not $script:fontFamily -and $script:fontCollection.Families.Count -gt 0) {
            $script:fontFamily = $script:fontCollection.Families[0]
        }
    } catch {}
}

Load-Fonts

function New-GuiFont {
    param(
        [float]$Size,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular,
        [bool]$Logo = $false
    )
    try {
        if ($Logo -and $script:logoFontFamily) { return New-Object System.Drawing.Font($script:logoFontFamily, $Size, $Style, [System.Drawing.GraphicsUnit]::Point) }
        if ($script:fontFamily) { return New-Object System.Drawing.Font($script:fontFamily, $Size, $Style, [System.Drawing.GraphicsUnit]::Point) }
    } catch {}
    try { return New-Object System.Drawing.Font('Circe', $Size, $Style, [System.Drawing.GraphicsUnit]::Point) } catch {}
    return New-Object System.Drawing.Font('Segoe UI', $Size, $Style, [System.Drawing.GraphicsUnit]::Point)
}

$fontTitle = New-GuiFont 28 ([System.Drawing.FontStyle]::Bold) $true
$fontLabel = New-GuiFont 11 ([System.Drawing.FontStyle]::Regular) $false
$fontInput = New-GuiFont 12 ([System.Drawing.FontStyle]::Regular) $false
$fontBtn   = New-GuiFont 13 ([System.Drawing.FontStyle]::Bold) $false
$fontIcon  = New-GuiFont 18 ([System.Drawing.FontStyle]::Bold) $false

# Data Methods
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
        if ($script:cmbQuality -and -not $script:cmbQuality.IsDisposed -and $script:cmbQuality.SelectedItem) {
            return [string]$script:cmbQuality.SelectedItem
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
            $script:txtSpeakerLink.Text = Build-SpeakerLink $script:txtRoom.Text
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
    } catch {}
}

function Set-RunningUi {
    param([bool]$running)
    try {
        $script:txtRoom.Enabled = -not $running
        $script:txtNick.Enabled = -not $running
        $script:cmbQuality.Enabled = -not $running
        $script:statusRunning = $running
        $script:form.Invalidate()
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
    Set-RunningUi $false
}

function Start-Click {
    try {
        if ($script:proc -and -not $script:proc.HasExited) {
            Append-Log '[GUI] Native is already running.'
            return
        }

        $room = Convert-JitsiInputToRoom $script:txtRoom.Text
        if ([string]::IsNullOrWhiteSpace($room)) {
            [System.Windows.Forms.MessageBox]::Show($script:form, 'Enter Jitsi link or room name.', 'Missing room', 'OK', 'Warning') | Out-Null
            return
        }

        $exe = Find-NativeExe
        if (-not $exe) {
            [System.Windows.Forms.MessageBox]::Show($script:form, 'jitsi-ndi-native.exe not found in build folders.', 'Missing exe', 'OK', 'Error') | Out-Null
            return
        }

        if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $script:currentLogFile = Join-Path $script:logDir "jitsi-ndi-gui_$stamp.log"
        Set-Content -LiteralPath $script:currentLogFile -Value '# Jitsi NDI GUI session log' -Encoding UTF8

        $argsList = @('--room', $room)
        $nick = ("$($script:txtNick.Text)").Trim()
        if (-not [string]::IsNullOrWhiteSpace($nick)) {
            $argsList += @('--nick', $nick)
        }

        $arguments = Join-ProcessArgs $argsList
        $script:lastCommand = (Quote-Arg $exe) + ' ' + $arguments

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = $arguments
        $psi.WorkingDirectory = Split-Path -Parent $exe
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError = $false
        $psi.CreateNoWindow = $false

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $ok = $p.Start()
        if (-not $ok) { throw 'Process.Start returned false.' }
        $script:proc = $p
        $script:nativeStartedAt = Get-Date
        $script:isStopping = $false
        Set-RunningUi $true
        Append-Log "[GUI] Started. PID=$($p.Id)"
    } catch {
        Append-Log "[GUI] Start failed: $($_.Exception.Message)"
        Set-RunningUi $false
    }
}

function Log-Click {
    try {
        if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null }
        Start-Process explorer.exe $script:logDir
    } catch { Append-Log "[GUI] Open logs folder failed: $($_.Exception.Message)" }
}

function Copy-Click {
    try {
        $link = Build-SpeakerLink $script:txtRoom.Text
        if ([string]::IsNullOrWhiteSpace($link)) {
            [System.Windows.Forms.MessageBox]::Show($script:form, 'Enter Jitsi link or room name first.', 'Speaker link', 'OK', 'Warning') | Out-Null
            return
        }
        [System.Windows.Forms.Clipboard]::SetText($link)
        Append-Log ("[GUI] Speaker link copied. Quality=" + (Get-SelectedSpeakerQuality))
    } catch { Append-Log "[GUI] Copy speaker link failed: $($_.Exception.Message)" }
}

# ── Form ──────────────────────────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$script:form = $form
$form.Text = 'Jitsi NDI'
$form.Size = New-Object System.Drawing.Size(840, 580)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.DoubleBuffered = $true

# Controls
$txtRoom = New-Object System.Windows.Forms.TextBox
$script:txtRoom = $txtRoom
$txtRoom.Location = New-Object System.Drawing.Point(125, 126)
$txtRoom.Size = New-Object System.Drawing.Size(650, 24)
$txtRoom.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$txtRoom.BackColor = $C_InputBg
$txtRoom.ForeColor = $C_WhiteText
$txtRoom.Font = $fontInput
$txtRoom.Text = ''
$form.Controls.Add($txtRoom)

$txtSpeakerLink = New-Object System.Windows.Forms.TextBox
$script:txtSpeakerLink = $txtSpeakerLink
$txtSpeakerLink.Location = New-Object System.Drawing.Point(125, 226)
$txtSpeakerLink.Size = New-Object System.Drawing.Size(430, 24)
$txtSpeakerLink.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$txtSpeakerLink.BackColor = $C_InputBg
$txtSpeakerLink.ForeColor = $C_WhiteText
$txtSpeakerLink.Font = $fontInput
$txtSpeakerLink.ReadOnly = $true
$form.Controls.Add($txtSpeakerLink)

$cmbQuality = New-Object System.Windows.Forms.ComboBox
$script:cmbQuality = $cmbQuality
$cmbQuality.Location = New-Object System.Drawing.Point(650, 223)
$cmbQuality.Size = New-Object System.Drawing.Size(120, 28)
$cmbQuality.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$cmbQuality.BackColor = $C_InputBg
$cmbQuality.ForeColor = $C_WhiteText
$cmbQuality.Font = $fontInput
$cmbQuality.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
[void]$cmbQuality.Items.Add('480p')
[void]$cmbQuality.Items.Add('540p')
[void]$cmbQuality.Items.Add('720p')
[void]$cmbQuality.Items.Add('1080p')
$cmbQuality.SelectedItem = '1080p'
$form.Controls.Add($cmbQuality)

$txtNick = New-Object System.Windows.Forms.TextBox
$script:txtNick = $txtNick
$txtNick.Location = New-Object System.Drawing.Point(125, 326)
$txtNick.Size = New-Object System.Drawing.Size(650, 24)
$txtNick.BorderStyle = [System.Windows.Forms.BorderStyle]::None
$txtNick.BackColor = $C_InputBg
$txtNick.ForeColor = $C_WhiteText
$txtNick.Font = $fontInput
$txtNick.Text = 'STREAM'
$form.Controls.Add($txtNick)

# Interactive Regions
$btnConnectRect = New-Object System.Drawing.Rectangle(40, 420, 360, 60)
$btnStopRect    = New-Object System.Drawing.Rectangle(420, 420, 370, 60)
$btnLogRect     = New-Object System.Drawing.Rectangle(600, 30, 190, 40)
$btnCopyRect    = New-Object System.Drawing.Rectangle(565, 215, 75, 46)

$script:hoverConnect = $false
$script:hoverStop = $false
$script:hoverLog = $false
$script:hoverCopy = $false

$form.Add_MouseMove({
    param($sender, $e)
    $x = $e.X; $y = $e.Y
    $newHoverC = $btnConnectRect.Contains($x, $y)
    $newHoverS = $btnStopRect.Contains($x, $y)
    $newHoverL = $btnLogRect.Contains($x, $y)
    $newHoverCp = $btnCopyRect.Contains($x, $y)
    
    if ($newHoverC -ne $script:hoverConnect -or $newHoverS -ne $script:hoverStop -or $newHoverL -ne $script:hoverLog -or $newHoverCp -ne $script:hoverCopy) {
        $script:hoverConnect = $newHoverC
        $script:hoverStop = $newHoverS
        $script:hoverLog = $newHoverL
        $script:hoverCopy = $newHoverCp
        if ($newHoverC -or $newHoverS -or $newHoverL -or $newHoverCp) {
            $form.Cursor = [System.Windows.Forms.Cursors]::Hand
        } else {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
        $form.Invalidate()
    }
})

$form.Add_MouseClick({
    param($sender, $e)
    $x = $e.X; $y = $e.Y
    if ($btnConnectRect.Contains($x, $y)) { Start-Click }
    if ($btnStopRect.Contains($x, $y)) { Stop-NativeProcess 'Stop button' }
    if ($btnLogRect.Contains($x, $y)) { Log-Click }
    if ($btnCopyRect.Contains($x, $y)) { Copy-Click }
})

# Paint Event
$form.Add_Paint({
    param($sender, $e)
    try {
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit

        # 1. Fill base dark background
        $g.Clear($C_BgPurple)

        # 2. Draw glow at bottom left
        $glowPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $glowPath.AddEllipse(-150, $form.ClientSize.Height - 250, 500, 500)
        $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush($glowPath)
        $pgb.CenterColor = [System.Drawing.Color]::FromArgb(140, 255, 153, 0)
        $pgb.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 255, 153, 0))
        $g.FillPath($pgb, $glowPath)
        $pgb.Dispose(); $glowPath.Dispose()

        # Brushes & Pens
        $bWhite = New-Object System.Drawing.SolidBrush($C_WhiteText)
        $bOrange = New-Object System.Drawing.SolidBrush($C_Orange)
        $bInput = New-Object System.Drawing.SolidBrush($C_InputBg)
        $bIcon = New-Object System.Drawing.SolidBrush($C_IconBg)
        $penBorder = New-Object System.Drawing.Pen($C_InputBorder, 1)

        # 3. Draw Title
        $g.DrawString("Jitsi", $fontTitle, $bWhite, 40, 25)
        $jitsiSize = $g.MeasureString("Jitsi ", $fontTitle)
        $g.DrawString("NDI", $fontTitle, $bOrange, 40 + $jitsiSize.Width - 15, 25)

        # 4. Draw Labels
        $g.DrawString("ВСТАВЬТЕ ССЫЛКУ НА КОНФЕРЕНЦИЮ JITSI", $fontLabel, $bWhite, 110, 85)
        $g.DrawString("ССЫЛКА ДЛЯ СПИКЕРА", $fontLabel, $bWhite, 110, 185)
        $g.DrawString("ВЫБЕРИТЕ НИК", $fontLabel, $bWhite, 110, 285)

        # 5. Draw Input Backgrounds
        function Draw-Box($x, $y, $w, $h, $brush) {
            $rect = New-Object System.Drawing.Rectangle($x, $y, $w, $h)
            $p = New-RoundedPath $rect 10
            $g.FillPath($brush, $p)
            $g.DrawPath($penBorder, $p)
            $p.Dispose()
        }

        Draw-Box 110 115 680 46 $bInput
        Draw-Box 110 215 440 46 $bInput
        Draw-Box 640 215 150 46 $bInput # Combobox wrapper
        Draw-Box 110 315 680 46 $bInput

        # 6. Draw Icon Boxes
        Draw-Box 40 115 50 46 $bIcon
        Draw-Box 40 215 50 46 $bIcon
        Draw-Box 40 315 50 46 $bIcon
        
        # Simple glyphs for icons
        $g.DrawString(">", $fontIcon, $bOrange, 50, 122)
        $g.DrawString("@", $fontIcon, $bOrange, 50, 222)
        $g.DrawString("ID", $fontIcon, $bOrange, 50, 322)

        # 7. Draw Buttons
        # CONNECT Button
        $cPath = New-RoundedPath $btnConnectRect 14
        $cBrush = if ($script:hoverConnect) { New-Object System.Drawing.SolidBrush($C_OrangeHover) } else { New-Object System.Drawing.SolidBrush($C_Orange) }
        $g.FillPath($cBrush, $cPath)
        $g.DrawString("CONNECT", $fontBtn, $bWhite, $btnConnectRect.X + 130, $btnConnectRect.Y + 20)
        $cPath.Dispose(); $cBrush.Dispose()

        # STOP Button
        $sPath = New-RoundedPath $btnStopRect 14
        $sBrush = if ($script:hoverStop) { New-Object System.Drawing.SolidBrush($C_IconBg) } else { New-Object System.Drawing.SolidBrush($C_DarkButton) }
        $g.FillPath($sBrush, $sPath)
        $penOrange = New-Object System.Drawing.Pen($C_Orange, 2)
        $g.DrawPath($penOrange, $sPath)
        $g.DrawString("STOP", $fontBtn, $bOrange, $btnStopRect.X + 150, $btnStopRect.Y + 20)
        $sPath.Dispose(); $sBrush.Dispose()

        # OPEN LOG FOLDER Button
        $lPath = New-RoundedPath $btnLogRect 10
        $lBrush = if ($script:hoverLog) { New-Object System.Drawing.SolidBrush($C_IconBg) } else { New-Object System.Drawing.SolidBrush($C_BgPurple) }
        $g.FillPath($lBrush, $lPath)
        $g.DrawPath($penOrange, $lPath)
        $g.DrawString("OPEN LOG FOLDER", $fontLabel, $bOrange, $btnLogRect.X + 25, $btnLogRect.Y + 10)
        $lPath.Dispose(); $lBrush.Dispose()

        # COPY Button
        $cpPath = New-RoundedPath $btnCopyRect 10
        $cpBrush = if ($script:hoverCopy) { New-Object System.Drawing.SolidBrush($C_OrangeHover) } else { New-Object System.Drawing.SolidBrush($C_Orange) }
        $g.FillPath($cpBrush, $cpPath)
        $g.DrawString("COPY", $fontLabel, $bWhite, $btnCopyRect.X + 12, $btnCopyRect.Y + 14)
        $cpPath.Dispose(); $cpBrush.Dispose()

        # Status Line
        $statusStr = if ($script:statusRunning) { "STATUS: CONNECTED" } else { "STATUS: READY" }
        $cStatus = if ($script:statusRunning) { $C_Green } else { $C_LabelText }
        $bStatus = New-Object System.Drawing.SolidBrush($cStatus)
        $g.DrawString($statusStr, $fontInput, $bStatus, 40, $form.ClientSize.Height - 35)

        $bWhite.Dispose(); $bOrange.Dispose(); $bInput.Dispose(); $bIcon.Dispose(); $penBorder.Dispose(); $bStatus.Dispose(); $penOrange.Dispose()
    } catch {}
})

$script:txtRoom.Add_TextChanged({
    try { Update-SpeakerLink } catch {}
})
Update-SpeakerLink
$script:cmbQuality.Add_SelectedIndexChanged({ Update-SpeakerLink })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        if ($script:proc) {
            if ($script:proc.HasExited) {
                $script:proc = $null
                Set-RunningUi $false
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
                $script:form,
                'Native process is still running. YES = stop native and close. NO = close GUI only. CANCEL = keep GUI open.',
                'Close GUI?',
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($result -eq [System.Windows.Forms.DialogResult]::Cancel) {
                $e.Cancel = $true
                return
            }
            if ($result -eq [System.Windows.Forms.DialogResult]::Yes) {
                Stop-NativeProcess 'GUI closing'
            }
        }
    } catch {}
})

Set-RunningUi $false
[void]$form.ShowDialog()