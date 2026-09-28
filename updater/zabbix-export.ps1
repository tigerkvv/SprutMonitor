param(
    [string]$ReleaseVersion = "2.0.0",
    [string]$OutputPath = "",
    [string]$Template = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path $PSScriptRoot -Parent
$releasePath = Join-Path $repoRoot "releases\$ReleaseVersion"
$manifestPath = Join-Path $releasePath "manifest.yaml"

if (-not (Test-Path $manifestPath)) { throw "Release manifest not found: $manifestPath" }

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    if ([string]::IsNullOrWhiteSpace($Template)) {
        $OutputPath = Join-Path $releasePath "zabbix-export.yaml"
    }
    else {
        $safeTemplate = ($Template -replace '[^a-zA-Z0-9._-]', '_')
        $OutputPath = Join-Path $releasePath "zabbix-export-$safeTemplate.yaml"
    }
}

$login = [Environment]::GetEnvironmentVariable("ZABBIX_USERNAME", "Machine")
$password = [Environment]::GetEnvironmentVariable("ZABBIX_PASSWORD", "Machine")

if ([string]::IsNullOrWhiteSpace($login)) { throw "System environment variable ZABBIX_USERNAME is not set." }
if ([string]::IsNullOrWhiteSpace($password)) { throw "System environment variable ZABBIX_PASSWORD is not set." }

$manifestText = Get-Content $manifestPath -Raw
$templateNames = @(
    [regex]::Matches($manifestText, '(?m)^\s*-\s+(.+?)\s*$') |
        ForEach-Object { $_.Groups[1].Value.Trim().Trim("'").Trim('"') }
)

if ($templateNames.Count -eq 0) { throw "No templates found in manifest: $manifestPath" }

if (-not [string]::IsNullOrWhiteSpace($Template)) {
    $templateNames = @($Template)
}

function Invoke-ZabbixApi {
    param([string]$Method, [hashtable]$Params, [string]$Token, [int]$Id)

    $body = @{
        jsonrpc = "2.0"
        method = $Method
        params = $Params
        auth = $Token
        id = $Id
    } | ConvertTo-Json -Depth 50

    $response = Invoke-RestMethod -Uri "http://localhost/api_jsonrpc.php" -Method Post -ContentType "application/json-rpc" -Body $body
    if ($response.error) { throw ($response.error | ConvertTo-Json -Depth 20) }
    return $response.result
}

Write-Host "=== Sprut Monitor Zabbix Native Export ==="
Write-Host "Release: $ReleaseVersion"

if (-not [string]::IsNullOrWhiteSpace($Template)) {
    Write-Host "Single template test: $Template"
}

Write-Host ""

$loginBody = @{
    jsonrpc = "2.0"
    method = "user.login"
    params = @{ username = $login; password = $password }
    id = 1
} | ConvertTo-Json -Depth 20

$auth = Invoke-RestMethod -Uri "http://localhost/api_jsonrpc.php" -Method Post -ContentType "application/json-rpc" -Body $loginBody
if (-not $auth.result) { throw "Zabbix authentication failed." }

$token = $auth.result
Write-Host "Authentication successful."
Write-Host ""

$templates = Invoke-ZabbixApi -Method "template.get" -Params @{ output = @("templateid", "name") } -Token $token -Id 2
$templateIds = @()

foreach ($templateName in $templateNames) {
    $matches = @($templates | Where-Object { $_.name -eq $templateName })
    if ($matches.Count -ne 1) { throw "Expected exactly one template named '$templateName', found $($matches.Count)." }
    $templateIds += [string]$matches[0].templateid
    Write-Host "Template: $templateName -> templateid $($matches[0].templateid)"
}

Write-Host ""
Write-Host "Calling configuration.export..."
Write-Host "Format: yaml"
Write-Host ""

$export = Invoke-ZabbixApi -Method "configuration.export" -Params @{
    options = @{ templates = $templateIds }
    format = "yaml"
    prettyprint = $true
} -Token $token -Id 3

if ([string]::IsNullOrWhiteSpace([string]$export)) { throw "Zabbix returned an empty configuration export." }

$parent = Split-Path $OutputPath -Parent
if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

[System.IO.File]::WriteAllText($OutputPath, [string]$export, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "Native Zabbix export saved:"
Write-Host $OutputPath
Write-Host ""
Write-Host "No Zabbix configuration was changed."
