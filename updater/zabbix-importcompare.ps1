param(
    [string]$ReleaseVersion = "2.0.0",
    [string]$ApiUrl = "http://localhost/api_jsonrpc.php"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Sprut Monitor Zabbix Native Import Compare ==="
Write-Host "Release: $ReleaseVersion"
Write-Host ""

$repoRoot = Split-Path $PSScriptRoot -Parent
$releasePath = Join-Path $repoRoot "releases\$ReleaseVersion"
$sourcePath = Join-Path $releasePath "zabbix-export.yaml"

if (-not (Test-Path $sourcePath)) {
    throw "Native Zabbix export not found: $sourcePath"
}

$username = [Environment]::GetEnvironmentVariable("ZABBIX_USERNAME", "Machine")
$password = [Environment]::GetEnvironmentVariable("ZABBIX_PASSWORD", "Machine")

if ([string]::IsNullOrWhiteSpace($username)) {
    throw "System environment variable ZABBIX_USERNAME is not set."
}
if ([string]::IsNullOrWhiteSpace($password)) {
    throw "System environment variable ZABBIX_PASSWORD is not set."
}

$source = Get-Content $sourcePath -Raw

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

    $response = Invoke-RestMethod -Uri $ApiUrl -Method Post -ContentType "application/json-rpc" -Body $body

    if ($response.error) {
        throw ($response.error | ConvertTo-Json -Depth 20)
    }

    return $response.result
}

Write-Host "Authenticating..."

$login = Invoke-ZabbixApi `
    -Method "user.login" `
    -Params @{
        username = $username
        password = $password
    } `
    -Token $null `
    -Id 1

Write-Host "Authentication successful."
Write-Host ""
Write-Host "Calling configuration.importcompare..."
Write-Host "Format: yaml"
Write-Host ""

$rules = @{
    templates = @{
        createMissing = $true
        updateExisting = $true
    }
    items = @{
        createMissing = $true
        updateExisting = $true
        deleteMissing = $false
    }
    triggers = @{
        createMissing = $true
        updateExisting = $true
        deleteMissing = $false
    }
    graphs = @{
        createMissing = $true
        updateExisting = $true
        deleteMissing = $false
    }
    valueMaps = @{
        createMissing = $true
        updateExisting = $true
        deleteMissing = $false
    }
    templateDashboards = @{
        createMissing = $true
        updateExisting = $true
        deleteMissing = $false
    }
}

$result = Invoke-ZabbixApi `
    -Method "configuration.importcompare" `
    -Params @{
        format = "yaml"
        source = $source
        rules = $rules
    } `
    -Token $login `
    -Id 2

Write-Host "Native import comparison result:"
$result | ConvertTo-Json -Depth 100

Write-Host ""
Write-Host "No Zabbix configuration was changed."