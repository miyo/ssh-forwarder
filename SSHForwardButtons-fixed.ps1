# SSH Forward Manager - Windows PowerShell 5.1 (STA)
# Interactive ssh authentication via a separate console for every tunnel.
# Connected -> hide console; unexpected SSH exit -> show console with diagnostics.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SSHConsoleWindow {
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
}
'@
# Capture Ctrl+C / Ctrl+Break on the native console thread.
# The handler must NOT call PowerShell or WinForms: it only sets a flag.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class SSHCtrlCHandler {
    private delegate bool ConsoleHandler(uint eventType);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(ConsoleHandler handler, bool add);
    private static readonly ConsoleHandler Handler = OnConsoleEvent;
    private static volatile bool closingRequested;
    private static bool installed;
    private static bool OnConsoleEvent(uint eventType) {
        if (eventType == 0 || eventType == 1) { // CTRL_C_EVENT, CTRL_BREAK_EVENT
            closingRequested = true;
            return true;
        }
        return false;
    }
    public static bool ClosingRequested { get { return closingRequested; } }
    public static bool Install() {
        closingRequested = false;
        installed = SetConsoleCtrlHandler(Handler, true);
        return installed;
    }
    public static void Uninstall() {
        if (installed) {
            SetConsoleCtrlHandler(Handler, false);
            installed = false;
        }
    }
}
'@
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:Closing = $false
$baseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$configPath = Join-Path $baseDir 'ssh-forwards.txt'
if (-not (Test-Path -LiteralPath $configPath)) {
    @('ssh -f -N -L 13389:localhost:3389 qdev', 'ssh -f -N -L 20443:localhost:443 talisker') |
        Set-Content -LiteralPath $configPath -Encoding UTF8
}
$ssh = (Get-Command ssh.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
if (-not $ssh) { [System.Windows.Forms.MessageBox]::Show('ssh.exe was not found.') | Out-Null; return }

function Parse-Line([string]$line) {
    if ($line -notmatch '^\s*ssh(?:\.exe)?\s+(.+)$') { throw 'Line must start with ssh' }
    $raw = $Matches[1]
    # Do not detach using ssh -f: the GUI needs ownership of the SSH process.
    $raw = [regex]::Replace($raw, '(?<!\S)-f(?!\S)', '').Trim()
    if ($raw -notmatch '(?<!\S)-N(?!\S)') { $raw = '-N ' + $raw }
    $matchPort = [regex]::Match($raw, '(?:^|\s)-L\s+(?:(?:localhost|127\.0\.0\.1|\[::1\]):)?(?<port>\d+):')
    if (-not $matchPort.Success) { throw 'Only ssh -L <local-port>:<target>:<port> is supported' }
    $port = [int]$matchPort.Groups['port'].Value
    if ($port -lt 1 -or $port -gt 65535) { throw 'Local port out of range' }
    if ($raw -match '[&|<>\r\n]') { throw 'Shell metacharacters are not supported in commands' }
    return @{ Arguments = ('-o ExitOnForwardFailure=yes ' + $raw); Port = $port }
}

# A small helper runs *inside* the SSH console before ssh.exe. GetConsoleWindow()
# provides the correct console HWND, which cmd.exe.MainWindowHandle may not.
$script:RunDir = Join-Path $env:TEMP ('SSHForwardButtons-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $script:RunDir -Force)
$handleHelper = Join-Path $script:RunDir 'capture-window.ps1'
@'
param([string]$OutputPath)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class ConsoleHandle {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
}
"@
[IO.File]::WriteAllText($OutputPath, [ConsoleHandle]::GetConsoleWindow().ToInt64().ToString())
'@ | Set-Content -LiteralPath $handleHelper -Encoding ASCII

$form = New-Object System.Windows.Forms.Form
$form.Text = 'SSH Forward Manager (interactive SSH)'
#$form.Size = New-Object System.Drawing.Size(1050, 490)
#$form.MinimumSize = New-Object System.Drawing.Size(350, 230)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Meiryo UI', 10)

$panel = New-Object System.Windows.Forms.FlowLayoutPanel
$panel.Dock = 'Fill'; $panel.AutoScroll = $true
$panel.FlowDirection = 'TopDown'; $panel.WrapContents = $false
$panel.Padding = New-Object System.Windows.Forms.Padding(8)
$form.Controls.Add($panel)
$panel.BringToFront()
$entries = New-Object System.Collections.ArrayList

function Has-LocalListener([int]$port) {
    try { return (@(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue).Count -gt 0) }
    catch { return $false }
}
function Get-EntryHwnd($e) {
    if ($e.ConsoleHwnd -ne [IntPtr]::Zero -and [SSHConsoleWindow]::IsWindow($e.ConsoleHwnd)) { return $e.ConsoleHwnd }
    if (Test-Path -LiteralPath $e.HandleFile) {
        try {
            $val = [Int64]::Parse(([IO.File]::ReadAllText($e.HandleFile)).Trim())
            $hwnd = [IntPtr]::new($val)
            if ([SSHConsoleWindow]::IsWindow($hwnd)) { $e.ConsoleHwnd = $hwnd; return $hwnd }
        } catch {}
    }
    return [IntPtr]::Zero
}
function Set-ConsoleVisible($e, [bool]$visible) {
    $hwnd = Get-EntryHwnd $e
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    if ($visible) { [void][SSHConsoleWindow]::ShowWindow($hwnd, 5) } # SW_SHOW
    else { [void][SSHConsoleWindow]::ShowWindow($hwnd, 0) } # SW_HIDE
    return $true
}
function Set-EntryButtonState($e, [string]$state) {
    # Flat style preserves the intended background color on Windows Forms.
    $e.Button.UseVisualStyleBackColor = $false
    $e.Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $e.Button.ForeColor = [Drawing.Color]::Black
    switch ($state) {
        'Connected' {
            $e.Button.Text = 'Disconnect'
            $e.Button.BackColor = [Drawing.Color]::LightCoral
            $e.Button.Enabled = $true
        }
        'Disconnected' {
            $e.Button.Text = 'Connect'
            $e.Button.BackColor = [Drawing.Color]::LightGreen
            $e.Button.Enabled = $true
        }
        default {
            $e.Button.Text = $state
            $e.Button.BackColor = [Drawing.Color]::Khaki
            $e.Button.Enabled = $true
        }
    }
}
function Refresh-Entry($e) {
    if ($script:Closing) { return }
    if ($null -eq $e.Process) {
        $e.Label.Text = $(if ($e.Message) { $e.Message } else { 'Disconnected' })
        $e.Label.ForeColor = [Drawing.Color]::DimGray
        Set-EntryButtonState $e $(if ($e.Message) { 'Error' } else { 'Disconnected' })
        return
    }
    try {
        $e.Process.Refresh()
        $consoleExited = $e.Process.HasExited
        # cmd.exe remains alive for error inspection (cmd /k), so check an explicit
        # marker written when ssh.exe returns, independently of cmd.exe lifetime.
        $sshExited = $consoleExited -or (Test-Path -LiteralPath $e.ExitFile)
        if ($sshExited) {
            if (-not $e.ErrorNotified) {
                [void](Set-ConsoleVisible $e $true)
                $e.Hidden = $false
                $e.ErrorNotified = $true
            }
            $code = ''
            if (Test-Path -LiteralPath $e.ExitFile) {
                try { $code = ([IO.File]::ReadAllText($e.ExitFile)).Trim() } catch {}
            }
            $e.Label.Text = $(if ($code -ne '') { "Error: ssh exited ($code)" } else { 'Error: console closed' })
            $e.Label.ForeColor = [Drawing.Color]::Firebrick
            Set-EntryButtonState $e 'Error'
        } elseif (Has-LocalListener $e.Port) {
            # Non-zero console HWND may only become available after login.
            if (-not $e.Hidden) {
                if (Set-ConsoleVisible $e $false) { $e.Hidden = $true }
            }
            $e.Label.Text = 'Connected'
            $e.Label.ForeColor = [Drawing.Color]::ForestGreen
            Set-EntryButtonState $e 'Connected'
        } else {
            # A listener dropping while SSH runs is not proof of SSH failure.
            # Keep console hidden only when it is already hidden; on exit it is shown.
            $e.Label.Text = 'Connecting'
            $e.Label.ForeColor = [Drawing.Color]::DarkOrange
            Set-EntryButtonState $e 'Connecting'
        }
    } catch {
        $e.Label.Text = 'Status error: ' + $_.Exception.Message
        $e.Label.ForeColor = [Drawing.Color]::Firebrick
        Set-EntryButtonState $e 'Error'
    }
}
function Stop-Entry($e) {
    $p = $e.Process
    $e.Process = $null
    if ($null -ne $p) {
        try {
            $p.Refresh()
            if (-not $p.HasExited) {
                # Terminate cmd.exe AND child ssh.exe, including ProxyJump children.
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = "$env:SystemRoot\System32\taskkill.exe"
                $psi.Arguments = "/PID $($p.Id) /T /F"
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $killer = [System.Diagnostics.Process]::Start($psi)
                if ($null -ne $killer) {
                    [void]$killer.WaitForExit(3000)
                    $killer.Dispose()
                }
            }
            $p.Dispose()
        } catch {}
    }
    # Session files are only for this SSH console, not stored credentials.
    foreach ($file in @($e.BatchFile, $e.HandleFile, $e.ExitFile)) {
        if ($file) { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    }
    $e.ConsoleHwnd = [IntPtr]::Zero
    $e.Hidden = $false
    $e.ErrorNotified = $false
    $e.Message = ''
    if (-not $script:Closing) { Refresh-Entry $e }
}
function Start-Entry($e) {
    try {
        $e.Hidden = $false
        $e.ErrorNotified = $false
        $e.ConsoleHwnd = [IntPtr]::Zero
        $e.Message = ''
        # Per-connection batch file avoids cmd /k quoting ambiguities. /k retains
        # stderr and a visible console when ssh.exe terminates unexpectedly.
        $id = [guid]::NewGuid().ToString('N')
        $e.BatchFile = Join-Path $script:RunDir ("session-$id.cmd")
        $e.HandleFile = Join-Path $script:RunDir ("handle-$id.txt")
        $e.ExitFile = Join-Path $script:RunDir ("exit-$id.txt")
        $lines = @(
            '@echo off',
            ('title SSH Forward - port ' + $e.Port),
            ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $handleHelper + '" "' + $e.HandleFile + '"'),
            ('"' + $ssh + '" ' + $e.Arguments),
            ('echo %errorlevel%>"' + $e.ExitFile + '"'),
            'echo SSH session ended. Review any errors above. Reconnect from the GUI.'
        )
        [IO.File]::WriteAllLines($e.BatchFile, [string[]]$lines, [Text.Encoding]::Default)
        $p = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" `
            -ArgumentList ('/k ""' + $e.BatchFile + '""') -PassThru -ErrorAction Stop
        $e.Process = $p
        Refresh-Entry $e
    } catch {
        $e.Label.Text = 'Start failed: ' + $_.Exception.Message
        $e.Label.ForeColor = [Drawing.Color]::Firebrick
        Set-EntryButtonState $e 'Error'
    }
}
# Measure the longest command once so buttons stay aligned.
$configLines = @(Get-Content -LiteralPath $configPath -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and -not $_.StartsWith('#') })
$longestLabelWidth = 0
foreach ($configLine in $configLines) {
    $measured = [System.Windows.Forms.TextRenderer]::MeasureText(
        $configLine, $form.Font,
        [System.Drawing.Size]::new(10000, 40),
        [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    ).Width
    if ($measured -gt $longestLabelWidth) { $longestLabelWidth = $measured }
}
$displayLeft = 5
$labelWidth = [Math]::Max(150, [Math]::Min(800, $longestLabelWidth + 3))
$buttonLeft = $displayLeft + $labelWidth + 2
# Fit the longest button caption, with modest horizontal padding.
$buttonTextWidth = 0
foreach ($caption in @('Disconnect', 'Connect', 'Connecting', 'Disconnected', 'Error')) {
    $measured = [System.Windows.Forms.TextRenderer]::MeasureText(
        $caption, $form.Font,
        [System.Drawing.Size]::new(10000, 40),
        [System.Windows.Forms.TextFormatFlags]::SingleLine -bor [System.Windows.Forms.TextFormatFlags]::NoPadding
    ).Width
    if ($measured -gt $buttonTextWidth) { $buttonTextWidth = $measured }
}
$buttonWidth = $buttonTextWidth + 16
foreach ($line in $configLines) {
    try { $parsed = Parse-Line $line }
    catch { [Windows.Forms.MessageBox]::Show("Invalid config entry: $line`r`n$($_.Exception.Message)") | Out-Null; continue }
    $row = New-Object System.Windows.Forms.Panel
    $row.Size = New-Object System.Drawing.Size(975, 54) # Width adjusted to the form below
    $row.Margin = New-Object System.Windows.Forms.Padding(2, 2, 2, 2)
    $panel.Controls.Add($row)
    $display = New-Object System.Windows.Forms.Label
    $display.Text = $line; $display.AutoEllipsis = $true
    $display.SetBounds($displayLeft, 2, $labelWidth, 25); $row.Controls.Add($display)
    $status = New-Object System.Windows.Forms.Label
    $status.Text = 'Disconnected'; $status.AutoEllipsis = $true
    $status.SetBounds($displayLeft, 26, $labelWidth, 25); $row.Controls.Add($status)
    $button = New-Object System.Windows.Forms.Button
    $button.Text = 'Connect'; $button.SetBounds($buttonLeft, 3, $buttonWidth, 48)
    $button.UseVisualStyleBackColor = $false
    $button.BackColor = [Drawing.Color]::LightGreen
    $button.ForeColor = [Drawing.Color]::Black
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $row.Controls.Add($button)
    $entry = [pscustomobject]@{ Arguments=$parsed.Arguments; Port=$parsed.Port; Process=$null; Label=$status; Button=$button; Message=''; Hidden=$false; ErrorNotified=$false; ConsoleHwnd=[IntPtr]::Zero; BatchFile=''; HandleFile=''; ExitFile='' }
    [void]$entries.Add($entry)
    $button.Tag = $entry
    Set-EntryButtonState $entry 'Disconnected'
    $button.Add_Click({
        $item = $this.Tag
        # Connected: disconnect. Other states: restart a clean SSH session.
        # Stop-Entry also removes any leftover (possibly hidden) console.
        if ($item.Button.Text -eq 'Disconnect') {
            Stop-Entry $item
        } else {
            if ($null -ne $item.Process) { Stop-Entry $item }
            Start-Entry $item
        }
    })
}
# Let rows grow/shrink with the available width. When the window is too
# narrow for the fixed aligned button column, use horizontal scrolling.
$updateRowWidths = {
    $available = $panel.ClientSize.Width - $panel.Padding.Horizontal - 12
    $required = $buttonLeft + $buttonWidth + 12
    $newWidth = [Math]::Max($required, $available)
    foreach ($control in $panel.Controls) {
        if ($control.Width -ne $newWidth) { $control.Width = $newWidth }
    }
}
$panel.Add_Resize($updateRowWidths)
& $updateRowWidths

# Adjust window size to fit all entries
$clientWidth = $buttonLeft + $buttonWidth + 40
$clientHeight = $entries.Count * 58 + 20

$form.ClientSize = New-Object System.Drawing.Size(
    $clientWidth,
    $clientHeight
)

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
# A short independent timer handles Ctrl+C quickly; connection polling stays 2 s.
$cancelTimer = New-Object System.Windows.Forms.Timer
$cancelTimer.Interval = 200
$onCancelTick = [System.EventHandler]{
    if (-not $script:Closing -and [SSHCtrlCHandler]::ClosingRequested) {
        $form.Close() # normal FormClosing + finally cleanup, on the UI thread
    }
}
$cancelTimer.Add_Tick($onCancelTick)
$onTick = [System.EventHandler]{
    if ($script:Closing -or $form.IsDisposed -or $form.Disposing) { return }
    foreach ($item in $entries) {
        if ($script:Closing) { break }
        Refresh-Entry $item
    }
}
$timer.Add_Tick($onTick)
$onClosing = [System.Windows.Forms.FormClosingEventHandler]{
    $script:Closing = $true
    $timer.Stop()
    $cancelTimer.Stop()
    $timer.Remove_Tick($onTick)
    $cancelTimer.Remove_Tick($onCancelTick)
}
$form.Add_FormClosing($onClosing)
# Register after setup, directly before starting the message loop.
# If registration fails, normal window-close still works.
$ctrlCInstalled = [SSHCtrlCHandler]::Install()
$timer.Start()
$cancelTimer.Start()
try { [void]$form.ShowDialog() }
finally {
    $script:Closing = $true
    $timer.Stop()
    $cancelTimer.Stop()
    $timer.Remove_Tick($onTick)
    $cancelTimer.Remove_Tick($onCancelTick)
    [SSHCtrlCHandler]::Uninstall()
    $form.Remove_FormClosing($onClosing)
    foreach ($item in $entries) { Stop-Entry $item }
    $timer.Dispose()
    $cancelTimer.Dispose()
    $form.Dispose()
    Remove-Item -LiteralPath $script:RunDir -Recurse -Force -ErrorAction SilentlyContinue
}
