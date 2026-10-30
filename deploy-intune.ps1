<#
.SYNOPSIS
    Deploys the National Minute of Silence reminder scripts to Microsoft Intune
    for Windows and macOS, targeting the IT Core group.

.DESCRIPTION
    1. Authenticates via MicrosoftTokenBridge (or existing MgGraph session).
    2. Resolves Entra ID groups (Target: IT Core).
    3. Deletes existing scripts and creates fresh IDs for mandatory re-execution (per intune-macos-scripts.md).
    4. Creates Windows Device Management Script ("Windows - National Minute of Silence Reminder").
    5. Creates macOS Device Shell Script ("macOS - National Minute of Silence Reminder").
    6. Assigns scripts to the target group.
#>

param(
    [string]$TargetGroupName = "IT Core"
)

$ErrorActionPreference = 'Stop'

$tokenBridgeModule = "c:\Users\ViktorHyrylovskyi\Documents\Code\Scripts\Modules\MicrosoftTokenBridge\MicrosoftTokenBridge.psd1"
if (Test-Path $tokenBridgeModule) {
    Import-Module $tokenBridgeModule -Force -ErrorAction SilentlyContinue
}

$tenantId = "3bfb00bf-616d-44a4-a0fa-adc50abfe012"
$hasTokenBridge = $false
try {
    $testToken = Get-MicrosoftToken -Tenant gth -ErrorAction Stop
    if ($testToken) { $hasTokenBridge = $true }
} catch {}

if (-not $hasTokenBridge) {
    Import-Module Microsoft.Graph.Authentication -ErrorAction SilentlyContinue
    $mgCtx = Get-MgContext -ErrorAction SilentlyContinue
    if (-not $mgCtx -or $mgCtx.TenantId -ne $tenantId) {
        throw "Not authenticated. Please run Connect-MicrosoftTokenBridge -Tenant gth first."
    }
}

function Invoke-IntuneGraphRequest([string]$Method, [string]$Uri, $Body = $null, [string]$ContentType = "application/json") {
    if ($hasTokenBridge) {
        if ($null -ne $Body) {
            return Invoke-MicrosoftGraph -Method $Method -Uri $Uri -Body $Body
        } else {
            return Invoke-MicrosoftGraph -Method $Method -Uri $Uri
        }
    } else {
        $params = @{ Method = $Method; Uri = $Uri }
        if ($null -ne $Body) { $params.Body = $Body; $params.ContentType = $ContentType }
        return Invoke-MgGraphRequest @params
    }
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " National Minute of Silence - Microsoft Intune Deployment " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Verify Identity
$me = Invoke-IntuneGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/me"
Write-Host "Authenticated as: $($me.userPrincipalName) ($($me.displayName))`n" -ForegroundColor Green

# 2. Search & Resolve Groups
Write-Host "Resolving Entra ID groups..." -ForegroundColor Yellow
$allGroups = @()
$nextUri = "https://graph.microsoft.com/v1.0/groups?`$select=id,displayName&`$top=999"
while ($nextUri) {
    $res = Invoke-IntuneGraphRequest -Method GET -Uri $nextUri
    $allGroups += $res.value
    $nextUri = $res.'@odata.nextLink'
}

$matchedTarget = $allGroups | Where-Object { 
    $_.displayName -eq $TargetGroupName -or 
    $_.displayName -eq "[Dist] $TargetGroupName" -or 
    $_.displayName -eq "[User] $TargetGroupName" -or
    $_.displayName -like "*$TargetGroupName*"
}

if (-not $matchedTarget) {
    throw "Target group matching '$TargetGroupName' not found in Entra ID."
}

Write-Host "Found matching target groups:" -ForegroundColor Cyan
$matchedTarget | ForEach-Object { Write-Host " - $($_.displayName) (ID: $($_.id))" }

# Pick primary IT Core group
$primaryGroup = $matchedTarget | Where-Object { $_.displayName -eq $TargetGroupName }
if (-not $primaryGroup) { $primaryGroup = $matchedTarget | Where-Object { $_.displayName -eq "[Dist] $TargetGroupName" } }
if (-not $primaryGroup) { $primaryGroup = $matchedTarget | Where-Object { $_.displayName -eq "[User] $TargetGroupName" } }
if (-not $primaryGroup) { $primaryGroup = $matchedTarget[0] }

Write-Host "`nSelected Primary Target Group: '$($primaryGroup.displayName)' ($($primaryGroup.id))`n" -ForegroundColor Green


# 3. Deploy Windows Script (Delete & Recreate for clean IME execution)
$winScriptPath = Join-Path $PSScriptRoot "windows\Windows - National Minute of Silence Reminder.ps1"
if (-not (Test-Path $winScriptPath)) {
    throw "Windows script not found at '$winScriptPath'."
}

$winScriptContent = Get-Content -Path $winScriptPath -Raw -Encoding UTF8
$winScriptB64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($winScriptContent))
$winDisplayName = "Windows - National Minute of Silence Reminder"
$winFileName = "Windows - National Minute of Silence Reminder.ps1"
$winDescription = "Нагадування про загальнонаціональну хвилину мовчання о 09:00 (управління через Планувальник завдань у контексті користувача з точним NTP-синхроном)."

