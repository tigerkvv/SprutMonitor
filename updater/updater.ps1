$ErrorActionPreference = "Stop"

$configPath = Join-Path $PSScriptRoot "config.json"
$config = Get-Content $configPath -Raw | ConvertFrom-Json

$repo = $config.repository
$currentVersion = [version]$config.currentVersion

$headers = @{
    "Accept" = "application/vnd.github+json"
    "User-Agent" = "SprutMonitor-Updater"
}

$releasesApi = "https://api.github.com/repos/$repo/contents/releases"

Write-Host "Sprut Monitor Updater"
Write-Host "---------------------"
Write-Host "Текущая версия: $currentVersion"
Write-Host "Проверка обновлений..."

$releases = Invoke-RestMethod `
    -Uri $releasesApi `
    -Headers $headers `
    -Method Get

$versions = foreach ($item in $releases) {
    if ($item.type -eq "dir" -and $item.name -match '^\d+\.\d+\.\d+$') {
        [version]$item.name
    }
}

if (-not $versions) {
    Write-Host "Опубликованных версий нет."
    exit 1
}

$latestVersion = $versions | Sort-Object -Descending | Select-Object -First 1

Write-Host "Последняя версия: $latestVersion"

if ($latestVersion -le $currentVersion) {
    Write-Host ""
    Write-Host "Обновлений нет."
    exit 0
}

Write-Host ""
Write-Host "Доступно обновление: $latestVersion"
Write-Host ""

$answer = Read-Host "Установить обновление? (Y/N)"

if ($answer -notmatch '^(Y|y|Д|д)$') {
    Write-Host ""
    Write-Host "Обновление отклонено."
    exit 20
}

$releasePath = "releases/$latestVersion"
$releaseApi = "https://api.github.com/repos/$repo/contents/$releasePath"

$tempPath = Join-Path $env:TEMP "SprutMonitor-Updater\$latestVersion"

if (Test-Path $tempPath) {
    Remove-Item $tempPath -Recurse -Force
}

New-Item -ItemType Directory -Path $tempPath -Force | Out-Null

Write-Host ""
Write-Host "Скачивание релиза $latestVersion..."

$files = Invoke-RestMethod `
    -Uri $releaseApi `
    -Headers $headers `
    -Method Get

foreach ($file in $files) {
    if ($file.type -ne "file") {
        continue
    }

    $destination = Join-Path $tempPath $file.name

    Write-Host "  $($file.name)"

    Invoke-WebRequest `
        -Uri $file.download_url `
        -Headers @{ "User-Agent" = "SprutMonitor-Updater" } `
        -OutFile $destination
}

Write-Host ""
Write-Host "Релиз скачан:"
Write-Host $tempPath
Write-Host ""
Write-Host "Zabbix пока НЕ изменялся."

exit 10
