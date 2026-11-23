#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [ValidateSet('battery', 'thermal', 'lighting', 'camera', 'audio', 'other')]
    [string]$Feature = 'battery'
)

$ErrorActionPreference = 'Stop'
$channel = 'Microsoft-Windows-WMI-Activity/Trace'
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$folder = Join-Path (Get-Location).Path "hp-app-$Feature-$timestamp"
New-Item -ItemType Directory -Path $folder | Out-Null

function Invoke-EventLogTool {
    param([string[]]$Arguments)
    $result = & wevtutil.exe @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "wevtutil failed ($LASTEXITCODE): $($Arguments -join ' ')"
    }
    $result
}

$settings = [xml](Invoke-EventLogTool @('gl', $channel, '/f:xml') | Out-String)
$wasEnabled = $settings.DocumentElement.GetAttribute('enabled') -eq 'true'
$before = Read-Host 'Record the HP app setting before the change'
$started = [DateTime]::UtcNow

try {
    if (-not $wasEnabled) {
        Invoke-EventLogTool @('sl', $channel, '/e:true', '/q')
    }
    $after = Read-Host "Change only the $Feature setting in the HP app, then enter its new value"
    $finished = [DateTime]::UtcNow
    Invoke-EventLogTool @('sl', $channel, '/e:false')
    $begin = $started.ToString('o')
    $end = $finished.ToString('o')
    $query = "*[System[TimeCreated[@SystemTime >= '$begin' and @SystemTime <= '$end']]]"
    Invoke-EventLogTool @('epl', $channel, (Join-Path $folder 'wmi.evtx'), "/q:$query")
    @{
        feature = $Feature
        before = $before
        after = $after
        startUtc = $begin
        endUtc = $end
    } | ConvertTo-Json | Set-Content -Encoding UTF8 (Join-Path $folder 'capture.json')
}
finally {
    $enable = if ($wasEnabled) { '/e:true' } else { '/e:false' }
    if ($wasEnabled) {
        Invoke-EventLogTool @('sl', $channel, $enable, '/q')
    } else {
        Invoke-EventLogTool @('sl', $channel, $enable)
    }
}

Get-Process | Where-Object { $_.ProcessName -match '^(HP|myHP|Poly)' } |
    Select-Object ProcessName, Id |
    Export-Csv -NoTypeInformation (Join-Path $folder 'hp-processes.csv')
Get-CimInstance Win32_Service -Filter "Name LIKE 'HP%' OR DisplayName LIKE 'HP%'" |
    Select-Object Name, DisplayName, State, ProcessId |
    Export-Csv -NoTypeInformation (Join-Path $folder 'hp-services.csv')
Write-Output "Capture saved to $folder"
