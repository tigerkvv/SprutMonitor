$ErrorActionPreference = "Stop"

$configPath = Join-Path $PSScriptRoot "config.json"
$config = Get-Content $configPath -Raw | ConvertFrom-Json

$repo = $config.repository
$currentVersion = [version]$config.currentVersion

$apiUrl = "https://api.github.com/repos/$repo/contents/releases"

$headers = @{
    "Accept" = "application/vnd.github+json"
    "User-Agent" = "SprutMonitor-Updater"
}

Write-Host "Sprut Monitor Updater"
Write-Host "---------------------"
Write-Host "Текущая версия: $currentVersion"
Write-Host "Проверка обновлений..."

try {
    $releases = Invoke-RestMethod `
        -Uri $apiUrl `
        -Headers $headers `
        -Method Get
}
catch {
    Write-Host ""
    Write-Host "Не удалось проверить обновления."
    Write-Host $_.Exception.Message
    exit 1
}

$versions = foreach ($item in $releases) {
    if ($item.type -eq "dir" -and $item.name -match '^\d+\.\d+\.\d+$') {
        try {
            [version]$item.name
        }
        catch {
        }
    }
}

if (-not $versions) {
    Write-Host ""
    Write-Host "В репозитории нет опубликованных версий."
    exit 1
}

$latestVersion = $versions | Sort-Object -Descending | Select-Object -First 1

Write-Host "Последняя версия: $latestVersion"

if ($latestVersion -gt $currentVersion) {
    Write-Host ""
    Write-Host "ДОСТУПНО ОБНОВЛЕНИЕ"
    Write-Host "Версия: $latestVersion"
    Write-Host ""
    Write-Host "Каталог релиза:"
    Write-Host "https://github.com/$repo/tree/main/releases/$latestVersion"

    exit 10
}

Write-Host ""
Write-Host "Обновлений нет."
exit 0
