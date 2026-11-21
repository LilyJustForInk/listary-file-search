#Requires -Version 7.0
<#
.SYNOPSIS
  Find indexed local files and folders using Listary 7's loopback HTTP API.
.DESCRIPTION
  Read-only by default. -Enable/-Disable require -Apply and restart the Listary UI.
  Always launch with: pwsh -NoProfile -File <path-to-script> ...
.EXAMPLE
  pwsh -NoProfile -File .\listary.ps1 -Query 'ANEMONE' -Limit 10 -Format compact
.EXAMPLE
  pwsh -NoProfile -File .\listary.ps1 -Query '*.ps1' -Format paths
.EXAMPLE
  pwsh -NoProfile -File .\listary.ps1 -Doctor
.NOTES
  Exit codes: 0 success; 1 invalid input; 2 API unreachable;
              3 HTTP/API/response error; 4 local config/restart failure.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Query,

    [ValidateRange(1, 100)]
    [int]$Limit = 20,

    [ValidateRange(0, [int]::MaxValue)]
    [int]$Offset = 0,

    [string[]]$SearchIn,

    [ValidateSet('file', 'folder')]
    [string[]]$Types,

    [string[]]$Extensions,

    [ValidateSet('table', 'paths', 'json', 'compact')]
    [string]$Format = 'table',

    [string]$Endpoint,

    # Zero means auto-detect; -Port is for the CLI, not an HTTP server setting.
    [ValidateRange(0, 65535)]
    [int]$Port = 0,

    [switch]$Doctor,
    [switch]$Enable,
    [switch]$Disable,

    # Deliberate second switch for operations that edit settings/restart Listary.
    [switch]$Apply
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$DefaultPort = 41234
$PreferencesPath = if ($env:APPDATA) {
    Join-Path $env:APPDATA 'Listary\UserProfile\Settings\Preferences.json'
} else { $null }

function Fail {
    param([int]$Code, [string]$Message)
    [Console]::Error.WriteLine($Message)
    exit $Code
}

function Test-PortValue {
    param([object]$Value, [string]$Source)
    $number = 0
    if (-not [int]::TryParse([string]$Value, [ref]$number) -or
        $number -lt 1 -or $number -gt 65535) {
        throw "Invalid port in ${Source}: '$Value' (expected 1..65535)."
    }
    return $number
}

function Read-Preferences {
    if (-not $PreferencesPath -or -not (Test-Path -LiteralPath $PreferencesPath -PathType Leaf)) {
        return $null
    }
    $bytes = [System.IO.File]::ReadAllBytes($PreferencesPath)
    $decoder = [System.Text.UTF8Encoding]::new($false, $true)
    $raw = $decoder.GetString($bytes).TrimStart([char]0xFEFF)
    $prefs = ConvertFrom-Json -InputObject $raw -Depth 100
    if ($null -eq $prefs -or $null -eq $prefs.Settings -or
        $prefs.Settings -isnot [pscustomobject]) {
        throw 'Preferences.json must contain a JSON object with a Settings object.'
    }
    return $prefs
}

function Get-ConfiguredPort {
    param($Preferences)
    if ($null -ne $Preferences) {
        $value = $Preferences.Settings.'General.HttpApi.Port'
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value) -and
            [string]$value -ne '0') {
            return (Test-PortValue -Value $value -Source 'Preferences.json')
        }
    }
    return $DefaultPort
}

