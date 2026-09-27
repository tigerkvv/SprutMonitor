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

$login = [Environment]::GetEnvironmentVariable("ZABBIX_USERNAME", "Machine")
$plainPassword = [Environment]::GetEnvironmentVariable("ZABBIX_PASSWORD", "Machine")

if ([string]::IsNullOrWhiteSpace($login)) {
    throw "System environment variable ZABBIX_USERNAME is not set."
}

if ([string]::IsNullOrWhiteSpace($plainPassword)) {
    throw "System environment variable ZABBIX_PASSWORD is not set."
}

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
    $templateId = [string]$valueMap.hostid

    if ([string]::IsNullOrWhiteSpace($templateId)) {
        Write-Host "[ERROR] $name - release Value Map has no template binding"
        continue
    }

    $templateName = ($release.managed.templates |
        Where-Object { [string]$_.templateid -eq $templateId } |
        Select-Object -First 1).name

    if ([string]::IsNullOrWhiteSpace($templateName)) {
        Write-Host "[ERROR] $name - source template $templateId is not in managed templates"
        continue
    }

    $targetTemplate = @(
        $allTemplates |
            Where-Object { $_.name -eq $templateName }
    )

    if ($targetTemplate.Count -ne 1) {
        Write-Host "[ERROR] $name - cannot resolve target template '$templateName'"
        continue
    }

    $targetTemplateId = [string]$targetTemplate[0].templateid

    $found = @(
        $allValueMaps |
            Where-Object {
                $_.name -eq $name -and
                [string]$_.hostid -eq $targetTemplateId -and
                (Get-MappingSignature $_) -eq $signature
            }
    )

    if ($found.Count -eq 0) {
        Write-Host "[CREATE] $name -> template '$templateName'"
    }
    elseif ($found.Count -eq 1) {
        Write-Host "[UPDATE] $name -> valuemapid $($found[0].valuemapid), template '$templateName'"
    }
    else {
        Write-Host "[AMBIGUOUS] $name - multiple Value Maps bound to template '$templateName'"
        $found |
            Select-Object valuemapid,name,hostid |
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

    # Graphs are always matched through the template bound to their items.
    $releaseTemplateIds = @(
        @($graph.items) |
            Where-Object { $_.hostid } |
            ForEach-Object { [string]$_.hostid } |
            Sort-Object -Unique
    )

    if ($releaseTemplateIds.Count -eq 0) {
        Write-Host "[ERROR] $name - release Graph has no template-bound items"
        continue
    }

    $releaseTemplateNames = @(
        foreach ($templateId in $releaseTemplateIds) {
            $t = $release.managed.templates |
                Where-Object { [string]$_.templateid -eq $templateId } |
                Select-Object -First 1
            if ($t) { $t.name }
        }
    )

    if ($releaseTemplateNames.Count -eq 0) {
        Write-Host "[ERROR] $name - source template is not in managed templates"
        continue
    }

    $targetTemplateIds = @(
        foreach ($templateName in $releaseTemplateNames) {
            $t = @($allTemplates | Where-Object { $_.name -eq $templateName })
            if ($t.Count -eq 1) { [string]$t[0].templateid }
        }
    ) | Sort-Object -Unique

    if ($targetTemplateIds.Count -eq 0) {
        Write-Host "[ERROR] $name - cannot resolve target template"
        continue
    }

    $releaseKeys = @(
        @($graph.items) |
            Where-Object { $_.key_ } |
            ForEach-Object { [string]$_.key_ } |
            Sort-Object -Unique
    )

    $found = @(
        $graphCandidates |
            Where-Object {
                if ($_.name -ne $name) { return $false }

                $candidateTemplateIds = @(
                    @($_.items) |
                        Where-Object { $_.hostid } |
                        ForEach-Object { [string]$_.hostid } |
                        Sort-Object -Unique
                )

                $templateMatch = @(
                    $candidateTemplateIds |
                        Where-Object { $targetTemplateIds -contains $_ }
                )

                if ($templateMatch.Count -eq 0) { return $false }

                if ($releaseKeys.Count -gt 0) {
                    $candidateKeys = @(
                        @($_.items) |
                            Where-Object { $_.key_ } |
                            ForEach-Object { [string]$_.key_ } |
                            Sort-Object -Unique
                    )

                    $common = @(
                        $releaseKeys |
                            Where-Object { $candidateKeys -contains $_ }
                    )

                    return ($common.Count -gt 0)
                }

                return $true
            }
    )

    if ($found.Count -eq 0) {
        Write-Host "[CREATE] $name -> template '$($releaseTemplateNames -join ', ')'"
    }
    elseif ($found.Count -eq 1) {
        Write-Host "[UPDATE] $name -> graphid $($found[0].graphid), template '$($releaseTemplateNames -join ', ')'"
    }
    else {
        Write-Host "[AMBIGUOUS] $name - multiple Graphs bound to template '$($releaseTemplateNames -join ', ')'"
        $found |
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
