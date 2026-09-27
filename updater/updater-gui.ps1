Add-Type -AssemblyName PresentationFramework

[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    Title="Sprut Monitor"
    Width="520"
    Height="360"
    WindowStartupLocation="CenterScreen"
    ResizeMode="NoResize">

    <Grid Margin="25">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <TextBlock
            Text="Sprut Monitor"
            FontSize="26"
            FontWeight="Bold"/>

        <StackPanel Grid.Row="1" Margin="0,25,0,20">

            <TextBlock
                Name="StatusText"
                Text="Нажмите «Проверить обновления»"
                FontSize="16"
                TextWrapping="Wrap"/>

            <TextBlock
                Name="DetailsText"
                Margin="0,20,0,0"
                FontSize="14"
                TextWrapping="Wrap"/>

        </StackPanel>

        <StackPanel
            Grid.Row="2"
            Orientation="Horizontal"
            HorizontalAlignment="Right">

            <Button
                Name="CheckButton"
                Content="Проверить обновления"
                Width="180"
                Height="35"
                Margin="0,0,10,0"/>

            <Button
                Name="AcceptButton"
                Content="Согласен"
                Width="100"
                Height="35"
                Visibility="Collapsed"
                Margin="0,0,10,0"/>

            <Button
                Name="RejectButton"
                Content="Отклонить"
                Width="100"
                Height="35"
                Visibility="Collapsed"/>

        </StackPanel>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$status = $window.FindName("StatusText")
$details = $window.FindName("DetailsText")

$check = $window.FindName("CheckButton")
$accept = $window.FindName("AcceptButton")
$reject = $window.FindName("RejectButton")

$check.Add_Click({

    $status.Text = "Проверка обновлений..."
    $details.Text = ""

    $configPath = Join-Path $PSScriptRoot "config.json"
    $config = Get-Content $configPath -Raw | ConvertFrom-Json

    $repo = $config.repository
    $current = [version]$config.currentVersion

    try {
        $headers = @{
            "Accept" = "application/vnd.github+json"
            "User-Agent" = "SprutMonitor-Updater"
        }

        $url = "https://api.github.com/repos/$repo/contents/releases"

        $items = Invoke-RestMethod `
            -Uri $url `
            -Headers $headers

        $versions = foreach ($item in $items) {
            if ($item.type -eq "dir" -and
                $item.name -match '^\d+\.\d+\.\d+$') {
                [version]$item.name
            }
        }

        $latest = $versions |
            Sort-Object -Descending |
            Select-Object -First 1

        if ($latest -le $current) {
            $status.Text = "Обновлений нет"
            $details.Text = "Установлена актуальная версия $current."
            return
        }

        $status.Text = "Доступно обновление"
        $details.Text = "Новая версия: $latest`nТекущая версия: $current"

        $check.Visibility = "Collapsed"
        $accept.Visibility = "Visible"
        $reject.Visibility = "Visible"

        $window.Tag = $latest

    }
    catch {
        $status.Text = "Ошибка проверки"
        $details.Text = $_.Exception.Message
    }
})

$reject.Add_Click({
    $status.Text = "Обновление отклонено"
    $details.Text = ""
    $accept.Visibility = "Collapsed"
    $reject.Visibility = "Collapsed"
    $check.Visibility = "Visible"
})

$accept.Add_Click({
    $version = $window.Tag

    $status.Text = "Обновление $version..."
    $details.Text = "Подготовка файлов..."

    # Пока только тест интерфейса.
    # Реальную установку подключим следующим этапом.

    Start-Sleep -Seconds 1

    $status.Text = "Готово к установке"
    $details.Text = "Следующим этапом подключим безопасное применение конфигурации Zabbix."

    $accept.Visibility = "Collapsed"
    $reject.Visibility = "Collapsed"
    $check.Visibility = "Visible"
})

$window.ShowDialog() | Out-Null
