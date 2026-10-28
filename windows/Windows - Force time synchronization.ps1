<#
.SYNOPSIS
    [Intune Script] Windows - Force time synchronization
    Примусово налаштовує постійну та регулярну синхронізацію системного часу Windows через W32Time, NTP та Task Scheduler.

.DESCRIPTION
    Цей скрипт призначений для розгортання через Microsoft Intune (Devices > Scripts > Windows):
    - Налаштування Intune:
        * Run this script using the logged on credentials: No (RunAsAccount: system / Administrator)
        * Enforce script signature check: No
        * Run script in 64-bit PowerShell: Yes
    - Дії:
        1. Встановлює тип запуску служби Windows Time (W32Time) в Automatic і запускає її.
        2. Налаштовує надійні сервери часу (pool.ntp.org, time.windows.com, time.google.com).
        3. Зменшує інтервал опитування (SpecialPollInterval) до 1 години (3600 сек) замість стандартних 7 днів.
        4. Дозволяє миттєву корекцію часу будь-якої величини (MaxPhaseCorrection = 0xFFFFFFFF).
        5. Реєструє постійне системне завдання Task Scheduler "Corporate Time Synchronization" (SYSTEM context):
           - Щодня о 08:30 (за 30 хв до хвилини мовчання)
           - Повторення кожні 4 години цілодобово
           - При завантаженні системи (AtStartup)
           - При вході користувача (AtLogon)
           - З параметром StartWhenAvailable=$true (автоматично наздоганяє при пробудженні зі сну)
        6. Примусово виконує негайну синхронізацію w32tm /resync /force.

.NOTES
    Відповідає корпоративному стандарту назв Intune: "Windows - Force time synchronization".
    Забезпечує мілісекундну точність для загальнонаціональної хвилини мовчання (Jira II-5426).
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Write-Host "=== [Intune] Windows - Force time synchronization ===" -ForegroundColor Cyan

try {
    # ── 1. Налаштування служби W32Time ─────────────────────────────────────────
    Write-Host "1. Перевірка та запуск служби W32Time..." -ForegroundColor Gray
    $service = Get-Service -Name W32Time -ErrorAction SilentlyContinue
    if (-not $service) {
        throw "Службу W32Time (Windows Time) не знайдено в системі."
    }

    Set-Service -Name W32Time -StartupType Automatic
    if ($service.Status -ne 'Running') {
        Start-Service -Name W32Time
        Write-Host "Службу W32Time успішно запущено." -ForegroundColor Green
    } else {
        Write-Host "Служба W32Time вже працює." -ForegroundColor Green
    }

    # ── 2. Налаштування параметрів реєстру W32Time ─────────────────────────────
    Write-Host "2. Налаштування NTP серверів та інтервалів опитування..." -ForegroundColor Gray
    $ntpServers = "pool.ntp.org,0x9 time.windows.com,0x9 time.google.com,0x9"
    $w32TimeParams = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters"
    $w32TimeConfig = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Config"
    $w32TimeNtp    = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient"

    Set-ItemProperty -Path $w32TimeParams -Name "NtpServer" -Value $ntpServers -Type String -Force
    Set-ItemProperty -Path $w32TimeParams -Name "Type" -Value "NTP" -Type String -Force

    # Інтервал опитування служби: 3600 секунд (1 година замість стандартних 7 днів)
    Set-ItemProperty -Path $w32TimeNtp -Name "SpecialPollInterval" -Value 3600 -Type DWord -Force

    # Необмежена корекція фази (дозволяє миттєво виправляти будь-які дрифти годинника)
    Set-ItemProperty -Path $w32TimeConfig -Name "MaxNegPhaseCorrection" -Value 0xFFFFFFFF -Type DWord -Force
    Set-ItemProperty -Path $w32TimeConfig -Name "MaxPosPhaseCorrection" -Value 0xFFFFFFFF -Type DWord -Force

    # ── 3. Оновлення конфігурації через w32tm ──────────────────────────────────
    Write-Host "3. Оновлення конфігурації w32tm..." -ForegroundColor Gray
    $configResult = & w32tm /config /manualpeerlist:"$ntpServers" /syncfromflags:manual /reliable:yes /update 2>&1
    Write-Host "w32tm config: $configResult" -ForegroundColor Gray

    # ── 4. Реєстрація регулярного системного завдання (Task Scheduler) ────────
    $taskName = "Corporate Time Synchronization"
    Write-Host "4. Налаштування регулярного системного завдання '$taskName'..." -ForegroundColor Cyan

    $taskAction = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"Start-Service W32Time -ErrorAction SilentlyContinue; & w32tm /resync /nowait`""

    # Тригер 1: Щодня о 08:30 з регулярним повторенням кожні 4 години
    $triggerDaily = New-ScheduledTaskTrigger `
        -Once -At "08:30" `
        -RepetitionInterval (New-TimeSpan -Hours 4) `
        -RepetitionDuration (New-TimeSpan -Days 3650)

    # Тригер 2: При завантаженні системи (AtStartup)
    $triggerStartup = New-ScheduledTaskTrigger -AtStartup

    # Тригер 3: При вході користувача в систему (AtLogOn)
    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn

    $taskSettings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -MultipleInstances IgnoreNew

    $existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }

    [void](Register-ScheduledTask `
        -TaskName $taskName `
        -Action $taskAction `
        -Trigger @($triggerDaily, $triggerStartup, $triggerLogon) `
        -Settings $taskSettings `
        -User "NT AUTHORITY\SYSTEM" `
        -RunLevel Highest `
        -Description "Регулярна корпоративна синхронізація часу Windows через NTP кожні 4 години, щодня о 08:30 та при пробудженні" `
        -Force)

    Write-Host "Системне завдання '$taskName' зареєстровано (кожні 4 години, о 08:30 та при виході зі сну)." -ForegroundColor Green

    # ── 5. Примусова негайна синхронізація часу ───────────────────────────────
    Write-Host "5. Примусова синхронізація часу (w32tm /resync /force)..." -ForegroundColor Cyan
    $resyncResult = & w32tm /resync /force /nowait 2>&1
    Write-Host "Результат команди: $resyncResult" -ForegroundColor Green

    # ── 6. Перевірка статусу синхронізації ────────────────────────────────────
    Write-Host "6. Поточний статус синхронізації:" -ForegroundColor Gray
    try {
        $status = & w32tm /query /status 2>&1
        $status | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
    } catch {
        Write-Warning "Не вдалося отримати детальний статус w32tm."
    }

    Write-Host "УСПІШНО: Регулярну синхронізацію часу Windows налаштовано та активовано." -ForegroundColor Green
    exit 0

} catch {
    Write-Error "ПОМИЛКА: Не вдалося виконати синхронізацію часу: $_"
    exit 1
}
