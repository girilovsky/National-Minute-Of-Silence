<#
.SYNOPSIS
    Deploys the National Minute of Silence reminder scripts to Microsoft Intune
    for Windows and macOS, targeting the IT Core group.

.DESCRIPTION
    1. Authenticates via MicrosoftTokenBridge (or existing MgGraph session).
    2. Resolves Entra ID groups (Target: IT Core, Exclusion: [Dist] Minute of Silence - Exclusions).
    3. Creates or updates Windows Device Management Script ("Windows - National Minute of Silence Reminder").
    4. Creates or updates macOS Device Shell Script ("macOS - National Minute of Silence Reminder").
    5. Assigns scripts to the target group.
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


# 3. Deploy Windows Script
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
$existingWin = Invoke-IntuneGraphRequest -Method GET -Uri "$winScriptsUri`?`$filter=displayName eq '$winDisplayName'"

$winScriptId = $null
if ($existingWin.value -and $existingWin.value.Count -gt 0) {
    $winScriptId = $existingWin.value[0].id
    Write-Host "Found existing Windows script '$winDisplayName' ($winScriptId). Updating content..." -ForegroundColor Cyan
    $patchBody = @{
        description           = $winDescription
        scriptContent         = $winScriptB64
        runAsAccount          = "user"
        enforceSignatureCheck = $false
        runAs32Bit            = $false
    } | ConvertTo-Json
    Invoke-IntuneGraphRequest -Method PATCH -Uri "$winScriptsUri/$winScriptId" -Body $patchBody
    Write-Host "[OK] Windows script updated successfully." -ForegroundColor Green
} else {
    Write-Host "Creating new Windows script '$winDisplayName'..." -ForegroundColor Cyan
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
    Write-Host "[OK] Created Windows script with ID: $winScriptId." -ForegroundColor Green
}

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

# 4. Deploy macOS Shell Script
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
$existingMac = Invoke-IntuneGraphRequest -Method GET -Uri "$macScriptsUri`?`$filter=displayName eq '$macDisplayName'"

$macScriptId = $null
if ($existingMac.value -and $existingMac.value.Count -gt 0) {
    $macScriptId = $existingMac.value[0].id
    Write-Host "Found existing macOS script '$macDisplayName' ($macScriptId). Updating content..." -ForegroundColor Cyan
    $patchBody = @{
        description                 = $macDescription
        scriptContent               = $macScriptB64
        runAsAccount                = "system"
        blockExecutionNotifications = $true
        retryCount                  = 3
    } | ConvertTo-Json
    Invoke-IntuneGraphRequest -Method PATCH -Uri "$macScriptsUri/$macScriptId" -Body $patchBody
    Write-Host "[OK] macOS script updated successfully." -ForegroundColor Green
} else {
    Write-Host "Creating new macOS shell script '$macDisplayName'..." -ForegroundColor Cyan
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
    Write-Host "[OK] Created macOS shell script with ID: $macScriptId." -ForegroundColor Green
}

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
