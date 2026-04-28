# Jitsi NDI Native - minimal detached safe GUI v59 nick
# GUI starts native with --room and optional --nick. It does not read native stdout/stderr, so GUI cannot crash from heavy native logs.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

$ErrorActionPreference = 'Continue'
$script:proc = $null
$script:repoRoot = $PSScriptRoot
$script:selectedExePath = $null
$script:currentLogFile = $null
$script:logDir = Join-Path $script:repoRoot "logs"
$script:lastCommand = ""
$script:isStopping = $false
$script:nativeStartedAt = $null

function Convert-JitsiInputToRoom {
    param([string]$InputText)
    $s = ("$InputText").Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return "" }
    if ($s -match "@conference\.") { return ($s -replace "@conference\..*$", "").Trim() }
    if ($s -match "^https?://") {
        try {
            $uri = [System.Uri]$s
            $path = [System.Uri]::UnescapeDataString($uri.AbsolutePath.Trim("/"))
            if (-not [string]::IsNullOrWhiteSpace($path)) { return ($path.Split("/")[0]).Trim() }
        } catch { return $s }
    }
    if ($s -match "^[^/]+\.[^/]+/(.+)$") {
        $part = $Matches[1].Split("?")[0].Split("#")[0].Trim("/")
        if ($part) { return [System.Uri]::UnescapeDataString($part.Split("/")[0]) }
    }
    return ($s.Split("?")[0].Split("#")[0].Trim("/"))
}

function Find-NativeExe {
    if ($script:selectedExePath -and (Test-Path $script:selectedExePath)) { return $script:selectedExePath }
    $candidates = @(
        (Join-Path $script:repoRoot "build\Release\jitsi-ndi-native.exe"),
        (Join-Path $script:repoRoot "build-ndi\Release\jitsi-ndi-native.exe"),
        (Join-Path $script:repoRoot "build\RelWithDebInfo\jitsi-ndi-native.exe"),
        (Join-Path $script:repoRoot "build-ndi\RelWithDebInfo\jitsi-ndi-native.exe"),
        (Join-Path $script:repoRoot "jitsi-ndi-native.exe")
    )
    foreach ($p in $candidates) { if (Test-Path $p) { return $p } }
    return $null
}

function Quote-Arg {
    param([string]$s)
    if ($null -eq $s) { return '""' }
    return '"' + ($s -replace '"','\"') + '"'
}

function Join-ProcessArgs {
    param([string[]]$ArgsList)
    $parts = @()
    foreach ($a in $ArgsList) {
        $s = [string]$a
        if ($s -match '[\s"]') {
            $parts += ('"' + ($s -replace '"','\"') + '"')
        } else {
            $parts += $s
        }
    }
    return ($parts -join ' ')
}

function Safe-SetText {
    param($Control, [string]$Text)
    try {
        if ($Control -and -not $Control.IsDisposed) { $Control.Text = $Text }
    } catch {}
}

