<#
.SYNOPSIS
    [Intune Script] Windows - Force time synchronization
    Примусово налаштовує та синхронізує системний час Windows через службу W32Time та NTP.

.DESCRIPTION
    Цей скрипт призначений для розгортання через Microsoft Intune (Devices > Scripts > Windows)
    або як Proactive Remediation Detection/Remediation:
    - Налаштування Intune:
        * Run this script using the logged on credentials: No (RunAsAccount: system / Administrator)
        * Enforce script signature check: No
        * Run script in 64-bit PowerShell: Yes
    - Дії:
        1. Встановлює тип запуску служби Windows Time (W32Time) в Automatic і запускає її.
        2. Налаштовує надійні сервери часу (pool.ntp.org, time.windows.com, time.google.com).
        3. Зменшує інтервал опитування (SpecialPollInterval) до 1 години (3600 сек) замість стандартних 7 днів.
        4. Дозволяє миттєву корекцію часу будь-якої величини (MaxPhaseCorrection = 0xFFFFFFFF).
        5. Примусово виконує негайну синхронізацію w32tm /resync /force.

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

    # Інтервал опитування: 3600 секунд (1 година)
    Set-ItemProperty -Path $w32TimeNtp -Name "SpecialPollInterval" -Value 3600 -Type DWord -Force

    # Необмежена корекція фази (дозволяє виправляти навіть великі зсуви годинника)
    Set-ItemProperty -Path $w32TimeConfig -Name "MaxNegPhaseCorrection" -Value 0xFFFFFFFF -Type DWord -Force
    Set-ItemProperty -Path $w32TimeConfig -Name "MaxPosPhaseCorrection" -Value 0xFFFFFFFF -Type DWord -Force

    # ── 3. Оновлення конфігурації через w32tm ──────────────────────────────────
    Write-Host "3. Оновлення конфігурації w32tm..." -ForegroundColor Gray
    $configResult = & w32tm /config /manualpeerlist:"$ntpServers" /syncfromflags:manual /reliable:yes /update 2>&1
    Write-Host "w32tm config: $configResult" -ForegroundColor Gray

    # ── 4. Примусова синхронізація часу ───────────────────────────────────────
    Write-Host "4. Примусова синхронізація часу (w32tm /resync /force)..." -ForegroundColor Cyan
    $resyncResult = & w32tm /resync /force /nowait 2>&1
    Write-Host "Результат команди: $resyncResult" -ForegroundColor Green

    # ── 5. Перевірка статусу синхронізації ────────────────────────────────────
    Write-Host "5. Поточний статус синхронізації:" -ForegroundColor Gray
    try {
        $status = & w32tm /query /status 2>&1
        $status | ForEach-Object { Write-Host "   $_" -ForegroundColor DarkGray }
    } catch {
        Write-Warning "Не вдалося отримати детальний статус w32tm."
    }

    Write-Host "УСПІШНО: Синхронізацію часу Windows налаштовано та активовано." -ForegroundColor Green
    exit 0

} catch {
    Write-Error "ПОМИЛКА: Не вдалося виконати синхронізацію часу: $_"
    exit 1
}
