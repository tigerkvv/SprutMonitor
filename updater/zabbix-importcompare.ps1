param(
    [string]$ReleaseVersion = "2.0.0",
    [string]$ApiUrl = "http://localhost/api_jsonrpc.php",
    [int]$TimeoutSec = 300,
    [string]$InputPath = ""
)

$ErrorActionPreference = "Stop"
$scriptStart = Get-Date

function Write-Status {
    param([string]$Message)
    $elapsed = [int]((Get-Date) - $scriptStart).TotalSeconds
    Write-Host ("[{0,6}s] {1}" -f $elapsed, $Message)
}

Write-Status "=== Sprut Monitor Zabbix Native Import Compare ==="
Write-Status "Release: $ReleaseVersion"

$repoRoot = Split-Path $PSScriptRoot -Parent
$releasePath = Join-Path $repoRoot "releases\$ReleaseVersion"

if ([string]::IsNullOrWhiteSpace($InputPath)) {
    $sourcePath = Join-Path $releasePath "zabbix-export.yaml"
}
else {
    if ([System.IO.Path]::IsPathRooted($InputPath)) {
        $sourcePath = $InputPath
    }
    else {
        $sourcePath = Join-Path $repoRoot $InputPath
    }
}

if (-not (Test-Path $sourcePath)) {
    throw "Native Zabbix export not found: $sourcePath"
}

Write-Status "Reading native export: $sourcePath"
$source = [System.IO.File]::ReadAllText($sourcePath, (New-Object System.Text.UTF8Encoding($false)))
$sourceBytes = [System.Text.Encoding]::UTF8.GetByteCount($source)
Write-Status ("Native export loaded: {0:N0} bytes" -f $sourceBytes)

$username = [Environment]::GetEnvironmentVariable("ZABBIX_USERNAME", "Machine")
$password = [Environment]::GetEnvironmentVariable("ZABBIX_PASSWORD", "Machine")

if ([string]::IsNullOrWhiteSpace($username)) {
    throw "System environment variable ZABBIX_USERNAME is not set."
}
if ([string]::IsNullOrWhiteSpace($password)) {
    throw "System environment variable ZABBIX_PASSWORD is not set."
}

function Invoke-ZabbixApi {
    param(
        [string]$Method,
        [hashtable]$Params,
        [string]$Token,
        [int]$Id
    )

    $request = @{
        jsonrpc = "2.0"
        method = $Method
        params = $Params
        id = $Id
    }

    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $request.auth = $Token
    }

    $body = $request | ConvertTo-Json -Depth 100
    $bodyBytes = [System.Text.Encoding]::UTF8.GetByteCount($body)

    Write-Status ("HTTP request: {0}; payload {1:N0} bytes; timeout {2}s" -f $Method, $bodyBytes, $TimeoutSec)
    Write-Status "Waiting for Zabbix response..."

    $job = Start-Job -ScriptBlock {
        param($Uri, $RequestBody)
        Invoke-RestMethod -Uri $Uri -Method Post -ContentType "application/json-rpc" -Body $RequestBody
    } -ArgumentList $ApiUrl, $body

    $waitStart = Get-Date

    try {
        while ($true) {
            $state = $job.State

            if ($state -eq "Completed") {
                $response = Receive-Job $job
                break
            }

            if ($state -eq "Failed" -or $state -eq "Stopped") {
                $reason = $job.ChildJobs[0].JobStateInfo.Reason
                if ($reason) {
                    throw $reason
                }
                throw "HTTP job ended with state: $state"
            }

            $waited = [int]((Get-Date) - $waitStart).TotalSeconds
            Write-Host ("\r[{0,6}s] Waiting for Zabbix response... state={1}" -f $waited, $state) -NoNewline
            Start-Sleep -Seconds 1

            if (((Get-Date) - $waitStart).TotalSeconds -ge $TimeoutSec) {
                Stop-Job $job -ErrorAction SilentlyContinue
                throw "Zabbix API request timed out after $TimeoutSec seconds: $Method"
            }
        }
    }
    finally {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        Write-Host ""
    }

    if ($response.error) {
        throw ($response.error | ConvertTo-Json -Depth 20)
    }

    return $response.result
}

Write-Status "Authenticating..."
$login = Invoke-ZabbixApi `
    -Method "user.login" `
    -Params @{
        username = $username
        password = $password
    } `
    -Token $null `
    -Id 1
Write-Status "Authentication successful."

$rules = @{
    templates = @{ createMissing = $true; updateExisting = $true }
    items = @{ createMissing = $true; updateExisting = $true; deleteMissing = $false }
    triggers = @{ createMissing = $true; updateExisting = $true; deleteMissing = $false }
    graphs = @{ createMissing = $true; updateExisting = $true; deleteMissing = $false }
    valueMaps = @{ createMissing = $true; updateExisting = $true; deleteMissing = $false }
    templateDashboards = @{ createMissing = $true; updateExisting = $true; deleteMissing = $false }
}

Write-Status "Prepared import comparison rules."
Write-Status "Calling configuration.importcompare..."

$result = Invoke-ZabbixApi `
    -Method "configuration.importcompare" `
    -Params @{
        format = "yaml"
        source = $source
        rules = $rules
    } `
    -Token $login `
    -Id 2

Write-Status "configuration.importcompare completed."
Write-Host "Native import comparison result:"
$result | ConvertTo-Json -Depth 100

Write-Status "No Zabbix configuration was changed."
