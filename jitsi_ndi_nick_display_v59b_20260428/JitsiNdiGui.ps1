# Jitsi NDI Native GUI v59b - detached safe launcher with optional display nick
# ASCII-only script to avoid PowerShell codepage/parser issues.
# Native stdout/stderr are not read by GUI, so heavy native logs cannot crash the GUI.

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
    $escaped = $s -replace '\\(?=(\\*)")', '\\'  # harmless for normal strings
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
            $lblStatus.Text = 'Status: running'
            $lblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
        } else {
            $lblStatus.Text = 'Status: stopped'
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
$form.Text = 'Jitsi NDI Native GUI v59b nick display'
$form.Size = New-Object System.Drawing.Size(780, 500)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object System.Drawing.Size(760, 470)
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'Stable detached launcher: link + optional display nick. GUI does not read native stdout.'
$lblTitle.Location = New-Object System.Drawing.Point(12, 12)
$lblTitle.Size = New-Object System.Drawing.Size(740, 22)
$lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblTitle)

$lblRoom = New-Object System.Windows.Forms.Label
$lblRoom.Text = 'Jitsi link / room:'
$lblRoom.Location = New-Object System.Drawing.Point(12, 48)
$lblRoom.Size = New-Object System.Drawing.Size(140, 22)
$form.Controls.Add($lblRoom)

$txtRoom = New-Object System.Windows.Forms.TextBox
$txtRoom.Location = New-Object System.Drawing.Point(155, 46)
$txtRoom.Size = New-Object System.Drawing.Size(590, 24)
$txtRoom.Text = 'https://meet.jit.si/6767676766767penxyi'
$form.Controls.Add($txtRoom)

$lblParsed = New-Object System.Windows.Forms.Label
$lblParsed.Text = 'Room:'
$lblParsed.Location = New-Object System.Drawing.Point(155, 74)
$lblParsed.Size = New-Object System.Drawing.Size(590, 20)
$form.Controls.Add($lblParsed)

$lblNick = New-Object System.Windows.Forms.Label
$lblNick.Text = 'Display nick:'
$lblNick.Location = New-Object System.Drawing.Point(12, 105)
$lblNick.Size = New-Object System.Drawing.Size(140, 22)
$form.Controls.Add($lblNick)

$txtNick = New-Object System.Windows.Forms.TextBox
$txtNick.Location = New-Object System.Drawing.Point(155, 102)
$txtNick.Size = New-Object System.Drawing.Size(260, 24)
$txtNick.Text = ''
$form.Controls.Add($txtNick)

$chkNick = New-Object System.Windows.Forms.CheckBox
$chkNick.Text = 'send --nick'
$chkNick.Location = New-Object System.Drawing.Point(155, 130)
$chkNick.Size = New-Object System.Drawing.Size(140, 22)
$chkNick.Checked = $true
$form.Controls.Add($chkNick)

$lblNickNote = New-Object System.Windows.Forms.Label
$lblNickNote.Text = 'Nick is applied only on next Start. To change it: Stop -> edit -> Start.'
$lblNickNote.Location = New-Object System.Drawing.Point(425, 105)
$lblNickNote.Size = New-Object System.Drawing.Size(330, 40)
$form.Controls.Add($lblNickNote)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'Status: stopped'
$lblStatus.ForeColor = [System.Drawing.Color]::DarkRed
$lblStatus.Location = New-Object System.Drawing.Point(12, 160)
$lblStatus.Size = New-Object System.Drawing.Size(250, 22)
$form.Controls.Add($lblStatus)

$lblSafety = New-Object System.Windows.Forms.Label
$lblSafety.Text = 'Command uses --room and optional --nick only. No quality/NDI scanning/live stdout.'
$lblSafety.Location = New-Object System.Drawing.Point(270, 160)
$lblSafety.Size = New-Object System.Drawing.Size(485, 22)
$form.Controls.Add($lblSafety)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = 'Start'
$btnStart.Location = New-Object System.Drawing.Point(12, 194)
$btnStart.Size = New-Object System.Drawing.Size(90, 32)
$form.Controls.Add($btnStart)

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = 'Stop'
$btnStop.Location = New-Object System.Drawing.Point(110, 194)
$btnStop.Size = New-Object System.Drawing.Size(90, 32)
$btnStop.Enabled = $false
$form.Controls.Add($btnStop)

$btnExe = New-Object System.Windows.Forms.Button
$btnExe.Text = 'Exe...'
$btnExe.Location = New-Object System.Drawing.Point(208, 194)
$btnExe.Size = New-Object System.Drawing.Size(90, 32)
$form.Controls.Add($btnExe)

$btnCopy = New-Object System.Windows.Forms.Button
$btnCopy.Text = 'Copy command'
$btnCopy.Location = New-Object System.Drawing.Point(306, 194)
$btnCopy.Size = New-Object System.Drawing.Size(150, 32)
$form.Controls.Add($btnCopy)