function Resolve-Endpoint {
    # Highest priority: CLI endpoint > environment endpoint > CLI port >
    # environment port > preferences port > documented local fallback.
    $urlOverride = if (-not [string]::IsNullOrWhiteSpace($Endpoint)) {
        $Endpoint
    } elseif (-not [string]::IsNullOrWhiteSpace($env:LISTARY_HTTP_ENDPOINT)) {
        $env:LISTARY_HTTP_ENDPOINT
    } else { $null }

    if ($urlOverride) {
        $match = [regex]::Match($urlOverride.Trim(),
            '^http://(?:127\.0\.0\.1|localhost):([0-9]{1,5})/api/v1/search/?$',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if (-not $match.Success) {
            throw 'Endpoint must be http://127.0.0.1:<port>/api/v1/search (localhost also allowed). Remote hosts, query strings and HTTPS are not supported.'
        }
        $listenPort = Test-PortValue -Value $match.Groups[1].Value -Source 'endpoint'
        return [pscustomobject]@{ Uri = "http://127.0.0.1:$listenPort/api/v1/search"; Port = $listenPort; Source = 'endpoint override' }
    }

    if ($Port -gt 0) {
        $listenPort = $Port
        $source = '-Port'
    } elseif (-not [string]::IsNullOrWhiteSpace($env:LISTARY_HTTP_PORT)) {
        $listenPort = Test-PortValue -Value $env:LISTARY_HTTP_PORT -Source 'LISTARY_HTTP_PORT'
        $source = 'LISTARY_HTTP_PORT'
    } else {
        $prefs = Read-Preferences
        $listenPort = Get-ConfiguredPort -Preferences $prefs
        $source = if ($null -ne $prefs -and $null -ne $prefs.Settings.'General.HttpApi.Port') {
            'Preferences.json'
        } else { 'fallback' }
    }
    return [pscustomobject]@{ Uri = "http://127.0.0.1:$listenPort/api/v1/search"; Port = $listenPort; Source = $source }
}

function Get-ListaryExe {
    $candidates = @('C:\Program Files\Listary\Listary.exe')
    if ($env:LOCALAPPDATA) {
        $candidates += (Join-Path $env:LOCALAPPDATA 'Programs\Listary\Listary.exe')
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    $running = Get-Process -Name Listary -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($running -and $running.Path -and (Test-Path -LiteralPath $running.Path -PathType Leaf)) {
        return $running.Path
    }
    return $null
}

function Test-LocalListener {
    param([int]$ListenPort)
    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connection = $client.ConnectAsync('127.0.0.1', $ListenPort)
        if (-not $connection.Wait(350)) { return $false }
        return $client.Connected
    } catch { return $false }
    finally { $client.Dispose() }
}

function Invoke-SearchRequest {
    param([string]$Uri, [hashtable]$Body, [int]$TimeoutSec = 8)
    # Send actual UTF-8 bytes, not a platform-dependent string encoding.
    $json = $Body | ConvertTo-Json -Compress -Depth 8
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    return Invoke-WebRequest -Uri $Uri -Method Post -Body $bytes `
        -ContentType 'application/json; charset=utf-8' -NoProxy `
        -SkipHttpErrorCheck -TimeoutSec $TimeoutSec
}

function Inspect-Response {
    param($Response)
    $payload = $null
    try { $payload = ConvertFrom-Json -InputObject ([string]$Response.Content) -Depth 20 }
    catch {
        return [pscustomobject]@{ Ok = $false; Payload = $null; Reason = "Invalid JSON: $($_.Exception.Message)" }
    }
    if ([int]$Response.StatusCode -ne 200) {
        return [pscustomobject]@{ Ok = $false; Payload = $payload; Reason = "HTTP $($Response.StatusCode) $($payload.error): $($payload.message)" }
    }
    if ($null -eq $payload -or $payload.ok -ne $true -or $null -eq $payload.data -or
        $null -eq $payload.data.results -or $null -eq $payload.data.total -or
        $null -eq $payload.data.count -or $null -eq $payload.data.offset) {
        $reason = if ($payload -and $payload.error) {
            "$($payload.error): $($payload.message)"
        } else { 'Missing or malformed response fields' }
        return [pscustomobject]@{ Ok = $false; Payload = $payload; Reason = $reason }
    }
    $items = @($payload.data.results)
    if ([int]$payload.data.count -ne $items.Count -or
        $payload.data.total -lt $payload.data.count -or
        $payload.data.offset -lt 0) {
        return [pscustomobject]@{ Ok = $false; Payload = $payload; Reason = 'Inconsistent count/total/offset in response' }
    }
    foreach ($item in $items) {
        if ($null -eq $item -or [string]::IsNullOrWhiteSpace([string]$item.path)) {
            return [pscustomobject]@{ Ok = $false; Payload = $payload; Reason = 'Result is missing a path' }
        }
    }
    return [pscustomobject]@{ Ok = $true; Payload = $payload; Reason = 'OK' }
}

function Show-Doctor {
    $prefs = $null
    $prefsError = $null
    try { $prefs = Read-Preferences }
    catch { $prefsError = $_.Exception.Message }

    Write-Output "listary.exe     : $(if (Get-ListaryExe) { Get-ListaryExe } else { 'NOT FOUND' })"
    $processIds = @((Get-Process -Name Listary -ErrorAction SilentlyContinue) | ForEach-Object { $_.Id })
    Write-Output "process ids     : $(if ($processIds.Count) { $processIds -join ',' } else { '(not running)' })"
    Write-Output "prefs           : $(if ($PreferencesPath -and (Test-Path -LiteralPath $PreferencesPath)) { $PreferencesPath } else { 'NOT FOUND' })"
    if ($prefsError) { Write-Output "prefs error     : $prefsError" }
    $enabled = if ($prefs) { $prefs.Settings.'General.HttpApi.Enabled' } else { $null }
    $savedPort = if ($prefs) { $prefs.Settings.'General.HttpApi.Port' } else { $null }
    Write-Output "enabled (prefs) : $(if ($null -eq $enabled) { '(unset)' } else { $enabled })"
    Write-Output "port (prefs)    : $(if ($null -eq $savedPort) { '(unset)' } else { $savedPort })"

    try { $target = Resolve-Endpoint }
    catch { Fail 1 $_.Exception.Message }
    Write-Output "endpoint        : $($target.Uri)"
    Write-Output "port source     : $($target.Source)"
    Write-Output "tcp listening   : $(Test-LocalListener -ListenPort $target.Port)"

    try { $response = Invoke-SearchRequest -Uri $target.Uri -Body @{ query = 'listary'; limit = 1 } -TimeoutSec 3 }
    catch {
        Write-Output "probe           : UNREACHABLE ($($_.Exception.Message))"
        Write-Output 'If you want to enable the API, get user approval first, then use -Enable -Apply.'
        exit 2
    }
    $check = Inspect-Response -Response $response
    if ($check.Ok) {
        Write-Output 'probe           : OK (valid Listary search response)'
        exit 0
    }
    Write-Output "probe           : $($check.Reason)"
    exit 3
}

function Stop-ListaryUi {
    $processes = @(Get-Process -Name Listary -ErrorAction SilentlyContinue)
    foreach ($proc in $processes) {
        try {
            $null = $proc.CloseMainWindow()
            if ($proc.WaitForExit(3000)) { continue }
        } catch { }
        $stillRunning = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
        if ($stillRunning) {
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            $stillRunning.WaitForExit(3000) | Out-Null
        }
    }
}

function Start-ListaryUi {
    param([string]$Exe)
    if (-not (Get-Process -Name Listary -ErrorAction SilentlyContinue)) {
        Start-Process -FilePath $Exe -ArgumentList '--startup' -ErrorAction Stop | Out-Null
    }
}

function Put-Setting {
    param($Settings, [string]$Key, $Value)
    $property = $Settings.PSObject.Properties[$Key]
    if ($null -ne $property) { $property.Value = $Value }
    else { $Settings | Add-Member -NotePropertyName $Key -NotePropertyValue $Value }
}

function Write-PreferencesAtomic {
    param([bool]$Enabled, [int]$ListenPort, [string]$BackupPath)
    if (-not $PreferencesPath -or -not (Test-Path -LiteralPath $PreferencesPath -PathType Leaf)) {
        throw 'Preferences.json is missing. No configuration was created or overwritten.'
    }
    $bytes = [System.IO.File]::ReadAllBytes($PreferencesPath)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $prefs = Read-Preferences
    [System.IO.File]::Copy($PreferencesPath, $BackupPath, $false)

    Put-Setting -Settings $prefs.Settings -Key 'General.HttpApi.Enabled' -Value $Enabled
    if ($Enabled) {
        Put-Setting -Settings $prefs.Settings -Key 'General.HttpApi.Port' -Value $ListenPort
    }
    $newJson = $prefs | ConvertTo-Json -Depth 100
    $tmp = "$PreferencesPath.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($tmp, $newJson, [System.Text.UTF8Encoding]::new($bom))
        [System.IO.File]::Move($tmp, $PreferencesPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Wait-ListaryState {
    param([bool]$Enabled, [int]$ListenPort)
    $uri = "http://127.0.0.1:$ListenPort/api/v1/search"
    for ($i = 0; $i -lt 24; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Process -Name Listary -ErrorAction SilentlyContinue)) { continue }
        if (-not $Enabled) {
            if (-not (Test-LocalListener -ListenPort $ListenPort)) { return $true }
            continue
        }
        try {
            $reply = Invoke-SearchRequest -Uri $uri -Body @{ query = 'listary'; limit = 1 } -TimeoutSec 2
            if ((Inspect-Response -Response $reply).Ok) { return $true }
        } catch { }
    }
    return $false
}

function Change-ListaryApi {
    param([bool]$Enabled)
    if (-not $IsWindows) { Fail 4 'Configuration changes are supported on Windows only.' }
    if (-not $Apply) { Fail 1 'Not changing any settings. After explicit user approval, add -Apply to -Enable or -Disable.' }
    if ($Endpoint) { Fail 1 '-Endpoint is read-only (search/doctor). Use -Port to choose the local API port.' }
    if (-not $Enabled -and $script:ExplicitPort) {
        Fail 1 '-Disable always uses the saved API port; omit -Port to avoid verifying the wrong listener.'
    }

    $exe = Get-ListaryExe
    if (-not $exe) { Fail 4 'Listary.exe was not found. No changes made.' }
    try {
        $prefs = Read-Preferences
        if ($null -eq $prefs) { throw 'Preferences.json is missing; refusing to create one.' }
        $savedPort = Get-ConfiguredPort -Preferences $prefs
        $targetPort = if ($Port -gt 0) { $Port } else { $savedPort }
        $currentlyEnabled = ($prefs.Settings.'General.HttpApi.Enabled' -eq $true)
    }
    catch { Fail 4 "Cannot inspect Listary settings: $($_.Exception.Message)" }

    # Already in the requested, verified state: avoid needless UI restarts.
    if ($currentlyEnabled -eq $Enabled -and (-not $Enabled -or $savedPort -eq $targetPort)) {
        if (-not $Enabled -and -not (Test-LocalListener -ListenPort $savedPort)) {
            Write-Output 'API already disabled; no settings changed or Listary restart.'
            return
        }
        if ($Enabled) {
            try {
                $checkUri = "http://127.0.0.1:$targetPort/api/v1/search"
                $probe = Invoke-SearchRequest -Uri $checkUri -Body @{ query = 'listary'; limit = 1 } -TimeoutSec 3
                if ((Inspect-Response -Response $probe).Ok) {
                    Write-Output "API already enabled and healthy at $checkUri; no changes made."
                    return
                }
            } catch { }
        }
    }

    $backup = $null
    $stopped = $false
    try {
        # Stop first: a running app could overwrite the JSON while shutting down.
        $stopped = $true
        Stop-ListaryUi
        $backup = "$PreferencesPath.$(Get-Date -Format 'yyyyMMdd-HHmmss-fff').$([guid]::NewGuid().ToString('N').Substring(0, 8)).bak"
        Write-PreferencesAtomic -Enabled $Enabled -ListenPort $targetPort -BackupPath $backup
        $afterWrite = Read-Preferences
        if (($afterWrite.Settings.'General.HttpApi.Enabled' -eq $true) -ne $Enabled) {
            throw 'Failed to verify General.HttpApi.Enabled on disk.'
        }
        if ($Enabled -and ((Get-ConfiguredPort -Preferences $afterWrite) -ne $targetPort)) {
            throw 'Failed to verify General.HttpApi.Port on disk.'
        }
        Start-ListaryUi -Exe $exe
        if (-not (Wait-ListaryState -Enabled $Enabled -ListenPort $targetPort)) {
            throw "Listary state could not be verified after restart (port $targetPort)."
        }
        Write-Output "backup   : $backup"
        Write-Output "api      : $(if ($Enabled) { 'enabled' } else { 'disabled' })"
        Write-Output "endpoint : http://127.0.0.1:$targetPort/api/v1/search"
        Write-Output 'Listary restarted; settings verified.'
        return
    }
    catch {
        $failure = $_.Exception.Message
        $rollback = 'not needed (settings were not rewritten)'
        try {
            if ($backup -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
                Stop-ListaryUi
                [System.IO.File]::Copy($backup, $PreferencesPath, $true)
                $rollback = "restored from $backup"
            }
            if ($stopped) { Start-ListaryUi -Exe $exe }
        }
        catch { $rollback = "FAILED: $($_.Exception.Message) (backup: $backup)" }
        Fail 4 "Listary configuration/restart failed: $failure. Rollback: $rollback"
    }
}

# Validate mode conflicts before any side effects.
$script:ExplicitPort = $PSBoundParameters.ContainsKey('Port')
if ($script:ExplicitPort -and $Port -eq 0) { Fail 1 'Port must be 1..65535 when explicitly provided.' }
$modeCount = [int][bool]$Doctor + [int][bool]$Enable + [int][bool]$Disable
if ($modeCount -gt 1) { Fail 1 '-Doctor, -Enable and -Disable are mutually exclusive.' }
if ($Apply -and -not ($Enable -or $Disable)) { Fail 1 '-Apply can only be used with -Enable or -Disable.' }
if ($Doctor) { Show-Doctor }
if ($Enable) { Change-ListaryApi -Enabled $true; exit 0 }
if ($Disable) { Change-ListaryApi -Enabled $false; exit 0 }

if ([string]::IsNullOrWhiteSpace($Query)) { Fail 1 'Query is required (or use -Doctor).' }
if ($SearchIn) {
    foreach ($directory in $SearchIn) {
        if ([string]::IsNullOrWhiteSpace($directory) -or
            -not [System.IO.Path]::IsPathFullyQualified($directory)) {
            Fail 1 "SearchIn must contain absolute directory paths, got '$directory'."
        }
    }
}

$cleanExtensions = @()
foreach ($extension in @($Extensions)) {
    if ($null -eq $extension) { continue }
    $clean = $extension.Trim().TrimStart('.')
    if (-not $clean -or $clean -notmatch '^[\p{L}\p{N}_+\-]+$') {
        Fail 1 "Invalid extension '$extension'. Use md, pdf, .ps1, etc."
    }
    $cleanExtensions += $clean
}

try { $target = Resolve-Endpoint }
catch { Fail 1 $_.Exception.Message }

$body = @{ query = $Query; limit = [int]$Limit }
if ($Offset -gt 0) { $body.offset = [int]$Offset }
if ($SearchIn) { $body.search_in = @($SearchIn) }
if ($Types) { $body.types = @($Types) }
if ($cleanExtensions.Count) { $body.extensions = @($cleanExtensions) }

$watch = [System.Diagnostics.Stopwatch]::StartNew()
try { $response = Invoke-SearchRequest -Uri $target.Uri -Body $body }
catch { Fail 2 "Listary API unreachable at $($target.Uri). Run -Doctor. $($_.Exception.Message)" }
$watch.Stop()

$check = Inspect-Response -Response $response
if (-not $check.Ok) { Fail 3 "Listary API error: $($check.Reason)" }
$data = $check.Payload.data
$results = @($data.results)

switch ($Format) {
    'json' { Write-Output ([string]$response.Content) }
    'paths' { foreach ($item in $results) { Write-Output ([string]$item.path) } }
    'compact' {
        $next = if ($data.count -gt 0 -and ($data.offset + $data.count) -lt $data.total) { $data.offset + $data.count } else { '-' }
        Write-Output ("total={0} returned={1} offset={2} next_offset={3}" -f $data.total, $data.count, $data.offset, $next)
        foreach ($item in $results) { Write-Output ([string]$item.path) }
    }
    default {
        Write-Output ("query='{0}' total={1} returned={2} offset={3} {4}ms" -f `
            $data.query, $data.total, $data.count, $data.offset, [math]::Round($watch.Elapsed.TotalMilliseconds))
        $next = $data.offset + $data.count
        if ($data.count -gt 0 -and $next -lt $data.total) { Write-Output "more results: use -Offset $next" }
        foreach ($item in $results) {
            $size = if ($null -ne $item.size_bytes) { $item.size_bytes } else { '-' }
            Write-Output ("{0,-6} {1,10}  {2}" -f $item.type, $size, $item.path)
        }
    }
}
exit 0