function Append-Log {
    param([string]$line)
    try {
        $stamp = Get-Date -Format "HH:mm:ss.fff"
        $text = "$stamp $line"
        if ($script:currentLogFile) {
            try { Add-Content -LiteralPath $script:currentLogFile -Value $text -Encoding UTF8 } catch {}
        }
        if ($script:txtLog -and -not $script:txtLog.IsDisposed) {
            if ($script:txtLog.InvokeRequired) {
                try { $script:txtLog.BeginInvoke([Action[string]]{ param($x) Append-Log $x }, $line) | Out-Null } catch {}
                return
            }
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

function Set-RunningUi {
    param([bool]$running)
    try {
        $btnStart.Enabled = -not $running
        $btnStop.Enabled = $running
        $txtRoom.Enabled = -not $running
        $txtNick.Enabled = -not $running
        $chkNick.Enabled = -not $running
        $btnExe.Enabled = -not $running
        if ($running) {
            $lblStatus.Text = "Status: running"
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
        } else {
            $lblStatus.Text = "Status: stopped"
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
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
    Set-RunningUi $false
}

# UI
$form = New-Object System.Windows.Forms.Form
$form.Text = "Jitsi NDI Native GUI v59 minimal detached + nick"
$form.Size = New-Object System.Drawing.Size(780, 500)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(720, 440)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Minimal safe launcher: ссылка + ник + старт/стоп. GUI не читает native stdout, чтобы не падать."
$lblTitle.Location = New-Object System.Drawing.Point(12, 12)
$lblTitle.Size = New-Object System.Drawing.Size(740, 22)
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblTitle)

$lblRoom = New-Object System.Windows.Forms.Label
$lblRoom.Text = "Jitsi ссылка или room:"
$lblRoom.Location = New-Object System.Drawing.Point(12, 48)
$lblRoom.Size = New-Object System.Drawing.Size(140, 22)
$form.Controls.Add($lblRoom)

$txtRoom = New-Object System.Windows.Forms.TextBox
$txtRoom.Location = New-Object System.Drawing.Point(155, 46)
$txtRoom.Size = New-Object System.Drawing.Size(590, 24)
$txtRoom.Text = "https://meet.jit.si/6767676766767penxyi"
$form.Controls.Add($txtRoom)

$lblParsed = New-Object System.Windows.Forms.Label
$lblParsed.Text = "Room: —"
$lblParsed.Location = New-Object System.Drawing.Point(155, 74)
$lblParsed.Size = New-Object System.Drawing.Size(590, 20)
$form.Controls.Add($lblParsed)

$lblNick = New-Object System.Windows.Forms.Label
$lblNick.Text = "Ник:"
$lblNick.Location = New-Object System.Drawing.Point(12, 105)
$lblNick.Size = New-Object System.Drawing.Size(140, 22)
$form.Controls.Add($lblNick)

$txtNick = New-Object System.Windows.Forms.TextBox
$txtNick.Location = New-Object System.Drawing.Point(155, 102)
$txtNick.Size = New-Object System.Drawing.Size(260, 24)
$txtNick.Text = ""

$form.Controls.Add($txtNick)

$chkNick = New-Object System.Windows.Forms.CheckBox
$chkNick.Text = "передать ник"
$chkNick.Location = New-Object System.Drawing.Point(155, 130)
$chkNick.Size = New-Object System.Drawing.Size(140, 22)
$chkNick.Checked = $true
$form.Controls.Add($chkNick)

$lblNickNote = New-Object System.Windows.Forms.Label
$lblNickNote.Text = "Передаётся как display nick при следующем старте. Для изменения: Стоп → ник → Старт."
$lblNickNote.Location = New-Object System.Drawing.Point(425, 105)
$lblNickNote.Size = New-Object System.Drawing.Size(330, 40)
$form.Controls.Add($lblNickNote)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Status: stopped"
$lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
$lblStatus.Location = New-Object System.Drawing.Point(12, 160)
$lblStatus.Size = New-Object System.Drawing.Size(250, 22)
$form.Controls.Add($lblStatus)

$lblSafety = New-Object System.Windows.Forms.Label
$lblSafety.Text = "Команда запуска: --room + опционально --nick. Без --quality / NDI-сканирования / live stdout."
$lblSafety.Location = New-Object System.Drawing.Point(270, 160)
$lblSafety.Size = New-Object System.Drawing.Size(485, 22)
$form.Controls.Add($lblSafety)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "Старт"
$btnStart.Location = New-Object System.Drawing.Point(12, 194)
$btnStart.Size = New-Object System.Drawing.Size(90, 32)
$form.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = "Стоп"
$btnStop.Location = New-Object System.Drawing.Point(110, 194)
$btnStop.Size = New-Object System.Drawing.Size(90, 32)
$btnStop.Enabled = $false
$form.Controls.Add($btnStop)

$btnExe = New-Object System.Windows.Forms.Button
$btnExe.Text = "Exe..."
$btnExe.Location = New-Object System.Drawing.Point(208, 194)
$btnExe.Size = New-Object System.Drawing.Size(90, 32)
$form.Controls.Add($btnExe)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = "Копировать команду"
$btnCopy.Location = New-Object System.Drawing.Point(306, 194)
$btnCopy.Size = New-Object System.Drawing.Size(150, 32)
$form.Controls.Add($btnCopy)

$btnOpenLog = New-Object System.Windows.Forms.Button
$btnOpenLog.Text = "Открыть GUI-лог"
$btnOpenLog.Location = New-Object System.Drawing.Point(464, 194)
$btnOpenLog.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($btnOpenLog)

$btnLogs = New-Object System.Windows.Forms.Button
$btnLogs.Text = "Папка логов"
$btnLogs.Location = New-Object System.Drawing.Point(592, 194)
$btnLogs.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($btnLogs)

$txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog = $txtLog
$txtLog.Location = New-Object System.Drawing.Point(12, 240)
$txtLog.Size = New-Object System.Drawing.Size(742, 198)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($txtLog)

$txtRoom.Add_TextChanged({
    try {
        $room = Convert-JitsiInputToRoom $txtRoom.Text
        if ($room) { $lblParsed.Text = "Room: $room" } else { $lblParsed.Text = "Room: —" }
    } catch {}
})
$lblParsed.Text = "Room: " + (Convert-JitsiInputToRoom $txtRoom.Text)

$btnExe.Add_Click({
    try {
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "jitsi-ndi-native.exe|jitsi-ndi-native.exe|Executable files (*.exe)|*.exe|All files (*.*)|*.*"
        $ofd.InitialDirectory = $script:repoRoot
        if ($ofd.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:selectedExePath = $ofd.FileName
            Append-Log "[GUI] Selected exe manually: $($ofd.FileName)"
        }
    } catch { Append-Log ("[GUI] Exe dialog failed: " + $_.Exception.Message) }
})

$btnStart.Add_Click({
    try {
        if ($script:proc -and -not $script:proc.HasExited) { return }
        $room = Convert-JitsiInputToRoom $txtRoom.Text
        if ([string]::IsNullOrWhiteSpace($room)) {
            [System.Windows.Forms.MessageBox]::Show($form, "Вставь ссылку Jitsi или room name.", "No room", "OK", "Warning") | Out-Null
            return
        }
        $exe = Find-NativeExe
        if (-not $exe) {
            [System.Windows.Forms.MessageBox]::Show($form, "Не найден jitsi-ndi-native.exe. Нажми Exe... и выбери файл.", "Exe not found", "OK", "Error") | Out-Null
            return
        }

        New-Item -ItemType Directory -Path $script:logDir -Force | Out-Null
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $script:currentLogFile = Join-Path $script:logDir ("jitsi-ndi-gui_" + $stamp + ".log")
        Set-Content -LiteralPath $script:currentLogFile -Value "# Jitsi NDI GUI v59 detached session log. Native stdout is intentionally not captured." -Encoding UTF8

        $args = @("--room", $room)
        $nick = ("$($txtNick.Text)").Trim()
        if ($chkNick.Checked -and -not [string]::IsNullOrWhiteSpace($nick)) {
            $args += @("--nick", $nick)
        }

        $script:lastCommand = (Quote-Arg $exe) + " " + (($args | ForEach-Object { Quote-Arg $_ }) -join " ")
        if ($chkNick.Checked -and -not [string]::IsNullOrWhiteSpace($nick)) {
            Append-Log "[GUI] Starting native detached with safe args: --room $room --nick $nick"
        } else {
            Append-Log "[GUI] Starting native detached with safe args: --room $room"
            Append-Log "[GUI] Nick is empty or disabled; --nick is not passed."
        }
        Append-Log "[GUI] Native stdout/stderr are NOT captured in v59 to keep GUI stable."
        Append-Log "[GUI] GUI log file: $script:currentLogFile"

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $exe
        $psi.Arguments = Join-ProcessArgs $args
        $psi.WorkingDirectory = Split-Path -Parent $exe
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $false
        $psi.RedirectStandardError = $false
        $psi.CreateNoWindow = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        $p.EnableRaisingEvents = $true
        $exitHandler = [System.EventHandler]{
            param($sender, $e)
            try {
                if (-not $script:isStopping) { Append-Log "[GUI] Native process exited." }
                if ($form -and -not $form.IsDisposed) {
                    $form.BeginInvoke([Action]{ Set-RunningUi $false }) | Out-Null
                }
            } catch {}
        }
        $p.add_Exited($exitHandler)

        [void]$p.Start()
        $script:proc = $p
        $script:nativeStartedAt = Get-Date
        $script:isStopping = $false
        Set-RunningUi $true
        Append-Log "[GUI] Native process started. PID=$($p.Id)"
    } catch {
        Append-Log ("[GUI] Start failed: " + $_.Exception.Message)
        Set-RunningUi $false
    }
})

$btnStop.Add_Click({
    Stop-NativeProcess "Stop button"
    Append-Log "[GUI] Stop requested."
})

$btnCopy.Add_Click({
    try {
        if ($script:lastCommand) {
            [System.Windows.Forms.Clipboard]::SetText($script:lastCommand)
            Append-Log "[GUI] Launch command copied."
        } else {
            $room = Convert-JitsiInputToRoom $txtRoom.Text
            $exe = Find-NativeExe
            if ($exe -and $room) {
                $parts = @("--room", $room)
                $nick = ("$($txtNick.Text)").Trim()
                if ($chkNick.Checked -and -not [string]::IsNullOrWhiteSpace($nick)) {
                    $parts += @("--nick", $nick)
                }
                $cmd = (Quote-Arg $exe) + " " + (($parts | ForEach-Object { Quote-Arg $_ }) -join " ")
                [System.Windows.Forms.Clipboard]::SetText($cmd)
                Append-Log "[GUI] Preview command copied."
            }
        }
    } catch { Append-Log ("[GUI] Copy failed: " + $_.Exception.Message) }
})

$btnOpenLog.Add_Click({
    try {
        if ($script:currentLogFile -and (Test-Path $script:currentLogFile)) {
            Start-Process notepad.exe $script:currentLogFile
        } else {
            [System.Windows.Forms.MessageBox]::Show($form, "Текущий GUI-лог ещё не создан.", "No log", "OK", "Information") | Out-Null
        }
    } catch {}
})

$btnLogs.Add_Click({
    try {
        New-Item -ItemType Directory -Path $script:logDir -Force | Out-Null
        Start-Process explorer.exe $script:logDir
    } catch {}
})

$form.Add_FormClosing({
    param($sender, $e)
    try {
        if ($script:proc -and -not $script:proc.HasExited) {
            $res = [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Native-процесс ещё работает.\n\nДа — оставить NDI работать и закрыть только GUI.\nНет — остановить native и закрыть GUI.\nОтмена — не закрывать GUI.",
                "Native is running",
                [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                [System.Windows.Forms.MessageBoxIcon]::Question
            )
            if ($res -eq [System.Windows.Forms.DialogResult]::Cancel) {
                $e.Cancel = $true
                return
            }
            if ($res -eq [System.Windows.Forms.DialogResult]::No) {
                Stop-NativeProcess "GUI closing"
            } else {
                Append-Log "[GUI] GUI closed; native process left running. PID=$($script:proc.Id)"
            }
        }
    } catch {}
})

# Catch UI thread exceptions and keep the process alive where possible.
[System.Windows.Forms.Application]::add_ThreadException({
    param($sender, $e)
    try { Append-Log ("[GUI] UI exception caught: " + $e.Exception.Message) } catch {}
})

try {
    Append-Log "[GUI] v59 minimal detached loaded. No NDI scanning. Optional --nick display-name mode. No live native stdout reading."
    [void]$form.ShowDialog()
} catch {
    try { Append-Log ("[GUI] Fatal GUI exception: " + $_.Exception.Message) } catch {}
}
