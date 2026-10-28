<#
.SYNOPSIS
    Реєструє або видаляє щоденне завдання Windows Task Scheduler для хвилини мовчання о 09:00.

.DESCRIPTION
    Налаштовує щоденний запуск Show-MinuteOfSilence.ps1 о 09:00:00 за локальним часом.
    - Працює як у контексті користувача (Intune RunAsAccount = user), так і в контексті SYSTEM.
    - Дозволяє запуск від батареї (AllowStartIfOnBatteries).
    - Встановлює таймаут виконання 5 хвилин для уникнення зависань.
    - StartWhenAvailable = $false (запобігає запуску вдень, якщо о 09:00 ноутбук був вимкнений).

.PARAMETER Unregister
    Видаляє завдання планувальника та локальні файли конфігурації.
#>
[CmdletBinding()]
param(
    [switch]$Unregister
)

$ErrorActionPreference = 'Stop'

$TaskName = "National Minute of Silence Reminder"
$InstallDir = Join-Path $env:LOCALAPPDATA "Corporate\MinuteOfSilence"
if (-not $env:LOCALAPPDATA -or $env:USERNAME -eq "SYSTEM") {
    $InstallDir = "C:\ProgramData\Corporate\MinuteOfSilence"
}
$TargetScriptPath = Join-Path $InstallDir "Show-MinuteOfSilence.ps1"

# ── 1. Видалення (Unregister) ─────────────────────────────────────────────────
if ($Unregister) {
    Write-Host "Minute of Silence: Видалення запланованого завдання '$TaskName'..." -ForegroundColor Yellow
    $existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existingTask) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Завдання '$TaskName' успішно видалено." -ForegroundColor Green
    } else {
        Write-Host "Завдання '$TaskName' не знайдено." -ForegroundColor Gray
    }

    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "Директорію '$InstallDir' видалено." -ForegroundColor Green
    }
    exit 0
}

# ── 2. Підготовка директорії та копіювання скрипта ────────────────────────────
if (-not (Test-Path $InstallDir)) {
    New-Item -Path $InstallDir -ItemType Directory -Force | Out-Null
}

$sourceScript = Join-Path $PSScriptRoot "Show-MinuteOfSilence.ps1"
if (Test-Path $sourceScript) {
    Copy-Item -Path $sourceScript -Destination $TargetScriptPath -Force
    Write-Host "Скрипт скопійовано: $TargetScriptPath" -ForegroundColor Cyan
} else {
    if (-not (Test-Path $TargetScriptPath)) {
        throw "Вихідний файл '$sourceScript' не знайдено, і файл '$TargetScriptPath' відсутній."
    }
}

$sourceMp3 = Join-Path $PSScriptRoot "metronome.mp3"
if (Test-Path $sourceMp3) {
    Copy-Item -Path $sourceMp3 -Destination (Join-Path $InstallDir "metronome.mp3") -Force
    Write-Host "Аудіофайл скопійовано: $(Join-Path $InstallDir 'metronome.mp3')" -ForegroundColor Cyan
}

# ── 3. Створення Scheduled Task ───────────────────────────────────────────────
Write-Host "Реєстрація запланованого завдання '$TaskName' (запуск о 08:59:50 для відкриття о 09:00:00)..." -ForegroundColor Cyan

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$TargetScriptPath`""

# Запуск о 08:59:50 (за 10 с до 09:00) для фонового прогріву та синхронного старту девайсів
$trigger = New-ScheduledTaskTrigger -Daily -At "08:59:50"

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -MultipleInstances IgnoreNew

# Реєстрація завдання під поточним користувачем (інтерактивна сесія)
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$registeredTask = Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description "Щоденне сповіщення про загальнонаціональну хвилину мовчання о 09:00" `
    -Force

Write-Host "УСПІШНО: Завдання '$TaskName' зареєстровано. Наступний запуск о 09:00." -ForegroundColor Green
