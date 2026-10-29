<#
.SYNOPSIS
    Відображає вікно щоденного нагадування про загальнонаціональну хвилину мовчання о 09:00.

.DESCRIPTION
    Графічне меморіальне сповіщення (WPF/XAML) у сучасному стилі:
    - Відображається поверх інших вікон (TopMost).
    - Автоматично закривається після закінчення хвилини мовчання (60 сек).
    - Відтворює калібрований аудіотрек метронома пам'яті (60.0 BPM).
    - У разі відсутності файлу MP3 автоматично вмикає вбудований синтезований метроном пам'яті.
    - Можливість вимкнути звук кнопкою 🔊/🔇 або параметром -NoSound.
    - Сучасний вигляд (Bento/Dark Glass), мінімалістичний flame-accent, чиста типографіка Inter / Segoe UI.
    - Тонка лінія прогресу та таймер зворотного відліку.
    - Безпечний Time Guard: якщо ноутбук розбудили вдень (після 09:10), сповіщення не відображатиметься (крім запуску з -Force).
    - Захист від повторного запуску (Single Instance Mutex).

.PARAMETER Force
    Ігнорує перевірку часу 09:00 (використовується для тестування).

.PARAMETER TestSeconds
    Встановлює тривалість показу в секундах (за замовчуванням: 60 с).

.PARAMETER NoSound
    Запускає сповіщення в беззвучному режимі.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [int]$TestSeconds = 60,
    [switch]$NoSound
)

$ErrorActionPreference = 'Stop'

# ── 1. Time Guard: перевірка вікна запуску (08:59:40 - 09:00:59) ──────────────
$now = Get-Date
$todayTarget = Get-Date -Hour 9 -Minute 0 -Second 0 -Millisecond 0

if (-not $Force) {
    # Дозволене вікно:
    # - Ранній запуск (Pre-warming): від 08:59:40 (за 20 сек до 09:00)
    # - Жорсткий дедлайн: строго до 09:00:59 (о 09:01:00 і пізніше сповіщення НЕ відображається)
    $minAllowed = $todayTarget.AddSeconds(-20)
    $maxAllowed = $todayTarget.AddSeconds(59)

    if ($now -lt $minAllowed -or $now -gt $maxAllowed) {
        Write-Verbose "Minute of Silence: Поточний час ($($now.ToString('HH:mm:ss'))) за межами 08:59:40 - 09:00:59. О 09:01 і пізніше сповіщення не відображається. Пропуск."
        exit 0
    }
}

# ── 2. Single-Instance Mutex ──────────────────────────────────────────────────
$mutexName = "Global\NationalMinuteOfSilenceReminder"
$createdNew = $false
$mutex = [System.Threading.Mutex]::new($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    Write-Verbose "Minute of Silence: Сповіщення вже відкрите в іншій сесії."
    exit 0
}

