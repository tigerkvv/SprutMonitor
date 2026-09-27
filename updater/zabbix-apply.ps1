param(
    [string]$ReleasePath = "R:\SprutMonitor\releases\1.1.0\zabbix-managed.json"
)

$ErrorActionPreference = "Stop"

Write-Host "=== Sprut Monitor Zabbix Apply ==="
Write-Host "Mode: PREVIEW - no changes will be made"
Write-Host ""

if (-not (Test-Path $ReleasePath)) {
    throw "Release not found: $ReleasePath"
}

$release = Get-Content $ReleasePath -Raw | ConvertFrom-Json

Write-Host "Release format: $($release.format)"
Write-Host "Release version: 1.1.0"
Write-Host ""

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

Write-Host "Authentication successful."
Write-Host ""

Write-Host "Loading Zabbix objects..."

$allTemplates = Invoke-ZabbixApi `
    -Method "template.get" `
    -Params @{
        output = "extend"
    } `
    -Token $token `
    -Id 10

Write-Host "Templates received: $($allTemplates.Count)"

$allValueMaps = Invoke-ZabbixApi `
    -Method "valuemap.get" `
    -Params @{
        output = "extend"
        selectMappings = "extend"
    } `
    -Token $token `
    -Id 20

Write-Host "Value Maps received: $($allValueMaps.Count)"

$allGraphs = Invoke-ZabbixApi `
    -Method "graph.get" `
    -Params @{
        output = "extend"
    } `
    -Token $token `
    -Id 30

Write-Host "Graphs received: $($allGraphs.Count)"

$allActions = Invoke-ZabbixApi `
    -Method "action.get" `
    -Params @{
        output = "extend"
    } `
    -Token $token `
    -Id 40

Write-Host "Trigger Actions received: $($allActions.Count)"
Write-Host ""

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

function Get-MappingSignature {
    param($map)

    $parts = @()

    foreach ($mapping in @($map.mappings)) {
        $parts += (
            [string]$mapping.value + "|" +
            [string]$mapping.newvalue + "|" +
            [string]$mapping.type
        )
    }

    return (($parts | Sort-Object) -join ";;")
}

Write-Host "=== Value Maps ==="

foreach ($valueMap in $release.managed.valueMaps) {

    $name = $valueMap.name
    $signature = Get-MappingSignature $valueMap

    $found = @(
        $allValueMaps |
            Where-Object {
                $_.name -eq $name -and
                (Get-MappingSignature $_) -eq $signature
            }
    )

    if ($found.Count -eq 0) {
        Write-Host "[CREATE] $name"
    }
    elseif ($found.Count -eq 1) {
        Write-Host "[UPDATE] $name -> valuemapid $($found[0].valuemapid)"
    }
    else {
        Write-Host "[AMBIGUOUS] $name - multiple matching Value Maps"
        $found |
            Select-Object valuemapid,name |
            Format-Table -AutoSize
    }
}

Write-Host ""

Write-Host "=== Graphs ==="

$graphCandidates = Invoke-ZabbixApi `
    -Method "graph.get" `
    -Params @{
        output = "extend"
        templated = $true
        inherited = $false
        selectItems = "extend"
        selectGraphItems = "extend"
    } `
    -Token $token `
    -Id 31

Write-Host "Managed Graph candidates: $($graphCandidates.Count)"

foreach ($graph in $release.managed.graphs) {

    $name = $graph.name

    $found = @(
        $graphCandidates |
            Where-Object {
                $_.name -eq $name
            }
    )

    if ($found.Count -eq 0) {
        Write-Host "[CREATE] $name"
        continue
    }

    if ($found.Count -eq 1) {
        Write-Host "[UPDATE] $name -> graphid $($found[0].graphid)"
        continue
    }

    $templateGraphs = @(
        $found |
            Where-Object {
                [string]$_.templateid -eq "0"
            }
    )

    if ($templateGraphs.Count -eq 1) {
        Write-Host "[UPDATE] $name -> graphid $($templateGraphs[0].graphid)"
        continue
    }

    if ($templateGraphs.Count -gt 1) {
        Write-Host "[AMBIGUOUS] $name - multiple template Graphs with templateid 0"
        $templateGraphs |
            Select-Object graphid,name,templateid |
            Format-Table -AutoSize
        continue
    }

    $releaseKeys = @()

    foreach ($item in @($graph.items)) {
        if ($item.key_) {
            $releaseKeys += [string]$item.key_
        }
    }

    $matched = @(
        $found | Where-Object {

            $candidateKeys = @()

            foreach ($item in @($_.items)) {
                if ($item.key_) {
                    $candidateKeys += [string]$item.key_
                }
            }

            $common = @(
                $releaseKeys | Where-Object {
                    $candidateKeys -contains $_
                }
            )

            $common.Count -gt 0
        }
    )

    if ($matched.Count -eq 1) {
        Write-Host "[UPDATE] $name -> graphid $($matched[0].graphid)"
    }
    elseif ($matched.Count -eq 0) {
        Write-Host "[AMBIGUOUS] $name - could not determine Graph uniquely"
        $found |
            Select-Object graphid,name,templateid |
            Format-Table -AutoSize
    }
    else {
        Write-Host "[AMBIGUOUS] $name - multiple Graphs matched item key"
        $matched |
            Select-Object graphid,name,templateid |
            Format-Table -AutoSize
    }
}

Write-Host ""

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
Write-Host "Zabbix changes were NOT executed."
