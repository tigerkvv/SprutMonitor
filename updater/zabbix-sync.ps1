param(
    [string]$OutputPath = "R:\SprutMonitor\releases\1.1.0\zabbix-managed.json"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Sprut Monitor Zabbix Sync ==="

$login = Read-Host "Zabbix username"
$password = Read-Host "Zabbix password" -AsSecureString

$plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
)

function Invoke-ZabbixApi {
    param(
        [string]$Method,
        [hashtable]$Params,
        [string]$Token,
        [int]$Id
    )

    $body = @{
        jsonrpc = "2.0"
        method  = $Method
        params  = $Params
        auth    = $Token
        id      = $Id
    } | ConvertTo-Json -Depth 100

    $response = Invoke-RestMethod `
        -Uri "http://localhost/api_jsonrpc.php" `
        -Method Post `
        -ContentType "application/json-rpc" `
        -Body $body

    if ($response.error) {
        throw ($response.error | ConvertTo-Json -Depth 20)
    }

    return $response.result
}

# ------------------------------------------------------------
# Login
# ------------------------------------------------------------

$loginBody = @{
    jsonrpc = "2.0"
    method  = "user.login"
    params  = @{
        username = $login
        password = $plainPassword
    }
    id = 1
} | ConvertTo-Json -Depth 20

$auth = Invoke-RestMethod `
    -Uri "http://localhost/api_jsonrpc.php" `
    -Method Post `
    -ContentType "application/json-rpc" `
    -Body $loginBody

if (-not $auth.result) {
    throw "Zabbix authentication failed."
}

$token = $auth.result

Write-Host "Авторизация успешна."

# ------------------------------------------------------------
# Read manifest
# ------------------------------------------------------------

$manifestPath = "R:\SprutMonitor\releases\1.1.0\manifest.yaml"

if (-not (Test-Path $manifestPath)) {
    throw "Manifest not found: $manifestPath"
}

$manifestLines = Get-Content $manifestPath

$templateNames = @()
$inTemplates = $false

foreach ($line in $manifestLines) {

    $trimmed = $line.Trim()

    if ($trimmed -eq "templates:") {
        $inTemplates = $true
        continue
    }

    if ($inTemplates) {

        if ($trimmed -match "^-\s+(.+)$") {
            $templateNames += $matches[1].Trim()
            continue
        }

        if ($trimmed -and $line -notmatch "^\s+-") {
            break
        }
    }
}

if ($templateNames.Count -eq 0) {
    throw "No managed templates found in manifest."
}

Write-Host "Управляемых шаблонов: $($templateNames.Count)"

# ------------------------------------------------------------
# Read managed Trigger Actions from manifest
# ------------------------------------------------------------

$triggerActionNames = @()
$inTriggerActions = $false

foreach ($line in $manifestLines) {

    $trimmed = $line.Trim()

    if ($trimmed -eq "triggerActions:") {
        $inTriggerActions = $true
        continue
    }

    if ($inTriggerActions) {

        if ($trimmed -match "^-\s+(.+)$") {
            $triggerActionNames += $matches[1].Trim().Trim('"')
            continue
        }

        if ($trimmed -and $line -notmatch "^\s+-") {
            break
        }
    }
}

Write-Host "Управляемых Trigger Actions: $($triggerActionNames.Count)"

$triggerActionNames | ForEach-Object {
    Write-Host "  - $_"
}

# ------------------------------------------------------------
# Resolve Trigger Action IDs by name
# ------------------------------------------------------------

$triggerActions = @()

if ($triggerActionNames.Count -gt 0) {

    $allActions = Invoke-ZabbixApi `
        -Method "action.get" `
        -Params @{
            output = "extend"
        } `
        -Token $token `
        -Id 5

    foreach ($actionName in $triggerActionNames) {

        $found = @(
            $allActions |
                Where-Object {
                    $_.name -eq $actionName
                }
        )

        if ($found.Count -eq 0) {
            throw "Trigger Action not found in Zabbix: $actionName"
        }

        if ($found.Count -gt 1) {
            throw "Multiple Trigger Actions found with name: $actionName"
        }

        $triggerActions += $found[0]

        Write-Host "  $actionName -> $($found[0].actionid)"
    }
}