try {
    # ── 3. DPI Awareness ──────────────────────────────────────────────────────
    try {
        Add-Type -Namespace CorporateUI -Name Dpi -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDpiAwarenessContext(System.IntPtr ctx);
'@
        $PerMonitorV2 = [IntPtr]::new(-4)
        [void][CorporateUI.Dpi]::SetProcessDpiAwarenessContext($PerMonitorV2)
    } catch {}

    # ── 4. Завантаження збірок WPF ────────────────────────────────────────────
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

    # ── 5. Підготовка аудіо (Метроном MP3 трек або синтезований метроном) ──────
    $script:soundEnabled = (-not $NoSound)
    $script:mediaPlayer  = $null
    $script:soundPlayer  = $null

    # Пошук файлу метронома
    $installDir = Join-Path $env:LOCALAPPDATA "Corporate\MinuteOfSilence"
    $candidateMp3Paths = @(
        (Join-Path $PSScriptRoot "metronome.mp3"),
        (Join-Path $installDir "metronome.mp3"),
        "C:\ProgramData\Corporate\MinuteOfSilence\metronome.mp3",
        (Join-Path $PSScriptRoot "..\assets\metronome.mp3")
    )

    $officialMp3Path = $null
    foreach ($cand in $candidateMp3Paths) {
        if (Test-Path $cand) {
            $officialMp3Path = (Get-Item $cand).FullName
            break
        }
    }

    if (-not $officialMp3Path) {
        $downloadTarget = Join-Path $installDir "metronome.mp3"
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $webClient = New-Object System.Net.WebClient
            $webClient.DownloadFile("https://raw.githubusercontent.com/girilovsky/National-Minute-Of-Silence/main/windows/metronome.mp3", $downloadTarget)
            if (Test-Path $downloadTarget) {
                $officialMp3Path = $downloadTarget
            }
        } catch {}
    }

    $script:defaultVolume = 0.15
    if ($officialMp3Path) {
        try {
            $script:mediaPlayer = New-Object System.Windows.Media.MediaPlayer
            $script:mediaPlayer.Open([System.Uri]::new($officialMp3Path))
            $script:mediaPlayer.Volume = if ($script:soundEnabled) { $script:defaultVolume } else { 0.0 }
            $script:mediaPlayer.Add_MediaFailed({
                param($s, $e)
                $script:mediaPlayer = $null
            })
        } catch {
            $script:mediaPlayer = $null
        }
    }

    # Fallback: синтез метронома, якщо MP3 відсутній
    if (-not $script:mediaPlayer) {
        try {
            $wavPath = Join-Path $env:TEMP "minute_of_silence_tick.wav"
            if (-not (Test-Path $wavPath) -or (Get-Item $wavPath).Length -lt 1000) {
                $sampleRate = 44100
                $durationSeconds = 0.05
                $peakVolume = 0.15

                $numSamples = [int]($sampleRate * $durationSeconds)
                $subChunk2Size = $numSamples * 2
                $chunkSize = 36 + $subChunk2Size

                $fs = [System.IO.File]::Create($wavPath)
                $bw = New-Object System.IO.BinaryWriter($fs)

                $bw.Write([System.Text.Encoding]::ASCII.GetBytes("RIFF"))
                $bw.Write([int32]$chunkSize)
                $bw.Write([System.Text.Encoding]::ASCII.GetBytes("WAVE"))
                $bw.Write([System.Text.Encoding]::ASCII.GetBytes("fmt "))
                $bw.Write([int32]16)
                $bw.Write([int16]1) # PCM
                $bw.Write([int16]1) # Mono
                $bw.Write([int32]$sampleRate)
                $bw.Write([int32]($sampleRate * 2))
                $bw.Write([int16]2)
                $bw.Write([int16]16)
                $bw.Write([System.Text.Encoding]::ASCII.GetBytes("data"))
                $bw.Write([int32]$subChunk2Size)

                for ($i = 0; $i -lt $numSamples; $i++) {
                    $t = $i / $sampleRate
                    $click = [Math]::Sin(2.0 * [Math]::PI * 1200.0 * $t) * [Math]::Exp(-$t * 160.0) * 0.45
                    $body  = [Math]::Sin(2.0 * [Math]::PI * 520.0 * $t)  * [Math]::Exp(-$t * 60.0)  * 0.55
                    $sampleVal = ($click + $body) * $peakVolume
                    $intSample = [int16][Math]::Round([Math]::Max(-1.0, [Math]::Min(1.0, $sampleVal)) * 32767.0)
                    $bw.Write($intSample)
                }
                $bw.Flush()
                $bw.Close()
                $fs.Close()
            }

            $script:soundPlayer = New-Object System.Media.SoundPlayer($wavPath)
            $script:soundPlayer.Load()
        } catch {
            $script:soundEnabled = $false
        }
    }

    # ── 6. XAML Розмітка інтерфейсу ───────────────────────────────────────────
    $xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Хвилина мовчання"
        Height="340" Width="500"
        WindowStyle="None"
        AllowsTransparency="True"
        Background="Transparent"
        Topmost="True"
        WindowStartupLocation="CenterScreen"
        ShowInTaskbar="False"
        ResizeMode="NoResize"
        Opacity="0">

    <Window.Resources>
        <Style TargetType="Button" x:Key="ModernBtnStyle">
            <Setter Property="Background" Value="#22252D"/>
            <Setter Property="Foreground" Value="#F3F4F6"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontFamily" Value="Segoe UI, Inter, -apple-system"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="#333742"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="btnBorder" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="10" Padding="18,8">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="btnBorder" Property="Background" Value="#2F333E"/>
                                <Setter TargetName="btnBorder" Property="BorderBrush" Value="#4B5263"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="Button" x:Key="IconBtnStyle">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Foreground" Value="#9CA3AF"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="iconBorder" Background="Transparent" CornerRadius="6" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="iconBorder" Property="Background" Value="#22252D"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Border Background="#111215" CornerRadius="20" BorderBrush="#25272F" BorderThickness="1.2">
        <Border.Effect>
            <DropShadowEffect BlurRadius="45" Color="#000000" Opacity="0.8" ShadowDepth="14"/>
        </Border.Effect>

        <Grid Margin="28,24,28,20">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <!-- 1. Top Bar: Pill Badge + Candle Flame Accent -->
            <Grid Grid.Row="0" Margin="0,0,0,16">
                <Border Background="#1A1C22" CornerRadius="14" BorderBrush="#2D3039" BorderThickness="1" 
                        HorizontalAlignment="Center" Padding="14,6">
                    <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                        <Path Fill="#F59E0B" Data="M6.5,1 C6.5,1 3,5.5 3,8.5 C3,10.4 4.6,12 6.5,12 C8.4,12 10,10.4 10,8.5 C10,5.5 6.5,1 6.5,1 Z" 
                              Width="13" Height="13" Stretch="Uniform" Margin="0,0,8,0" VerticalAlignment="Center"/>
                        <TextBlock Text="09:00" Foreground="#F3F4F6" FontSize="13" FontWeight="Bold" FontFamily="Segoe UI, Inter" VerticalAlignment="Center"/>
                        <TextBlock Text="  •  ХВИЛИНА МОВЧАННЯ" Foreground="#9CA3AF" FontSize="11.5" FontWeight="SemiBold" FontFamily="Segoe UI, Inter" VerticalAlignment="Center"/>
                    </StackPanel>
                </Border>
            </Grid>

            <!-- 2. Main Title -->
            <TextBlock Grid.Row="1" Text="Загальнонаціональна хвилина мовчання" 
                       Foreground="#FFFFFF" FontSize="19" FontWeight="Bold" 
                       FontFamily="Segoe UI, Inter"
                       TextAlignment="Center" Margin="0,0,0,12"/>

            <!-- 3. Message Body -->
            <StackPanel Grid.Row="2" VerticalAlignment="Center" Margin="10,0,10,14">
                <TextBlock Text="Зупинимося на хвилину, щоб вшанувати пам'ять захисників, захисниць та всіх українців, чиї життя забрала війна." 
                           Foreground="#9CA3AF" FontSize="13.5" LineHeight="20" 
                           FontFamily="Segoe UI, Inter"
                           TextWrapping="Wrap" TextAlignment="Center" Margin="0,0,0,12"/>

                <Border Background="#16181E" CornerRadius="10" Padding="14,7" HorizontalAlignment="Center">
                    <TextBlock Text="Пам'ятаємо.  Дякуємо.  Шануємо." 
                               Foreground="#FBBF24" FontSize="13.5" FontWeight="SemiBold" 
                               FontFamily="Segoe UI, Inter"
                               TextAlignment="Center"/>
                </Border>
            </StackPanel>

            <!-- 4. Thin Modern Progress Bar -->
            <Grid Grid.Row="3" Margin="0,0,0,16">
                <ProgressBar Name="TimerProgress" Height="3" Minimum="0" Maximum="60" Value="60" 
                             Foreground="#F59E0B" Background="#1E2026" BorderThickness="0">
                    <ProgressBar.Clip>
                        <RectangleGeometry RadiusX="1.5" RadiusY="1.5" Rect="0,0,444,3"/>
                    </ProgressBar.Clip>
                </ProgressBar>
            </Grid>

            <!-- 5. Footer: Countdown + Sound Toggle + Modern Dismiss Button -->
            <Grid Grid.Row="4">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>

                <StackPanel Grid.Column="0" Orientation="Horizontal" VerticalAlignment="Center">
                    <Button Name="SoundToggleBtn" Content="🔊" Width="28" Height="28" 
                            Style="{StaticResource IconBtnStyle}" Margin="0,0,6,0"
                            ToolTip="Вимкнути / увімкнути звук"/>
                    <TextBlock Name="CountdownLabel" Text="Закриється через 60 с" 
                               Foreground="#6B7280" FontSize="12.5" FontFamily="Segoe UI, Inter" VerticalAlignment="Center"/>
                </StackPanel>

                <Button Name="DismissBtn" Grid.Column="1" Content="Зрозуміло" 
                        Style="{StaticResource ModernBtnStyle}"/>
            </Grid>
        </Grid>
    </Border>
