$ErrorActionPreference = "Stop"

$configPath = Join-Path $PSScriptRoot "config.json"
$config = Get-Content $configPath -Raw | ConvertFrom-Json

$repo = $config.repository
$currentVersion = [version]$config.currentVersion

$apiUrl = "https://api.github.com/repos/$repo/releases/latest"

$headers = @{
    "Accept" = "application/vnd.github+json"
    "User-Agent" = "SprutMonitor-Updater"
}

Write-Host "Sprut Monitor Updater"
Write-Host "---------------------"
Write-Host "Текущая версия: $currentVersion"
Write-Host "Проверка обновлений..."

try {
    $release = Invoke-RestMethod `
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

$latestVersionText = $release.tag_name.TrimStart("v")
$latestVersion = [version]$latestVersionText

Write-Host "Последняя версия: $latestVersion"

if ($latestVersion -gt $currentVersion) {
    Write-Host ""
    Write-Host "ДОСТУПНО ОБНОВЛЕНИЕ"
    Write-Host "Версия: $latestVersion"
    Write-Host ""

    if ($release.body) {
        Write-Host "Изменения:"
        Write-Host $release.body
    }

    exit 10
}

Write-Host ""
Write-Host "Обновлений нет."
exit 0