$btnOpenLog = New-Object System.Windows.Forms.Button
$btnOpenLog.Text = 'Open GUI log'
$btnOpenLog.Location = New-Object System.Drawing.Point(464, 194)
$btnOpenLog.Size = New-Object System.Drawing.Size(120, 32)
$form.Controls.Add($btnOpenLog)

$btnLogs = New-Object System.Windows.Forms.Button
$btnLogs.Text = 'Logs folder'
$btnLogs.Location = New-Object System.Drawing.Point(592, 194)
$btnLogs.Size = New-Object System.Drawing.Size(110, 32)
$form.Controls.Add($btnLogs)

$txtLog = New-Object System.Windows.Forms.TextBox
$script:txtLog = $txtLog
$txtLog.Location = New-Object System.Drawing.Point(12, 240)
$txtLog.Size = New-Object System.Drawing.Size(742, 198)
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font('Consolas', 9)
$form.Controls.Add($txtLog)

$txtRoom.Add_TextChanged({
    try {
        $room = Convert-JitsiInputToRoom $txtRoom.Text
        if ($room) { $lblParsed.Text = "Room: $room" } else { $lblParsed.Text = 'Room:' }
    } catch {}
})
$lblParsed.Text = 'Room: ' + (Convert-JitsiInputToRoom $txtRoom.Text)

$btnExe.Add_Click({
    try {
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = 'jitsi-ndi-native.exe|jitsi-ndi-native.exe|Executable files (*.exe)|*.exe|All files (*.*)|*.*'
        $ofd.InitialDirectory = $script:repoRoot
        if ($ofd.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:selectedExePath = $ofd.FileName
            Append-Log "[GUI] Selected exe manually: $($ofd.FileName)"
        }
    } catch { Append-Log "[GUI] Exe picker failed: $($_.Exception.Message)" }
})

$btnCopy.Add_Click({
    try {
        if ($script:lastCommand) {
            [System.Windows.Forms.Clipboard]::SetText($script:lastCommand)
            Append-Log '[GUI] Command copied.'
        } else {
            Append-Log '[GUI] No command yet. Press Start first.'
        }
    } catch { Append-Log "[GUI] Copy failed: $($_.Exception.Message)" }
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

$btnStart.Add_Click({
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
            [System.Windows.Forms.MessageBox]::Show($form, 'jitsi-ndi-native.exe not found. Use Exe... button.', 'Missing exe', 'OK', 'Error') | Out-Null
            return
        }

        if (-not (Test-Path $script:logDir)) { New-Item -ItemType Directory -Force -Path $script:logDir | Out-Null }
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $script:currentLogFile = Join-Path $script:logDir "jitsi-ndi-gui_$stamp.log"
        Set-Content -LiteralPath $script:currentLogFile -Value '# Jitsi NDI GUI session log' -Encoding UTF8

        $argsList = @('--room', $room)
        $nick = ("$($txtNick.Text)").Trim()
        if ($chkNick.Checked -and -not [string]::IsNullOrWhiteSpace($nick)) {
            $argsList += @('--nick', $nick)
            Append-Log '[GUI] Nick will be passed as --nick display name.'
        } else {
            Append-Log '[GUI] Nick is not passed.'
        }

        $arguments = Join-ProcessArgs $argsList
        $script:lastCommand = (Quote-Arg $exe) + ' ' + $arguments
        Append-Log "[GUI] Starting native: $script:lastCommand"
        Append-Log "[GUI] Session log file: $script:currentLogFile"

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
        Append-Log "[GUI] Native process started. PID=$($p.Id)"
        Append-Log '[GUI] GUI does not read native stdout/stderr. NDI should keep running even if GUI is closed.'
    } catch {
        Append-Log "[GUI] Start failed: $($_.Exception.Message)"
        Set-RunningUi $false
    }
})

$btnStop.Add_Click({ Stop-NativeProcess 'Stop button' })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        if ($script:proc) {
            if ($script:proc.HasExited) {
                if (-not $script:isStopping) { Append-Log "[GUI] Native exited with code $($script:proc.ExitCode)." }
                $script:proc = $null
                Set-RunningUi $false
            } else {
                if ($script:nativeStartedAt) {
                    $elapsed = [int]((Get-Date) - $script:nativeStartedAt).TotalSeconds
                    $lblStatus.Text = "Status: running (${elapsed}s)"
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
                'Native process is still running. YES = stop native and close. NO = close GUI only, keep NDI running. CANCEL = keep GUI open.',
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
            if ($result -eq [System.Windows.Forms.DialogResult]::No) {
                Append-Log '[GUI] Closing GUI only; native left running.'
            }
        }
    } catch {}
})

Append-Log '[GUI] v59b loaded. Detached mode. Optional --nick display name.'
Append-Log '[GUI] If nick causes issues, uncheck send --nick and restart.'
[void]$form.ShowDialog()