</Window>
"@

    # ── 7. Ініціалізація вікна ────────────────────────────────────────────────
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
    $window = [System.Windows.Markup.XamlReader]::Load($reader)

    $progressBar    = $window.FindName("TimerProgress")
    $countdownLabel = $window.FindName("CountdownLabel")
    $dismissBtn     = $window.FindName("DismissBtn")
    $soundToggleBtn = $window.FindName("SoundToggleBtn")

    $script:remainingSeconds = $TestSeconds
    $progressBar.Maximum = $TestSeconds
    $progressBar.Value   = $TestSeconds
    $countdownLabel.Text = "Закриється через $($script:remainingSeconds) с"

    if (-not $script:soundEnabled) {
        $soundToggleBtn.Content = "🔇"
    }

    # Кнопка перемикання звуку
    $soundToggleBtn.Add_Click({
        $script:soundEnabled = -not $script:soundEnabled
        $soundToggleBtn.Content = if ($script:soundEnabled) { "🔊" } else { "🔇" }

        if ($script:mediaPlayer) {
            $script:mediaPlayer.Volume = if ($script:soundEnabled) { $script:defaultVolume } else { 0.0 }
        }
    })

    # ── 8. Обробники подій закриття ───────────────────────────────────────────
    $closeAction = {
        if ($timer -and $timer.IsEnabled) {
            $timer.Stop()
        }
        if ($script:mediaPlayer) {
            try {
                $script:mediaPlayer.Stop()
                $script:mediaPlayer.Close()
            } catch {}
        }
        if ($script:soundPlayer) {
            try { $script:soundPlayer.Stop() } catch {}
        }
        $window.Close()
    }

    $dismissBtn.Add_Click({ & $closeAction })

    # Закриття по Esc, Return або Space
    $window.Add_KeyDown({
        param($sender, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::Escape -or 
            $e.Key -eq [System.Windows.Input.Key]::Return -or 
            $e.Key -eq [System.Windows.Input.Key]::Space) {
            & $closeAction
        }
    })

    # Перетягування вікна за потреби
    $window.Add_MouseLeftButtonDown({
        param($sender, $e)
        try { $window.DragMove() } catch {}
    })

    # ── 9. Мілісекундна синхронізація через NTP (Pre-warming + NTP Skew Lock) ────
    function Get-NtpClockOffsetMs {
        param(
            [string[]]$Servers = @('time.google.com', 'time.windows.com', 'time.cloudflare.com', 'pool.ntp.org'),
            [int]$TimeoutMs = 600
        )
        foreach ($server in $Servers) {
            $udp = $null
            try {
                $udp = New-Object System.Net.Sockets.UdpClient
                $udp.Client.ReceiveTimeout = $TimeoutMs
                $udp.Client.SendTimeout = $TimeoutMs
                $udp.Connect($server, 123)

                $req = New-Object byte[] 48
                $req[0] = 0x1B # Mode 3 (Client)
                
                $t0 = [DateTime]::UtcNow
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                [void]$udp.Send($req, 48)

                $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $res = $udp.Receive([ref]$ep)
                $rtt = $sw.Elapsed.TotalMilliseconds

                if ($res.Length -ge 48) {
                    $sec = [System.BitConverter]::ToUInt32($res[43..40], 0)
                    $frac = [System.BitConverter]::ToUInt32($res[47..44], 0)
                    $serverSec = $sec + ($frac / 4294967296.0)
                    $serverUtc = ([DateTime]::new(1900, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).AddSeconds($serverSec)

                    $localMid = $t0.AddMilliseconds($rtt / 2.0)
                    $offsetMs = ($serverUtc - $localMid).TotalMilliseconds

                    if ([Math]::Abs($offsetMs) -lt 30000) {
                        return [Math]::Round($offsetMs, 1)
                    }
                }
            } catch {
            } finally {
                if ($udp) { try { $udp.Close() } catch {} }
            }
        }
        return 0.0
    }

    $script:initialOffsetSeconds = 0.0
    $script:targetInstant = $todayTarget

    if (-not $Force) {
        # Запит атомарного часу NTP під час фонового прогріву
        $ntpSkew = Get-NtpClockOffsetMs
        $adjustedTarget = $todayTarget.AddMilliseconds(-$ntpSkew)

        $now = Get-Date
        # Жорстка перевірка: якщо атомарний час вже 09:01:00 або пізніше — негайний вихід!
        if ($now -ge $adjustedTarget.AddSeconds(60)) {
            Write-Verbose "Minute of Silence: Атомарний час вже 09:01:00 або пізніше. Хвилина мовчання на сьогодні завершена. Пропуск."
            exit 0
        }

        if ($now -ge $adjustedTarget) {
            # Етап Catch-up: ноутбук прокинувся після 09:00:00 (між 09:00:00 і 09:00:59)
            # Вирівнюємося на найближчий круглий такт секунди для ідеальної фази цокання
            $elapsedTotal = ($now - $adjustedTarget).TotalSeconds
            $targetBeat = [Math]::Ceiling($elapsedTotal)
            $script:initialOffsetSeconds = $targetBeat
            # Якщо хвилина мовчання вже закінчилась (60 с) або минуло 09:01:00 — пропуск
            if ($script:initialOffsetSeconds -ge $TestSeconds -or $script:initialOffsetSeconds -ge 60) {
                exit 0
            }
            $script:targetInstant = $adjustedTarget.AddSeconds($targetBeat)
        } else {
            $script:targetInstant = $adjustedTarget
        }
    } else {
        # У тестовому режимі (-Force): вирівнюємося на найближчий початок наступної секунди
        $now = Get-Date
        $msToNextSec = 1000 - $now.Millisecond
        $script:targetInstant = $now.AddMilliseconds($msToNextSec)
    }

    # Підлаштування залишкового часу та лінії прогресу
    $script:remainingSeconds = [Math]::Max(1.0, [double]$TestSeconds - $script:initialOffsetSeconds)
    $progressBar.Maximum = $TestSeconds
    $progressBar.Value   = $script:remainingSeconds
    $countdownLabel.Text = "Закриється через $([int][Math]::Ceiling($script:remainingSeconds)) с"

    # ── 10. Високоточний таймер, плавна анімація та затухання (Fade-Out) ────────
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(40) # 25 кадрів/сек для плавної лінії прогресу
    $script:stopwatch = New-Object System.Diagnostics.Stopwatch
    $script:lastDisplaySecond = -1

    $timer.Add_Tick({
        $elapsed = $script:stopwatch.Elapsed.TotalSeconds
        $remaining = [Math]::Max(0.0, [double]$TestSeconds - $script:initialOffsetSeconds - $elapsed)
        $displaySeconds = [int][Math]::Ceiling($remaining)

        # Оновлення лічильника секунд та тексту (ідеально синхронно з тактом метронома)
        if ($displaySeconds -ne $script:lastDisplaySecond) {
            $script:lastDisplaySecond = $displaySeconds
            $countdownLabel.Text = "Закриється через $displaySeconds с"

            # Якщо активний синтезований метроном (fallback)
            if (-not $script:mediaPlayer -and $script:soundEnabled -and $script:soundPlayer -and $displaySeconds -gt 0) {
                try { $script:soundPlayer.Play() } catch {}
            }
        }

        # Плавний, неперервний рух лінії прогресу
        $progressBar.Value = $remaining

        # ── Затухання (Fade-Out) в кінці ──────────────────────────────────────
        # Останні 2.4 секунди: плавне затухання гучності звуку (Audio Fade-Out)
        if ($remaining -le 2.4 -and $script:soundEnabled -and $script:mediaPlayer) {
            $volumeRatio = [Math]::Max(0.0, $remaining / 2.4)
            $script:mediaPlayer.Volume = $script:defaultVolume * $volumeRatio
        }

        # Останні 0.2 секунди: швидке затухання прозорості вікна (Window Opacity Fade-Out)
        if ($remaining -le 0.2) {
            $window.Opacity = [Math]::Max(0.0, $remaining / 0.2)
        }

        if ($remaining -le 0.0) {
            & $closeAction
        }
    })

    # Запуск таймера та аудіотреку синхронно при досягненні точного моменту (Pre-warming)
    $window.Add_Loaded({
        $waitMs = ($script:targetInstant - (Get-Date)).TotalMilliseconds
        if ($waitMs -gt 150) {
            [System.Threading.Thread]::Sleep([int]($waitMs - 80))
        }
        while ((Get-Date) -lt $script:targetInstant) {
            [System.Threading.Thread]::SpinWait(100)
        }

        # Миттєва поява вікна (без затримок на компіляцію XAML/WPF)
        $window.Opacity = 1.0

        if ($script:initialOffsetSeconds -gt 0 -and $script:mediaPlayer) {
            try {
                $script:mediaPlayer.Position = [TimeSpan]::FromSeconds($script:initialOffsetSeconds)
            } catch {}
        }

        $script:stopwatch.Start()
        $timer.Start()
        if ($script:soundEnabled) {
            if ($script:mediaPlayer) {
                try { $script:mediaPlayer.Play() } catch {}
            } elseif ($script:soundPlayer) {
                try { $script:soundPlayer.Play() } catch {}
            }
        }
    })

    # ── 11. Відображення вікна ────────────────────────────────────────────────
    [void]$window.ShowDialog()

} finally {
    if ($script:mediaPlayer) {
        try {
            $script:mediaPlayer.Stop()
            $script:mediaPlayer.Close()
        } catch {}
    }
    if ($script:soundPlayer) {
        try { $script:soundPlayer.Dispose() } catch {}
    }
    if ($mutex) {
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