Write-Host "Найдено Trigger Actions: $($triggerActions.Count)"

$templateNames | ForEach-Object {
    Write-Host "  - $_"
}

# ------------------------------------------------------------
# Resolve template IDs by name
# ------------------------------------------------------------

$templateIds = @()

foreach ($templateName in $templateNames) {

    $found = Invoke-ZabbixApi `
        -Method "template.get" `
        -Params @{
            filter = @{
                name = @($templateName)
            }
            output = "extend"
        } `
        -Token $token `
        -Id 10

    if ($found.Count -eq 0) {
        throw "Template not found in Zabbix: $templateName"
    }

    if ($found.Count -gt 1) {
        throw "Multiple templates found with name: $templateName"
    }

    $templateIds += $found[0].templateid

    Write-Host "  $templateName -> $($found[0].templateid)"
}

# ------------------------------------------------------------
# Export managed templates
# ------------------------------------------------------------

Write-Host "Экспорт шаблонов: $($templateIds.Count)"

$templates = Invoke-ZabbixApi `
    -Method "template.get" `
    -Params @{
        templateids = $templateIds
        output = "extend"
        selectItems = "extend"
        selectTriggers = "extend"
    } `
    -Token $token `
    -Id 2

Write-Host "Получено шаблонов: $($templates.Count)"

# ------------------------------------------------------------
# Find used Value Maps
# ------------------------------------------------------------

$managedTemplateIdSet = @{}
foreach ($templateId in $templateIds) {
    $managedTemplateIdSet[[string]$templateId] = $true
}

$usedValueMapIds = @(
    $templates.items |
        Where-Object {
            $_.valuemapid -and
            $_.valuemapid -ne "0" -and
            $managedTemplateIdSet.ContainsKey([string]$_.hostid)
        } |
        ForEach-Object {
            $_.valuemapid
        } |
        Sort-Object -Unique
)

Write-Host "Используется Value Maps, принадлежащих управляемым шаблонам: $($usedValueMapIds.Count)"

if ($usedValueMapIds.Count -gt 0) {

    Write-Host "Value Map IDs:"
    Write-Host ($usedValueMapIds -join ", ")
}

# ------------------------------------------------------------
# Export used Value Maps only
# ------------------------------------------------------------

$valueMaps = @()

if ($usedValueMapIds.Count -gt 0) {

    $valueMaps = Invoke-ZabbixApi `
        -Method "valuemap.get" `
        -Params @{
            valuemapids = $usedValueMapIds
            output = "extend"
            selectMappings = "extend"
        } `
        -Token $token `
        -Id 3
}

Write-Host "Экспортировано Value Maps: $($valueMaps.Count)"

# ------------------------------------------------------------
# Export Graphs
# ------------------------------------------------------------

$graphs = Invoke-ZabbixApi `
    -Method "graph.get" `
    -Params @{
        templateids = $templateIds
        output = "extend"
        selectItems = "extend"
    } `
    -Token $token `
    -Id 4

Write-Host "Экспортировано Graphs: $($graphs.Count)"

# ------------------------------------------------------------
# Export Trigger Actions
# ------------------------------------------------------------

Write-Host "Экспортировано Trigger Actions: $($triggerActions.Count)"

# ------------------------------------------------------------
# Build release
# ------------------------------------------------------------

$result = @{
    format = "sprut-monitor-zabbix"
    version = "1"

    generatedAt = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    managed = @{
        templates = $templates
        valueMaps = $valueMaps
        graphs = $graphs
        triggerActions = $triggerActions
    }

    protected = @{
        hosts = $true
        hostMacros = $true
        interfaces = $true
        history = $true
        trends = $true
        events = $true
        problems = $true
    }
}

# ------------------------------------------------------------
# Save
# ------------------------------------------------------------

$directory = Split-Path $OutputPath -Parent

if (-not (Test-Path $directory)) {
    New-Item `
        -ItemType Directory `
        -Path $directory `
        -Force |
        Out-Null
}

$result |
    ConvertTo-Json -Depth 100 |
    Set-Content `
        -Path $OutputPath `
        -Encoding UTF8

Write-Host ""
Write-Host "Экспорт завершён:"
Write-Host $OutputPath

Get-Item $OutputPath |
    Select-Object FullName, Length