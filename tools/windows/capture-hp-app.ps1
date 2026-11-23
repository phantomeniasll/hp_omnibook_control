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

function Get-BatteryBiosSnapshot {
    try {
        $settings = @(
            Get-CimInstance -Namespace 'root\HP\InstrumentedBIOS' -ClassName 'HPBIOS_BIOSEnumeration' -ErrorAction Stop |
                Where-Object { $_.Name -match 'battery|charging|charge limit|charge threshold|^batt_' } |
                Sort-Object Name |
                Select-Object Name, CurrentValue, PossibleValues
        )
        if ($settings.Count -eq 0) {
            Write-Warning 'The HP provider returned no battery-related BIOS settings.'
            return @{ status = 'no_matching_settings'; settings = @() }
        }
        return @{ status = 'ok'; settings = $settings }
    } catch {
        Write-Warning 'Could not read battery-related BIOS settings from the HP provider.'
        return @{ status = 'query_failed'; settings = @() }
    }
}

$settings = [xml](Invoke-EventLogTool @('gl', $channel, '/f:xml') | Out-String)
$wasEnabled = $settings.DocumentElement.GetAttribute('enabled') -eq 'true'
$before = Read-Host 'Record the HP app setting before the change'
if ($Feature -eq 'battery') {
    Write-Host 'Reading battery BIOS settings. Wait for the next prompt before changing myHP.'
    $batteryBefore = Get-BatteryBiosSnapshot
}

try {
    if (-not $wasEnabled) {
        Invoke-EventLogTool @('sl', $channel, '/e:true', '/q')
    }
    $started = [DateTime]::UtcNow
    $after = Read-Host "Change only the $Feature setting in the HP app, then enter its new value"
    $finished = [DateTime]::UtcNow
    if ($Feature -eq 'battery') {
        $batteryAfter = Get-BatteryBiosSnapshot
        @{
            before = $batteryBefore
            after = $batteryAfter
        } | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $folder 'battery-bios.json')
    }
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
