$ErrorActionPreference = 'Stop'

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if ($scriptPath) {
        $exePath = (Get-Process -Id $PID).Path
        $args = '-NoProfile -STA -ExecutionPolicy Bypass -File "{0}"' -f $scriptPath
        Start-Process -FilePath $exePath -ArgumentList $args
        exit
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:engineClass = 'NovaClickEngine_' + (-join ((65..90) + (97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ }))
$script:keyClass = 'NovaKeyProbe_' + (-join ((65..90) + (97..122) | Get-Random -Count 12 | ForEach-Object { [char]$_ }))

$nativeCode = @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public class $($script:engineClass) {
    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT {
        public uint type;
        public MOUSEINPUT mi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private const uint INPUT_MOUSE = 0;
    private const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    private const uint MOUSEEVENTF_LEFTUP = 0x0004;
    private const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
    private const uint MOUSEEVENTF_RIGHTUP = 0x0010;
    private const int MAX_CPS = 5000;

    private static volatile bool leftRunning = false;
    private static volatile bool rightRunning = false;
    private static int leftCps = 20;
    private static int rightCps = 20;
    private static Thread leftThread = null;
    private static Thread rightThread = null;

    private static int ClampCps(int cps) {
        if (cps < 1) return 1;
        if (cps > MAX_CPS) return MAX_CPS;
        return cps;
    }

    private static int ReadCps(bool left) {
        return ClampCps(left ? Volatile.Read(ref leftCps) : Volatile.Read(ref rightCps));
    }

    private static bool IsRunning(bool left) {
        return left ? leftRunning : rightRunning;
    }

    private static void SendMouseClick(bool left) {
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = INPUT_MOUSE;
        inputs[1].type = INPUT_MOUSE;

        if (left) {
            inputs[0].mi.dwFlags = MOUSEEVENTF_LEFTDOWN;
            inputs[1].mi.dwFlags = MOUSEEVENTF_LEFTUP;
        } else {
            inputs[0].mi.dwFlags = MOUSEEVENTF_RIGHTDOWN;
            inputs[1].mi.dwFlags = MOUSEEVENTF_RIGHTUP;
        }

        SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    private static void ClickLoop(bool left) {
        Stopwatch watch = Stopwatch.StartNew();
        long nextTick = watch.ElapsedTicks;

        while (IsRunning(left)) {
            int cps = ReadCps(left);
            long intervalTicks = Math.Max(1L, Stopwatch.Frequency / (long)cps);
            long now = watch.ElapsedTicks;

            if (now >= nextTick) {
                SendMouseClick(left);
                nextTick += intervalTicks;

                if (nextTick < now - intervalTicks) {
                    nextTick = now + intervalTicks;
                }
            } else {
                long remainingTicks = nextTick - now;
                long twoMs = Stopwatch.Frequency / 500L;

                if (remainingTicks > twoMs) {
                    int sleepMs = (int)Math.Min(10L, ((remainingTicks * 1000L) / Stopwatch.Frequency) - 1L);
                    if (sleepMs > 0) Thread.Sleep(sleepMs);
                    else Thread.Sleep(0);
                } else {
                    Thread.SpinWait(120);
                }
            }
        }
    }

    public static void StartLeft(int cps) {
        SetLeftCps(cps);
        if (leftRunning) return;
        leftRunning = true;
        leftThread = new Thread(() => ClickLoop(true));
        leftThread.IsBackground = true;
        leftThread.Name = "NovaClickerLeft";
        leftThread.Priority = ThreadPriority.Normal;
        leftThread.Start();
    }

    public static void StartRight(int cps) {
        SetRightCps(cps);
        if (rightRunning) return;
        rightRunning = true;
        rightThread = new Thread(() => ClickLoop(false));
        rightThread.IsBackground = true;
        rightThread.Name = "NovaClickerRight";
        rightThread.Priority = ThreadPriority.Normal;
        rightThread.Start();
    }

    public static void StopLeft() {
        leftRunning = false;
        Thread t = leftThread;
        if (t != null && t.IsAlive) t.Join(150);
        leftThread = null;
    }

    public static void StopRight() {
        rightRunning = false;
        Thread t = rightThread;
        if (t != null && t.IsAlive) t.Join(150);
        rightThread = null;
    }

    public static void StopAll() {
        StopLeft();
        StopRight();
    }

    public static void SetLeftCps(int cps) {
        Volatile.Write(ref leftCps, ClampCps(cps));
    }

    public static void SetRightCps(int cps) {
        Volatile.Write(ref rightCps, ClampCps(cps));
    }

    public static bool IsLeftRunning() {
        return leftRunning;
    }

    public static bool IsRightRunning() {
        return rightRunning;
    }
}

public class $($script:keyClass) {
    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    public static bool IsPressed(int vKey) {
        return (GetAsyncKeyState(vKey) & 0x8000) != 0;
    }
}
"@

Add-Type -TypeDefinition $nativeCode -Language CSharp

$script:Native = @{
    StartLeft   = [scriptblock]::Create("param([int]`$cps) [$($script:engineClass)]::StartLeft(`$cps)")
    StartRight  = [scriptblock]::Create("param([int]`$cps) [$($script:engineClass)]::StartRight(`$cps)")
    StopLeft    = [scriptblock]::Create("[$($script:engineClass)]::StopLeft()")
    StopRight   = [scriptblock]::Create("[$($script:engineClass)]::StopRight()")
    StopAll     = [scriptblock]::Create("[$($script:engineClass)]::StopAll()")
    SetLeftCps  = [scriptblock]::Create("param([int]`$cps) [$($script:engineClass)]::SetLeftCps(`$cps)")
    SetRightCps = [scriptblock]::Create("param([int]`$cps) [$($script:engineClass)]::SetRightCps(`$cps)")
    IsPressed   = [scriptblock]::Create("param([int]`$vk) [$($script:keyClass)]::IsPressed(`$vk)")
}

function New-Color {
    param([string]$Hex)
    $clean = $Hex.TrimStart('#')
    [System.Drawing.Color]::FromArgb(
        [Convert]::ToInt32($clean.Substring(0, 2), 16),
        [Convert]::ToInt32($clean.Substring(2, 2), 16),
        [Convert]::ToInt32($clean.Substring(4, 2), 16)
    )
}

$colors = @{
    Bg       = New-Color '#0B0E13'
    Bg2      = New-Color '#141923'
    Header   = New-Color '#111722'
    Surface  = New-Color '#181F2B'
    Surface2 = New-Color '#202A38'
    Surface3 = New-Color '#263243'
    Line     = New-Color '#334154'
    Text     = New-Color '#F2F6FA'
    Muted    = New-Color '#A9B5C3'
    Dim      = New-Color '#718093'
    Left     = New-Color '#25D6C8'
    Right    = New-Color '#FF5C8A'
    Yellow   = New-Color '#FFD166'
    Danger   = New-Color '#EF476F'
}

$state = @{
    maxCps       = 5000
    leftActive   = $false
    rightActive  = $false
    leftCps      = 20
    rightCps     = 20
    leftVK       = 0
    rightVK      = 0
    leftKeyName  = 'none'
    rightKeyName = 'none'
    leftPrev     = $false
    rightPrev    = $false
    leftLastToggleAt = 0L
    rightLastToggleAt = 0L
    toggleCooldownMs = 140
    captureIgnoreUntil = 0L
    leftDragging = $false
    rightDragging = $false
    waitingSide  = ''
    formDragging = $false
    dragOrigin   = $null
    pollTimer    = $null
}

$ui = @{}

$keyDefinitions = @(
    @('F1', 0x70), @('F2', 0x71), @('F3', 0x72), @('F4', 0x73), @('F5', 0x74), @('F6', 0x75),
    @('F7', 0x76), @('F8', 0x77), @('F9', 0x78), @('F10', 0x79), @('F11', 0x7A), @('F12', 0x7B),
    @('A', 0x41), @('B', 0x42), @('C', 0x43), @('D', 0x44), @('E', 0x45), @('F', 0x46),
    @('G', 0x47), @('H', 0x48), @('I', 0x49), @('J', 0x4A), @('K', 0x4B), @('L', 0x4C),
    @('M', 0x4D), @('N', 0x4E), @('O', 0x4F), @('P', 0x50), @('Q', 0x51), @('R', 0x52),
    @('S', 0x53), @('T', 0x54), @('U', 0x55), @('V', 0x56), @('W', 0x57), @('X', 0x58),
    @('Y', 0x59), @('Z', 0x5A),
    @('D0', 0x30), @('D1', 0x31), @('D2', 0x32), @('D3', 0x33), @('D4', 0x34),
    @('D5', 0x35), @('D6', 0x36), @('D7', 0x37), @('D8', 0x38), @('D9', 0x39),
    @('NumPad0', 0x60), @('NumPad1', 0x61), @('NumPad2', 0x62), @('NumPad3', 0x63), @('NumPad4', 0x64),
    @('NumPad5', 0x65), @('NumPad6', 0x66), @('NumPad7', 0x67), @('NumPad8', 0x68), @('NumPad9', 0x69),
    @('Space', 0x20), @('Tab', 0x09), @('Shift', 0x10), @('Control', 0x11), @('Alt', 0x12),
    @('Insert', 0x2D), @('Delete', 0x2E), @('Home', 0x24), @('End', 0x23), @('PageUp', 0x21), @('PageDown', 0x22),
    @('Up', 0x26), @('Down', 0x28), @('LeftArrow', 0x25), @('RightArrow', 0x27),
    @('MButton', 0x04), @('XButton1', 0x05), @('XButton2', 0x06)
)

$keyMap = @{}
$vkNameMap = @{}
foreach ($def in $keyDefinitions) {
    $name = [string]$def[0]
    $vk = [int]$def[1]
    $keyMap[$name] = $vk
    if (-not $vkNameMap.ContainsKey($vk)) {
        $vkNameMap[$vk] = $name
    }
}
$keyMap['ShiftKey'] = 0x10
$keyMap['ControlKey'] = 0x11
$keyMap['Menu'] = 0x12
$keyMap['Next'] = 0x22
$keyMap['Prior'] = 0x21

function Enable-DoubleBuffer {
    param([System.Windows.Forms.Control]$Control)

    try {
        $prop = $Control.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance')
        if ($prop) {
            $prop.SetValue($Control, $true, $null)
        }
    } catch {}
}

function New-Font {
    param(
        [float]$Size,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular
    )
    New-Object System.Drawing.Font -ArgumentList 'Segoe UI', $Size, $Style
}

function New-Label {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H,
        [float]$FontSize = 10,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular,
        [System.Drawing.Color]$ForeColor = $colors.Text,
        [string]$Align = 'MiddleLeft'
    )

    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.Location = New-Object System.Drawing.Point($X, $Y)
    $label.Size = New-Object System.Drawing.Size($W, $H)
    $label.Font = New-Font $FontSize $Style
    $label.ForeColor = $ForeColor
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.TextAlign = $Align
    $label
}

function New-FlatButton {
    param(
        [string]$Text,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$ForeColor = $colors.Text,
        [float]$FontSize = 9.5,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Bold
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Location = New-Object System.Drawing.Point($X, $Y)
    $button.Size = New-Object System.Drawing.Size($W, $H)
    $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $button.FlatAppearance.BorderSize = 0
    $button.FlatAppearance.MouseDownBackColor = $colors.Line
    $button.FlatAppearance.MouseOverBackColor = $colors.Surface3
    $button.BackColor = $BackColor
    $button.ForeColor = $ForeColor
    $button.Font = New-Font $FontSize $Style
    $button.UseVisualStyleBackColor = $false
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
    $button
}

function Get-Prefix {
    param([string]$Side)
    if ($Side -eq 'Left') { 'left' } else { 'right' }
}

function Get-SideLabel {
    param([string]$Side)
    if ($Side -eq 'Left') { 'Sinistro' } else { 'Destro' }
}

function Test-KeyPressed {
    param([int]$VK)
    [bool](& $script:Native['IsPressed'] $VK)
}

function Get-NowMs {
    [int64]([DateTime]::UtcNow.Ticks / [TimeSpan]::TicksPerMillisecond)
}

function Set-Status {
    param(
        [string]$Text,
        [System.Drawing.Color]$Color = $colors.Muted
    )
    $ui.status.Text = $Text
    $ui.status.ForeColor = $Color
}

function Convert-XToCps {
    param(
        [int]$X,
        [int]$Width
    )
    $clamped = [math]::Max(0, [math]::Min($Width, $X))
    [int][math]::Round(1 + (($clamped / [double]$Width) * ($state.maxCps - 1)))
}

function Set-Cps {
    param(
        [string]$Side,
        [int]$Value
    )

    $prefix = Get-Prefix $Side
    $value = [math]::Max(1, [math]::Min([int]$state.maxCps, $Value))
    $state["${prefix}Cps"] = $value

    $label = $ui["${prefix}CpsLabel"]
    $slider = $ui["${prefix}Slider"]
    $fill = $ui["${prefix}Fill"]
    $num = $ui["${prefix}Number"]

    if ($label) {
        $label.Text = "$value CPS"
    }

    if ($slider -and $fill) {
        $fill.Width = [math]::Max(3, [int]($slider.Width * ($value / [double]$state.maxCps)))
    }

    if ($num -and ([int]$num.Value -ne $value)) {
        $num.Value = [decimal]$value
    }

    if ($Side -eq 'Left') {
        & $script:Native['SetLeftCps'] $value
    } else {
        & $script:Native['SetRightCps'] $value
    }
}

function Set-CpsFromSlider {
    param(
        [string]$Side,
        [int]$X
    )
    $prefix = Get-Prefix $Side
    $slider = $ui["${prefix}Slider"]
    if ($slider) {
        Set-Cps -Side $Side -Value (Convert-XToCps -X $X -Width $slider.Width)
    }
}

function Update-ActiveUi {
    param([string]$Side)

    $prefix = Get-Prefix $Side
    $active = [bool]$state["${prefix}Active"]
    $accent = if ($Side -eq 'Left') { $colors.Left } else { $colors.Right }
    $toggle = $ui["${prefix}Toggle"]
    $panel = $ui["${prefix}Panel"]
    $stateLabel = $ui["${prefix}State"]

    if ($active) {
        $toggle.Text = 'ON'
        $toggle.BackColor = $accent
        $toggle.ForeColor = $colors.Bg
        $stateLabel.Text = 'ATTIVO'
        $stateLabel.ForeColor = $accent
    } else {
        $toggle.Text = 'OFF'
        $toggle.BackColor = $colors.Surface3
        $toggle.ForeColor = $colors.Muted
        $stateLabel.Text = 'FERMO'
        $stateLabel.ForeColor = $colors.Dim
    }

    if ($panel) {
        $panel.Invalidate()
    }
}

function Toggle-Clicker {
    param([string]$Side)

    $prefix = Get-Prefix $Side
    $newState = -not [bool]$state["${prefix}Active"]
    $state["${prefix}Active"] = $newState
    $cps = [int]$state["${prefix}Cps"]
    $sideLabel = Get-SideLabel $Side

    if ($newState) {
        if ($Side -eq 'Left') {
            & $script:Native['StartLeft'] $cps
        } else {
            & $script:Native['StartRight'] $cps
        }
        $accent = if ($Side -eq 'Left') { $colors.Left } else { $colors.Right }
        Set-Status "$sideLabel attivo a $cps CPS" $accent
    } else {
        if ($Side -eq 'Left') {
            & $script:Native['StopLeft']
        } else {
            & $script:Native['StopRight']
        }
        Set-Status "$sideLabel fermo" $colors.Muted
    }

    Update-ActiveUi $Side
}

function Begin-HotkeyCapture {
    param([string]$Side)

    $state.waitingSide = $Side
    $state.captureIgnoreUntil = (Get-NowMs) + 160
    $prefix = Get-Prefix $Side
    $button = $ui["${prefix}Key"]
    $button.Text = 'Premi...'
    $button.BackColor = if ($Side -eq 'Left') { $colors.Left } else { $colors.Right }
    $button.ForeColor = $colors.Bg
    Set-Status "Premi un tasto supportato (Esc annulla)" $colors.Yellow
    $form.Activate()
    $form.Focus()
}

function Cancel-HotkeyCapture {
    if ([string]::IsNullOrWhiteSpace($state.waitingSide)) {
        return
    }

    $side = $state.waitingSide
    $prefix = Get-Prefix $side
    $button = $ui["${prefix}Key"]
    $button.Text = "Hotkey: $($state["${prefix}KeyName"])"
    $button.BackColor = $colors.Surface3
    $button.ForeColor = $colors.Text
    $state.waitingSide = ''
    Set-Status 'Assegnazione annullata' $colors.Muted
}

function Normalize-KeyName {
    param([string]$KeyName)

    switch ($KeyName) {
        'ShiftKey' { 'Shift'; break }
        'ControlKey' { 'Control'; break }
        'Menu' { 'Alt'; break }
        'Next' { 'PageDown'; break }
        'Prior' { 'PageUp'; break }
        default { $KeyName }
    }
}

function Set-Hotkey {
    param(
        [string]$Side,
        [string]$Name,
        [int]$VK
    )

    $prefix = Get-Prefix $Side
    $state["${prefix}VK"] = $VK
    $state["${prefix}KeyName"] = $Name
    $state["${prefix}Prev"] = Test-KeyPressed $VK
    $state["${prefix}LastToggleAt"] = Get-NowMs
    $state.waitingSide = ''

    $button = $ui["${prefix}Key"]
    $button.Text = "Hotkey: $Name"
    $button.BackColor = $colors.Surface3
    $button.ForeColor = $colors.Text

    Set-Status "$(Get-SideLabel $Side): hotkey $Name" (if ($Side -eq 'Left') { $colors.Left } else { $colors.Right })
}

function Get-PressedHotkey {
    foreach ($def in $keyDefinitions) {
        $name = [string]$def[0]
        $vk = [int]$def[1]
        if (Test-KeyPressed $vk) {
            return [pscustomobject]@{
                Name = $name
                VK = $vk
            }
        }
    }
    $null
}

function Add-PanelChrome {
    param(
        [System.Windows.Forms.Panel]$Panel,
        [string]$Side,
        [System.Drawing.Color]$Accent
    )

    $prefix = Get-Prefix $Side
    $Panel.Add_Paint({
        param($s, $e)
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $borderPen = New-Object System.Drawing.Pen -ArgumentList $colors.Line, 1
        $e.Graphics.DrawRectangle($borderPen, 0, 0, $s.Width - 1, $s.Height - 1)
        $borderPen.Dispose()

        $stripColor = if ([bool]$state["${prefix}Active"]) { $Accent } else { $colors.Line }
        $stripBrush = New-Object System.Drawing.SolidBrush -ArgumentList $stripColor
        $e.Graphics.FillRectangle($stripBrush, 0, 0, 5, $s.Height)
        $stripBrush.Dispose()
    }.GetNewClosure())
}

function Add-DragSurface {
    param([System.Windows.Forms.Control]$Control)

    $Control.Add_MouseDown({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $state.formDragging = $true
            $state.dragOrigin = $e.Location
        }
    })

    $Control.Add_MouseMove({
        param($s, $e)
        if ($state.formDragging) {
            $form.Location = New-Object System.Drawing.Point(
                ($form.Location.X + $e.X - $state.dragOrigin.X),
                ($form.Location.Y + $e.Y - $state.dragOrigin.Y)
            )
        }
    })

    $Control.Add_MouseUp({
        $state.formDragging = $false
    })
}

function New-ClickSection {
    param(
        [string]$Side,
        [string]$Title,
        [int]$X,
        [System.Drawing.Color]$Accent
    )

    $prefix = Get-Prefix $Side

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Location = New-Object System.Drawing.Point($X, 96)
    $panel.Size = New-Object System.Drawing.Size(250, 245)
    $panel.BackColor = $colors.Surface
    Enable-DoubleBuffer $panel
    Add-PanelChrome -Panel $panel -Side $Side -Accent $Accent
    $form.Controls.Add($panel)
    $ui["${prefix}Panel"] = $panel

    $titleLabel = New-Label $Title 22 18 160 30 15 ([System.Drawing.FontStyle]::Bold) $colors.Text
    $panel.Controls.Add($titleLabel)

    $stateLabel = New-Label 'FERMO' 167 20 62 24 9.5 ([System.Drawing.FontStyle]::Bold) $colors.Dim 'MiddleRight'
    $panel.Controls.Add($stateLabel)
    $ui["${prefix}State"] = $stateLabel

    $keyButton = New-FlatButton 'Hotkey: none' 22 60 128 34 $colors.Surface3 $colors.Text 9.5
    $keyButton.Add_Click({ Begin-HotkeyCapture -Side $Side }.GetNewClosure())
    $panel.Controls.Add($keyButton)
    $ui["${prefix}Key"] = $keyButton

    $toggleButton = New-FlatButton 'OFF' 160 60 68 34 $colors.Surface3 $colors.Muted 10
    $toggleButton.Add_Click({ Toggle-Clicker -Side $Side }.GetNewClosure())
    $panel.Controls.Add($toggleButton)
    $ui["${prefix}Toggle"] = $toggleButton

    $cpsCaption = New-Label 'CPS' 22 111 60 22 9 ([System.Drawing.FontStyle]::Bold) $colors.Dim
    $panel.Controls.Add($cpsCaption)

    $cpsLabel = New-Label '20 CPS' 88 104 140 34 17 ([System.Drawing.FontStyle]::Bold) $Accent 'MiddleRight'
    $panel.Controls.Add($cpsLabel)
    $ui["${prefix}CpsLabel"] = $cpsLabel

    $slider = New-Object System.Windows.Forms.Panel
    $slider.Location = New-Object System.Drawing.Point(22, 149)
    $slider.Size = New-Object System.Drawing.Size(206, 14)
    $slider.BackColor = $colors.Surface3
    $slider.Cursor = [System.Windows.Forms.Cursors]::Hand
    $panel.Controls.Add($slider)
    $ui["${prefix}Slider"] = $slider

    $fill = New-Object System.Windows.Forms.Panel
    $fill.Location = New-Object System.Drawing.Point(0, 0)
    $fill.Size = New-Object System.Drawing.Size(3, 14)
    $fill.BackColor = $Accent
    $fill.Enabled = $false
    $slider.Controls.Add($fill)
    $ui["${prefix}Fill"] = $fill

    $slider.Add_MouseDown({
        param($s, $e)
        $state["${prefix}Dragging"] = $true
        Set-CpsFromSlider -Side $Side -X $e.X
    }.GetNewClosure())

    $slider.Add_MouseMove({
        param($s, $e)
        if ([bool]$state["${prefix}Dragging"]) {
            Set-CpsFromSlider -Side $Side -X $e.X
        }
    }.GetNewClosure())

    $slider.Add_MouseUp({
        $state["${prefix}Dragging"] = $false
    }.GetNewClosure())

    $minLabel = New-Label '1' 22 169 50 18 8.5 ([System.Drawing.FontStyle]::Regular) $colors.Dim
    $panel.Controls.Add($minLabel)

    $maxLabel = New-Label "$($state.maxCps)" 148 169 80 18 8.5 ([System.Drawing.FontStyle]::Regular) $colors.Dim 'MiddleRight'
    $panel.Controls.Add($maxLabel)

    $number = New-Object System.Windows.Forms.NumericUpDown
    $number.Location = New-Object System.Drawing.Point(22, 196)
    $number.Size = New-Object System.Drawing.Size(206, 31)
    $number.Minimum = 1
    $number.Maximum = [decimal]$state.maxCps
    $number.Value = [decimal]$state["${prefix}Cps"]
    $number.Increment = 1
    $number.ThousandsSeparator = $true
    $number.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $number.BackColor = $colors.Bg2
    $number.ForeColor = $colors.Text
    $number.Font = New-Font 11 ([System.Drawing.FontStyle]::Bold)
    $number.Add_ValueChanged({ Set-Cps -Side $Side -Value ([int]$number.Value) }.GetNewClosure())
    $panel.Controls.Add($number)
    $ui["${prefix}Number"] = $number

    Set-Cps -Side $Side -Value ([int]$state["${prefix}Cps"])
    Update-ActiveUi $Side
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'NovaClicker'
$form.ClientSize = New-Object System.Drawing.Size(560, 410)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.ShowInTaskbar = $true
$form.KeyPreview = $true
$form.TopMost = $true
$form.BackColor = $colors.Bg
Enable-DoubleBuffer $form

$form.Add_Paint({
    param($s, $e)
    $rect = $s.ClientRectangle
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList $rect, $colors.Bg, $colors.Bg2, 35.0
    $e.Graphics.FillRectangle($brush, $rect)
    $brush.Dispose()

    $pen = New-Object System.Drawing.Pen -ArgumentList $colors.Line, 1
    $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
    $pen.Dispose()
})

$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(0, 0)
$header.Size = New-Object System.Drawing.Size(560, 74)
$header.BackColor = $colors.Header
Enable-DoubleBuffer $header
$form.Controls.Add($header)
Add-DragSurface $header

$header.Add_Paint({
    param($s, $e)
    $rect = $s.ClientRectangle
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush -ArgumentList $rect, $colors.Header, $colors.Surface, 0.0
    $e.Graphics.FillRectangle($brush, $rect)
    $brush.Dispose()

    $leftPen = New-Object System.Drawing.Pen -ArgumentList $colors.Left, 3
    $rightPen = New-Object System.Drawing.Pen -ArgumentList $colors.Right, 3
    $e.Graphics.DrawLine($leftPen, 0, $s.Height - 2, [int]($s.Width / 2), $s.Height - 2)
    $e.Graphics.DrawLine($rightPen, [int]($s.Width / 2), $s.Height - 2, $s.Width, $s.Height - 2)
    $leftPen.Dispose()
    $rightPen.Dispose()
})

$title = New-Label 'NovaClicker' 24 20 250 34 19 ([System.Drawing.FontStyle]::Bold) $colors.Text
$header.Controls.Add($title)
Add-DragSurface $title

$btnMin = New-FlatButton '-' 484 18 30 30 $colors.Surface2 $colors.Muted 13
$btnMin.Add_Click({ $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized })
$header.Controls.Add($btnMin)

$btnClose = New-FlatButton 'x' 520 18 30 30 $colors.Surface2 $colors.Text 12
$btnClose.FlatAppearance.MouseOverBackColor = $colors.Danger
$btnClose.Add_Click({ $form.Close() })
$header.Controls.Add($btnClose)

New-ClickSection -Side 'Left' -Title 'Click sinistro' -X 24 -Accent $colors.Left
New-ClickSection -Side 'Right' -Title 'Click destro' -X 286 -Accent $colors.Right

$footer = New-Object System.Windows.Forms.Panel
$footer.Location = New-Object System.Drawing.Point(24, 358)
$footer.Size = New-Object System.Drawing.Size(512, 32)
$footer.BackColor = $colors.Surface
Enable-DoubleBuffer $footer
$footer.Add_Paint({
    param($s, $e)
    $pen = New-Object System.Drawing.Pen -ArgumentList $colors.Line, 1
    $e.Graphics.DrawRectangle($pen, 0, 0, $s.Width - 1, $s.Height - 1)
    $pen.Dispose()
})
$form.Controls.Add($footer)

$status = New-Label 'Pronto' 14 4 484 24 10 ([System.Drawing.FontStyle]::Bold) $colors.Muted 'MiddleCenter'
$footer.Controls.Add($status)
$ui.status = $status

$form.Add_MouseUp({
    $state.formDragging = $false
    $state.leftDragging = $false
    $state.rightDragging = $false
})

$form.Add_KeyDown({
    param($s, $e)

    if ([string]::IsNullOrWhiteSpace($state.waitingSide)) {
        return
    }

    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
        Cancel-HotkeyCapture
        $e.SuppressKeyPress = $true
        return
    }

    $normalized = Normalize-KeyName $e.KeyCode.ToString()
    if ($keyMap.ContainsKey($normalized)) {
        $vk = [int]$keyMap[$normalized]
        $displayName = if ($vkNameMap.ContainsKey($vk)) { $vkNameMap[$vk] } else { $normalized }
        Set-Hotkey -Side $state.waitingSide -Name $displayName -VK $vk
        $e.SuppressKeyPress = $true
    }
})

$state.pollTimer = New-Object System.Windows.Forms.Timer
$state.pollTimer.Interval = 10
$state.pollTimer.Add_Tick({
    $nowMs = Get-NowMs

    if (-not [string]::IsNullOrWhiteSpace($state.waitingSide)) {
        if ($nowMs -lt [long]$state.captureIgnoreUntil) {
            return
        }

        $hit = Get-PressedHotkey
        if ($hit) {
            Set-Hotkey -Side $state.waitingSide -Name $hit.Name -VK $hit.VK
        }
        return
    }

    foreach ($side in @('Left', 'Right')) {
        $prefix = Get-Prefix $side
        $vk = [int]$state["${prefix}VK"]
        if ($vk -eq 0) {
            continue
        }

        $pressed = Test-KeyPressed $vk
        if ($pressed -and -not [bool]$state["${prefix}Prev"]) {
            $lastToggleAt = [long]$state["${prefix}LastToggleAt"]
            if (($nowMs - $lastToggleAt) -ge [int]$state.toggleCooldownMs) {
                Toggle-Clicker -Side $side
                $state["${prefix}LastToggleAt"] = $nowMs
            }
            $state["${prefix}Prev"] = $true
        } elseif (-not $pressed) {
            $state["${prefix}Prev"] = $false
        }
    }
})
$state.pollTimer.Start()

$form.Add_FormClosing({
    try {
        if ($state.pollTimer) {
            $state.pollTimer.Stop()
            $state.pollTimer.Dispose()
        }
        & $script:Native['StopAll']
    } catch {}
})

[void]$form.ShowDialog()
