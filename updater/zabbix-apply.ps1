param(
    [string]$ReleasePath = "R:\SprutMonitor\releases\1.1.0\zabbix-managed.json"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Sprut Monitor Zabbix Apply ==="
Write-Host "Режим: PREVIEW — изменения НЕ выполняются"
Write-Host ""

# ------------------------------------------------------------
# Load release
# ------------------------------------------------------------

if (-not (Test-Path $ReleasePath)) {
    throw "Release not found: $ReleasePath"
}

$release = Get-Content $ReleasePath -Raw | ConvertFrom-Json

Write-Host "Release format: $($release.format)"
Write-Host "Release version: 1.1.0"
Write-Host ""

# ------------------------------------------------------------
# Zabbix API
# ------------------------------------------------------------

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
Write-Host ""

# ------------------------------------------------------------
# Load PROD/DEV objects once
# ------------------------------------------------------------

Write-Host "Получение объектов Zabbix..."

$allTemplates = Invoke-ZabbixApi `
    -Method "template.get" `
    -Params @{
        output = "extend"
    } `
    -Token $token `
    -Id 10

Write-Host "Templates получено: $($allTemplates.Count)"

$allValueMaps = Invoke-ZabbixApi `
    -Method "valuemap.get" `
    -Params @{
        output = "extend"
    } `
    -Token $token `
    -Id 20

Write-Host "Value Maps получено: $($allValueMaps.Count)"

$allGraphs = Invoke-ZabbixApi `
    -Method "graph.get" `
    -Params @{
        output = "extend"
    } `
    -Token $token `
    -Id 30

Write-Host "Graphs получено: $($allGraphs.Count)"

$allActions = Invoke-ZabbixApi `
    -Method "action.get" `
    -Params @{
        output = "extend"
    } `
    -Token $token `
    -Id 40

Write-Host "Trigger Actions получено: $($allActions.Count)"

Write-Host ""

# ------------------------------------------------------------
# Templates
# ------------------------------------------------------------

Write-Host "=== Templates ==="

foreach ($template in $release.managed.templates) {

    $name = $template.name

    $found = @(
        $allTemplates |
            Where-Object {
                $_.name -eq $name
            }
    )

    if ($found.Count -eq 0) {

        Write-Host "[CREATE] $name"

    }
    elseif ($found.Count -eq 1) {

        Write-Host "[UPDATE] $name -> templateid $($found[0].templateid)"

    }
    else {

        Write-Host "[ERROR] Multiple templates with exact name: $name"

        $found |
            Select-Object templateid,name |
            Format-Table -AutoSize
    }
}

Write-Host ""

# ------------------------------------------------------------
# Value Maps
# ------------------------------------------------------------

Write-Host "=== Value Maps ==="

foreach ($valueMap in $release.managed.valueMaps) {

    $name = $valueMap.name

    $found = @(
        $allValueMaps |
            Where-Object {
                $_.name -eq $name
            }
    )

    if ($found.Count -eq 0) {

        Write-Host "[CREATE] $name"

    }
    elseif ($found.Count -eq 1) {

        Write-Host "[UPDATE] $name -> valuemapid $($found[0].valuemapid)"

    }
    else {

        Write-Host "[MULTIPLE] $name"

        $found |
            Select-Object valuemapid,name |
            Format-Table -AutoSize
    }
}

Write-Host ""

# ------------------------------------------------------------
# Graphs
# ------------------------------------------------------------

Write-Host "=== Graphs ==="

foreach ($graph in $release.managed.graphs) {

    $name = $graph.name

    $found = @(
        $allGraphs |
            Where-Object {
                $_.name -eq $name
            }
    )

    if ($found.Count -eq 0) {

        Write-Host "[CREATE] $name"

    }
    elseif ($found.Count -eq 1) {

        Write-Host "[UPDATE] $name -> graphid $($found[0].graphid)"

    }
    else {

        Write-Host "[MULTIPLE] $name"

        $found |
            Select-Object graphid,name,templateid |
            Format-Table -AutoSize
    }
}

Write-Host ""

# ------------------------------------------------------------
# Trigger Actions
# ------------------------------------------------------------

Write-Host "=== Trigger Actions ==="

foreach ($action in $release.managed.triggerActions) {

    $name = $action.name

    $found = @(
        $allActions |
            Where-Object {
                $_.name -eq $name
            }
    )

    if ($found.Count -eq 0) {

        Write-Host "[CREATE] $name"

    }
    elseif ($found.Count -eq 1) {

        Write-Host "[UPDATE] $name -> actionid $($found[0].actionid)"

    }
    else {

        Write-Host "[MULTIPLE] $name"

        $found |
            Select-Object actionid,name,status,eventsource |
            Format-Table -AutoSize
    }
}

Write-Host ""

# ------------------------------------------------------------
# Protected objects
# ------------------------------------------------------------

Write-Host "=== PROTECTED ==="

Write-Host "[SKIP] Hosts"
Write-Host "[SKIP] Host macros"
Write-Host "[SKIP] Host interfaces"
Write-Host "[SKIP] History"
Write-Host "[SKIP] Trends"
Write-Host "[SKIP] Events"
Write-Host "[SKIP] Problems"

Write-Host ""
Write-Host "=== PREVIEW FINISHED ==="
Write-Host "Изменения в Zabbix НЕ выполнялись."