Write-Host "Checking Windows Device Management Scripts in Intune..." -ForegroundColor Yellow
$winScriptsUri = "https://graph.microsoft.com/beta/deviceManagement/deviceManagementScripts"
$allWin = Invoke-IntuneGraphRequest -Method GET -Uri $winScriptsUri
$existingWin = @($allWin.value | Where-Object { $_.displayName -eq $winDisplayName })

if ($existingWin.Count -gt 0) {
    foreach ($oldWin in $existingWin) {
        Write-Host "Deleting existing Windows script ID: $($oldWin.id)..." -ForegroundColor Yellow
        Invoke-IntuneGraphRequest -Method DELETE -Uri "$winScriptsUri/$($oldWin.id)"
    }
}

Write-Host "Creating fresh Windows script '$winDisplayName'..." -ForegroundColor Cyan
$postBody = @{
    displayName           = $winDisplayName
    description           = $winDescription
    scriptContent         = $winScriptB64
    runAsAccount          = "user"
    enforceSignatureCheck = $false
    runAs32Bit            = $false
    fileName              = $winFileName
} | ConvertTo-Json
$createdWin = Invoke-IntuneGraphRequest -Method POST -Uri $winScriptsUri -Body $postBody
$winScriptId = $createdWin.id
Write-Host "[OK] Created Windows script with fresh ID: $winScriptId." -ForegroundColor Green

# Assign Windows Script
Write-Host "Assigning Windows script to '$($primaryGroup.displayName)'..." -ForegroundColor Yellow
$winAssignBody = @{
    deviceManagementScriptGroupAssignments = @(
        @{
            targetGroupId = $primaryGroup.id
        }
    )
} | ConvertTo-Json -Depth 5
Invoke-IntuneGraphRequest -Method POST -Uri "$winScriptsUri/$winScriptId/assign" -Body $winAssignBody
Write-Host "[OK] Windows script assigned successfully.`n" -ForegroundColor Green


# 4. Deploy macOS Shell Script (Delete & Recreate per intune-macos-scripts.md)
$macScriptPath = Join-Path $PSScriptRoot "macos\macOS - National Minute of Silence Reminder.sh"
if (-not (Test-Path $macScriptPath)) {
    throw "macOS script not found at '$macScriptPath'."
}

$macScriptBytes = [System.IO.File]::ReadAllBytes($macScriptPath)
$macScriptB64 = [Convert]::ToBase64String($macScriptBytes)
$macDisplayName = "macOS - National Minute of Silence Reminder"
$macFileName = "macOS - National Minute of Silence Reminder.sh"
$macDescription = "Нагадування про загальнонаціональну хвилину мовчання о 09:00 (LaunchAgent + swiftDialog / osascript з перевіркою часового вікна)."

Write-Host "Checking macOS Device Shell Scripts in Intune..." -ForegroundColor Yellow
$macScriptsUri = "https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts"
$allMac = Invoke-IntuneGraphRequest -Method GET -Uri $macScriptsUri
$existingMac = @($allMac.value | Where-Object { $_.displayName -eq $macDisplayName })

if ($existingMac.Count -gt 0) {
    foreach ($oldMac in $existingMac) {
        Write-Host "Deleting existing macOS shell script ID: $($oldMac.id)..." -ForegroundColor Yellow
        Invoke-IntuneGraphRequest -Method DELETE -Uri "$macScriptsUri/$($oldMac.id)"
    }
}

Write-Host "Creating fresh macOS shell script '$macDisplayName'..." -ForegroundColor Cyan
$postBody = @{
    displayName                 = $macDisplayName
    description                 = $macDescription
    scriptContent               = $macScriptB64
    runAsAccount                = "system"
    blockExecutionNotifications = $true
    retryCount                  = 3
    fileName                    = $macFileName
} | ConvertTo-Json
$createdMac = Invoke-IntuneGraphRequest -Method POST -Uri $macScriptsUri -Body $postBody
$macScriptId = $createdMac.id
Write-Host "[OK] Created macOS shell script with fresh ID: $macScriptId." -ForegroundColor Green

# Assign macOS Script
Write-Host "Assigning macOS script to '$($primaryGroup.displayName)'..." -ForegroundColor Yellow
$macAssignBody = @{
    deviceManagementScriptGroupAssignments = @(
        @{
            targetGroupId = $primaryGroup.id
        }
    )
} | ConvertTo-Json -Depth 5
Invoke-IntuneGraphRequest -Method POST -Uri "$macScriptsUri/$macScriptId/assign" -Body $macAssignBody
Write-Host "[OK] macOS script assigned successfully.`n" -ForegroundColor Green

# 5. Output Summary
Write-Host "==========================================================" -ForegroundColor Green
Write-Host " Intune Deployment Summary                                " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
[PSCustomObject]@{
    Platform = "Windows"
    DisplayName = $winDisplayName
    Id = $winScriptId
    RunAsAccount = "user"
    TargetGroup = $primaryGroup.displayName
} | Format-Table -AutoSize

[PSCustomObject]@{
    Platform = "macOS"
    DisplayName = $macDisplayName
    Id = $macScriptId
    RunAsAccount = "system"
    TargetGroup = $primaryGroup.displayName
} | Format-Table -AutoSize
