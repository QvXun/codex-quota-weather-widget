param(
    [switch]$Test,
    [switch]$SmokeTest,
    [switch]$TestWeather,
    [switch]$DemoWeather
)

$ErrorActionPreference = 'Stop'

function Get-CodexHome {
    if ($env:CODEX_HOME) { return $env:CODEX_HOME }
    return (Join-Path $env:USERPROFILE '.codex')
}

function Get-LatestCodexRateLimit {
    $sessionsRoot = Join-Path (Get-CodexHome) 'sessions'
    if (-not (Test-Path -LiteralPath $sessionsRoot)) {
        throw '未找到 Codex 会话目录。请先在 Codex 中完成一次对话。'
    }

    $files = @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -File -Filter '*.jsonl' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 12)
    if ($files.Count -eq 0) {
        throw '还没有可读取的 Codex 会话。请先发送一条消息。'
    }

    $best = $null
    foreach ($file in $files) {
        $stream = $null
        $reader = $null
        try {
            $stream = [System.IO.File]::Open(
                $file.FullName,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::Read,
                [System.IO.FileShare]::ReadWrite
            )

            # 额度事件通常位于文件末尾。限制读取量，避免大型会话拖慢悬浮窗。
            $readBytes = [Math]::Min($stream.Length, 2MB)
            if ($stream.Length -gt $readBytes) {
                [void]$stream.Seek(-$readBytes, [System.IO.SeekOrigin]::End)
            }
            $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
            if ($stream.Position -gt 0) { [void]$reader.ReadLine() }

            while (($line = $reader.ReadLine()) -ne $null) {
                # 只接受 Codex 的额度元数据事件。普通对话行不会进入 JSON 解析。
                if ($line.IndexOf('"type":"event_msg"', [StringComparison]::Ordinal) -lt 0 -or
                    $line.IndexOf('"type":"token_count"', [StringComparison]::Ordinal) -lt 0 -or
                    $line.IndexOf('"rate_limits":', [StringComparison]::Ordinal) -lt 0) { continue }
                try {
                    $row = $line | ConvertFrom-Json
                    $limits = $null
                    if ($row.type -eq 'event_msg' -and $row.payload.type -eq 'token_count' -and $row.payload.rate_limits) {
                        $limits = $row.payload.rate_limits
                    }
                    if (-not $limits -or -not $limits.primary) { continue }

                    $stamp = [DateTime]::MinValue
                    if ($row.timestamp) {
                        try { $stamp = [DateTimeOffset]::Parse([string]$row.timestamp).UtcDateTime } catch {}
                    }
                    if ($stamp -eq [DateTime]::MinValue) { $stamp = $file.LastWriteTimeUtc }

                    if (-not $best -or $stamp -gt $best.TimestampUtc) {
                        $best = [pscustomobject]@{
                            TimestampUtc = $stamp
                            Limits       = $limits
                            SourceFile   = $file.FullName
                        }
                    }
                } catch {
                    # 会话仍在写入时，末行可能暂时不完整；下次刷新再读。
                }
            }
        } finally {
            if ($reader) { $reader.Dispose() }
            if ($stream) { $stream.Dispose() }
        }
    }

    if (-not $best) {
        throw '暂未读到额度状态。请在 Codex 中发送一条消息后再刷新。'
    }
    return $best
}

function Get-WidgetConfig {
    $configPath = Join-Path $PSScriptRoot 'widget-config.json'
    $defaults = [ordered]@{
        weather_enabled = $false
        city            = '未配置'
        latitude        = 0
        longitude       = 0
        refresh_minutes = 15
        weather_cache_max_minutes = 45
    }

    if (-not (Test-Path -LiteralPath $configPath)) {
        $defaults | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
        return [pscustomobject]$defaults
    }

    try {
        $loaded = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json
        foreach ($key in $defaults.Keys) {
            if ($null -eq $loaded.$key) { $loaded | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] }
        }
        return $loaded
    } catch {
        return [pscustomobject]$defaults
    }
}

function Get-SeasonInfo([datetime]$date, [double]$latitude) {
    $month = $date.Month
    if ($latitude -lt 0) { $month = (($month + 5) % 12) + 1 }
    if ($month -in 3,4,5) {
        return [pscustomobject]@{ Key='spring'; Name='春日'; Icon='✿'; Background='#F21A2421'; Border='#6EC69A'; Primary='#69D9A2'; Secondary='#F09AB3'; Badge='#274B3C'; Rain='#8BD7D8' }
    }
    if ($month -in 6,7,8) {
        return [pscustomobject]@{ Key='summer'; Name='盛夏'; Icon='☀'; Background='#F2162229'; Border='#4CBFC9'; Primary='#50E3C2'; Secondary='#63AFFF'; Badge='#214851'; Rain='#74D9FF' }
    }
    if ($month -in 9,10,11) {
        return [pscustomobject]@{ Key='autumn'; Name='金秋'; Icon='◆'; Background='#F2251D18'; Border='#B97842'; Primary='#F0A653'; Secondary='#D97745'; Badge='#513623'; Rain='#88C9E8' }
    }
    return [pscustomobject]@{ Key='winter'; Name='冬境'; Icon='❄'; Background='#F216202D'; Border='#789CBF'; Primary='#B5D8F1'; Secondary='#7899E8'; Badge='#293C55'; Rain='#A7D8FF' }
}

function Get-WeatherDescription([int]$code) {
    switch ($code) {
        0 { '晴朗' }
        1 { '大部晴朗' }
        2 { '局部多云' }
        3 { '阴天' }
        { $_ -in 45,48 } { '有雾' }
        { $_ -in 51,53,55 } { '毛毛雨' }
        { $_ -in 56,57,66,67 } { '冻雨' }
        { $_ -in 61,63,65 } { '降雨' }
        { $_ -in 71,73,75,77 } { '降雪' }
        { $_ -in 80,81,82 } { '阵雨' }
        { $_ -in 85,86 } { '阵雪' }
        95 { '雷暴' }
        { $_ -in 96,99 } { '雷暴伴冰雹' }
        default { '天气变化中' }
    }
}

function Get-WeatherEffectMode([int]$code, [double]$rain, [double]$showers, [double]$snowfall) {
    if ($snowfall -gt 0 -or $code -in @(71,73,75,77,85,86)) { return 'snow' }
    if ($code -in @(95,96,99)) { return 'thunder' }
    if (($rain + $showers) -gt 0 -or $code -in @(51,53,55,56,57,61,63,65,66,67,80,81,82)) { return 'rain' }
    if ($code -in @(45,48)) { return 'fog' }
    return 'none'
}

function Test-WeatherCacheExpired($weather, [double]$maxMinutes) {
    if (-not [bool]$weather.from_cache) { return $false }
    try {
        return (([DateTimeOffset]::Now - [DateTimeOffset]::Parse([string]$weather.fetched_at)).TotalMinutes -gt $maxMinutes)
    } catch { return $true }
}

function Get-WeatherData($config) {
    $cachePath = Join-Path $PSScriptRoot 'weather-cache.json'
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $lat = ([double]$config.latitude).ToString('0.####', $culture)
    $lon = ([double]$config.longitude).ToString('0.####', $culture)
    $url = "https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code,is_day,precipitation,rain,showers,snowfall,cloud_cover&timezone=auto"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $response = Invoke-RestMethod -Uri $url -Method Get -TimeoutSec 8
        if (-not $response.current) { throw '天气服务没有返回当前天气。' }
        $current = $response.current
        $code = [int]$current.weather_code
        $mode = Get-WeatherEffectMode $code ([double]$current.rain) ([double]$current.showers) ([double]$current.snowfall)
        $precip = [Math]::Max([double]$current.precipitation, ([double]$current.rain + [double]$current.showers))
        $data = [ordered]@{
            fetched_at   = [DateTimeOffset]::Now.ToString('o')
            city         = [string]$config.city
            temperature  = [double]$current.temperature_2m
            weather_code = $code
            description  = Get-WeatherDescription $code
            mode         = $mode
            intensity    = [Math]::Min(3, [Math]::Max(1, [Math]::Ceiling($precip + 0.2)))
            is_day       = [int]$current.is_day
            from_cache   = $false
        }
        $data | ConvertTo-Json | Set-Content -LiteralPath $cachePath -Encoding UTF8
        return [pscustomobject]$data
    } catch {
        if (Test-Path -LiteralPath $cachePath) {
            try {
                $cached = Get-Content -Raw -Encoding UTF8 -LiteralPath $cachePath | ConvertFrom-Json
                $cached.city = [string]$config.city
                $cached.from_cache = $true
                return $cached
            } catch {}
        }
        throw
    }
}

if ($Test) {
    $result = Get-LatestCodexRateLimit
    [pscustomobject]@{
        timestamp_utc = $result.TimestampUtc.ToString('o')
        plan          = $result.Limits.plan_type
        five_hour     = $result.Limits.primary
        seven_day     = $result.Limits.secondary
        credits       = $result.Limits.credits
    } | ConvertTo-Json -Depth 8
    exit 0
}

if ($TestWeather) {
    Get-WeatherData (Get-WidgetConfig) | ConvertTo-Json -Depth 6
    exit 0
}

$createdNew = $false
$mutexName = if ($SmokeTest) { 'Local\CodexQuotaFloatingWidgetSmokeTest' } elseif ($DemoWeather) { 'Local\CodexQuotaFloatingWidgetDemo' } else { 'Local\CodexQuotaFloatingWidget' }
$mutex = New-Object Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) { exit 0 }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Codex 额度" Width="330" Height="246"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ResizeMode="NoResize" ShowInTaskbar="True">
  <Border Name="RootBorder" CornerRadius="18" Background="#F2162229" BorderBrush="#4CBFC9" BorderThickness="1" Padding="18">
    <Border.Effect>
      <DropShadowEffect BlurRadius="24" ShadowDepth="5" Opacity="0.42" Color="#000000"/>
    </Border.Effect>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="34"/>
        <RowDefinition Height="58"/>
        <RowDefinition Height="58"/>
        <RowDefinition Height="54"/>
      </Grid.RowDefinitions>

      <Grid Grid.Row="0" Name="DragArea" Background="Transparent">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="34"/>
          <ColumnDefinition Width="30"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Top">
          <Ellipse Name="StatusDot" Width="9" Height="9" Fill="#50E3A4" Margin="0,6,9,0"/>
          <TextBlock Name="TitleText" Text="Codex 额度" Foreground="#F4F7FB" FontSize="16" FontWeight="SemiBold" FontFamily="Microsoft YaHei UI"/>
          <TextBlock Name="PlanText" Text="" Foreground="#8993A5" FontSize="11" Margin="9,4,0,0" FontFamily="Microsoft YaHei UI"/>
          <Border Name="DemoBadge" Visibility="Collapsed" CornerRadius="6" Background="#B23A4B" Padding="6,1" Margin="8,1,0,0">
            <TextBlock Text="DEMO" Foreground="#FFFFFF" FontSize="9" FontWeight="Bold" FontFamily="Segoe UI"/>
          </Border>
        </StackPanel>
        <Button Grid.Column="1" Name="RefreshButton" Content="↻" FontSize="18" Foreground="#AAB3C2" Background="Transparent" BorderThickness="0" Cursor="Hand" ToolTip="立即刷新"/>
        <Button Grid.Column="2" Name="CloseButton" Content="×" FontSize="19" Foreground="#AAB3C2" Background="Transparent" BorderThickness="0" Cursor="Hand" ToolTip="关闭"/>
      </Grid>

      <Grid Grid.Row="1" Margin="0,3,0,0">
        <Grid.RowDefinitions><RowDefinition Height="25"/><RowDefinition Height="10"/><RowDefinition Height="20"/></Grid.RowDefinitions>
        <Grid>
          <TextBlock Text="5 小时额度" Foreground="#CCD3DE" FontSize="13" FontFamily="Microsoft YaHei UI"/>
          <TextBlock Name="PrimaryText" Text="--" HorizontalAlignment="Right" Foreground="#F4F7FB" FontSize="13" FontWeight="SemiBold" FontFamily="Microsoft YaHei UI"/>
        </Grid>
        <Border Grid.Row="1" Name="PrimaryTrack" CornerRadius="5" Height="8" Background="#303642" ClipToBounds="True">
          <Border Name="PrimaryFill" CornerRadius="5" Background="#50E3A4" HorizontalAlignment="Left" ToolTip="左侧彩色部分表示剩余额度"/>
        </Border>
        <TextBlock Grid.Row="2" Name="PrimaryReset" Text="等待数据…" Foreground="#7F899A" FontSize="10.5" VerticalAlignment="Bottom" FontFamily="Microsoft YaHei UI"/>
      </Grid>

      <Grid Grid.Row="2" Margin="0,5,0,0">
        <Grid.RowDefinitions><RowDefinition Height="25"/><RowDefinition Height="10"/><RowDefinition Height="20"/></Grid.RowDefinitions>
        <Grid>
          <TextBlock Text="7 天额度" Foreground="#CCD3DE" FontSize="13" FontFamily="Microsoft YaHei UI"/>
          <TextBlock Name="SecondaryText" Text="--" HorizontalAlignment="Right" Foreground="#F4F7FB" FontSize="13" FontWeight="SemiBold" FontFamily="Microsoft YaHei UI"/>
        </Grid>
        <Border Grid.Row="1" Name="SecondaryTrack" CornerRadius="5" Height="8" Background="#303642" ClipToBounds="True">
          <Border Name="SecondaryFill" CornerRadius="5" Background="#6AA8FF" HorizontalAlignment="Left" ToolTip="左侧彩色部分表示剩余额度"/>
        </Border>
        <TextBlock Grid.Row="2" Name="SecondaryReset" Text="等待数据…" Foreground="#7F899A" FontSize="10.5" VerticalAlignment="Bottom" FontFamily="Microsoft YaHei UI"/>
      </Grid>

      <Grid Grid.Row="3" Margin="0,6,0,0">
        <Grid.RowDefinitions><RowDefinition Height="25"/><RowDefinition Height="22"/></Grid.RowDefinitions>
        <Grid VerticalAlignment="Center">
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Border Grid.Column="0" Name="SeasonBadge" CornerRadius="7" Background="#214851" Padding="7,2" Margin="0,0,8,0">
            <TextBlock Name="SeasonText" Text="☀ 盛夏" Foreground="#D9F6F5" FontSize="10.5" FontWeight="SemiBold" FontFamily="Microsoft YaHei UI"/>
          </Border>
          <TextBlock Grid.Column="1" Name="WeatherText" Text="正在获取天气…" Foreground="#B9C4D2" FontSize="10.5" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI"/>
        </Grid>
        <TextBlock Grid.Row="1" Name="StatusText" Text="正在读取本机 Codex 状态…" Foreground="#697487" FontSize="10.5" TextTrimming="CharacterEllipsis" VerticalAlignment="Center" FontFamily="Microsoft YaHei UI"/>
      </Grid>

      <Canvas Grid.RowSpan="4" Name="WeatherCanvas" Margin="-14" IsHitTestVisible="False" Panel.ZIndex="50" ClipToBounds="False"/>
      <Rectangle Grid.RowSpan="4" Name="LightningFlash" Margin="-14" RadiusX="16" RadiusY="16" Fill="#EAF3FF" Opacity="0" IsHitTestVisible="False" Panel.ZIndex="60"/>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$names = @('RootBorder','StatusDot','DragArea','TitleText','PlanText','DemoBadge','RefreshButton','CloseButton','PrimaryText','PrimaryTrack','PrimaryFill','PrimaryReset','SecondaryText','SecondaryTrack','SecondaryFill','SecondaryReset','SeasonBadge','SeasonText','WeatherText','StatusText','WeatherCanvas','LightningFlash')
foreach ($name in $names) { Set-Variable -Name $name -Value $window.FindName($name) }

$script:primaryUsed = 0.0
$script:secondaryUsed = 0.0
$script:busy = $false
$statePath = Join-Path $PSScriptRoot 'widget-state.json'
$script:config = Get-WidgetConfig
$script:season = Get-SeasonInfo ([datetime]::Now) ([double]$script:config.latitude)
$script:primaryAccent = $script:season.Primary
$script:secondaryAccent = $script:season.Secondary
$script:weatherMode = 'none'
$script:weatherIntensity = 1
$script:particles = New-Object System.Collections.ArrayList
$script:random = New-Object System.Random
$script:brushConverter = New-Object System.Windows.Media.BrushConverter
$script:rainBrush = $script:brushConverter.ConvertFromString($script:season.Rain)
$script:demoIndex = -1
$demoSeasons = @(
    [pscustomobject]@{ Key='spring'; Name='春季'; Modes=@('none','rain','fog','thunder') },
    [pscustomobject]@{ Key='summer'; Name='夏季'; Modes=@('none','rain','fog','thunder') },
    [pscustomobject]@{ Key='autumn'; Name='秋季'; Modes=@('none','rain','fog') },
    [pscustomobject]@{ Key='winter'; Name='冬季'; Modes=@('none','fog','snow') }
)
$demoWeatherOptions = @{
    none    = [pscustomobject]@{ Name='晴朗'; Intensity=1 }
    rain    = [pscustomobject]@{ Name='降雨'; Intensity=2 }
    fog     = [pscustomobject]@{ Name='有雾'; Intensity=1 }
    snow    = [pscustomobject]@{ Name='降雪'; Intensity=2 }
    thunder = [pscustomobject]@{ Name='雷暴'; Intensity=2 }
}
$script:demoScenes = @(
    foreach ($seasonOption in $demoSeasons) {
        foreach ($mode in $seasonOption.Modes) {
            $weatherOption = $demoWeatherOptions[$mode]
            [pscustomobject]@{
                Season=$seasonOption.Key
                Mode=$mode
                Intensity=$weatherOption.Intensity
                SeasonName=$seasonOption.Name
                WeatherName=$weatherOption.Name
                Label="$($seasonOption.Name) × $($weatherOption.Name)"
            }
        }
    }
)

function ConvertTo-Brush([string]$color) {
    return $script:brushConverter.ConvertFromString($color)
}

function Apply-SeasonTheme([string]$forcedSeason = '') {
    $seasonDate = switch ($forcedSeason) {
        'spring' { [datetime]'2026-04-15' }
        'summer' { [datetime]'2026-07-15' }
        'autumn' { [datetime]'2026-10-15' }
        'winter' { [datetime]'2026-01-15' }
        default { [datetime]::Now }
    }
    $script:season = Get-SeasonInfo $seasonDate ([double]$script:config.latitude)
    $script:primaryAccent = $script:season.Primary
    $script:secondaryAccent = $script:season.Secondary
    $script:rainBrush = ConvertTo-Brush $script:season.Rain
    $RootBorder.Background = ConvertTo-Brush $script:season.Background
    $RootBorder.BorderBrush = ConvertTo-Brush $script:season.Border
    $StatusDot.Fill = ConvertTo-Brush $script:season.Primary
    $SeasonBadge.Background = ConvertTo-Brush $script:season.Badge
    $SeasonText.Text = "$($script:season.Icon) $($script:season.Name)"
    $PrimaryFill.Background = ConvertTo-Brush (Get-UsageColor $script:primaryUsed $script:primaryAccent)
    $SecondaryFill.Background = ConvertTo-Brush (Get-UsageColor $script:secondaryUsed $script:secondaryAccent)
}

function Get-ResetDescription($epochSeconds) {
    if (-not $epochSeconds) { return '重置时间未知' }
    try {
        $time = [DateTimeOffset]::FromUnixTimeSeconds([long]$epochSeconds).ToLocalTime()
        $span = $time - [DateTimeOffset]::Now
        if ($span.TotalSeconds -le 0) { return '额度即将刷新' }
        if ($span.TotalDays -ge 1) {
            return ('{0:MM-dd HH:mm} 重置（约 {1} 天）' -f $time, [Math]::Ceiling($span.TotalDays))
        }
        if ($span.TotalHours -ge 1) {
            return ('{0:HH:mm} 重置（约 {1} 小时）' -f $time, [Math]::Ceiling($span.TotalHours))
        }
        return ('{0:HH:mm} 重置（约 {1} 分钟）' -f $time, [Math]::Max(1, [Math]::Ceiling($span.TotalMinutes)))
    } catch { return '重置时间未知' }
}

function Get-RemainingBarWidth([double]$trackWidth, [double]$usedPercent) {
    $remaining = 100 - [Math]::Min(100, [Math]::Max(0, $usedPercent))
    return [Math]::Max(0, $trackWidth * $remaining / 100)
}

function Set-BarWidth {
    $PrimaryFill.Width = Get-RemainingBarWidth $PrimaryTrack.ActualWidth $script:primaryUsed
    $SecondaryFill.Width = Get-RemainingBarWidth $SecondaryTrack.ActualWidth $script:secondaryUsed
}

function Get-UsageColor([double]$used, [string]$normal) {
    if ($used -ge 90) { return '#FF657A' }
    if ($used -ge 70) { return '#FFB454' }
    return $normal
}

function Update-Quota {
    if ($script:busy) { return }
    $script:busy = $true
    try {
        $result = Get-LatestCodexRateLimit
        $limits = $result.Limits
        $script:primaryUsed = [double]$limits.primary.used_percent
        if ($limits.secondary) { $script:secondaryUsed = [double]$limits.secondary.used_percent } else { $script:secondaryUsed = 0 }

        $PrimaryText.Text = ('已用 {0:0.#}% · 剩余 {1:0.#}%' -f $script:primaryUsed, [Math]::Max(0, 100 - $script:primaryUsed))
        $SecondaryText.Text = if ($limits.secondary) { ('已用 {0:0.#}% · 剩余 {1:0.#}%' -f $script:secondaryUsed, [Math]::Max(0, 100 - $script:secondaryUsed)) } else { '当前方案未返回' }
        $PrimaryReset.Text = Get-ResetDescription $limits.primary.resets_at
        $SecondaryReset.Text = if ($limits.secondary) { Get-ResetDescription $limits.secondary.resets_at } else { '无第二额度窗口' }
        $PlanText.Text = if ($limits.plan_type) { ([string]$limits.plan_type).ToUpperInvariant() } else { '' }
        $PrimaryFill.Background = ConvertTo-Brush (Get-UsageColor $script:primaryUsed $script:primaryAccent)
        $SecondaryFill.Background = ConvertTo-Brush (Get-UsageColor $script:secondaryUsed $script:secondaryAccent)
        Set-BarWidth

        $age = [DateTime]::UtcNow - $result.TimestampUtc
        if ($age.TotalMinutes -lt 2) { $freshness = '刚刚更新' }
        elseif ($age.TotalHours -lt 1) { $freshness = ('{0} 分钟前更新' -f [Math]::Floor($age.TotalMinutes)) }
        else { $freshness = ('{0} 小时前更新' -f [Math]::Floor($age.TotalHours)) }
        $StatusText.Foreground = '#697487'
        $StatusText.Text = "$freshness · 自动刷新（数据随 Codex 对话更新）"
    } catch {
        $StatusText.Text = $_.Exception.Message
        $StatusText.Foreground = '#FF8A9B'
    } finally {
        $script:busy = $false
    }
}

function Update-Weather {
    Apply-SeasonTheme
    $previousMode = $script:weatherMode
    if (-not [bool]$script:config.weather_enabled) {
        $script:weatherMode = 'none'
        if ($previousMode -ne 'none') { Clear-WeatherEffects }
        $WeatherText.Text = "$($script:config.city) · 天气功能已关闭"
        return
    }

    try {
        $weather = Get-WeatherData $script:config
        $mode = [string]$weather.mode
        $cacheAgeMinutes = 0.0
        try { $cacheAgeMinutes = ([DateTimeOffset]::Now - [DateTimeOffset]::Parse([string]$weather.fetched_at)).TotalMinutes } catch { $cacheAgeMinutes = 99999 }
        $maxCacheMinutes = [Math]::Max(5, [double]$script:config.weather_cache_max_minutes)

        # 正式模式只服从实时天气。缓存过期后立即停止雨雪雾雷效果。
        if (Test-WeatherCacheExpired $weather $maxCacheMinutes) {
            $script:weatherMode = 'none'
            if ($previousMode -ne 'none') { Clear-WeatherEffects }
            $LightningFlash.Opacity = 0
            $WeatherText.Text = ('{0} · 天气数据已过期 · {1:0.#}°C' -f $weather.city, [double]$weather.temperature)
            $WeatherText.ToolTip = "缓存已超过 $([Math]::Round($maxCacheMinutes)) 分钟；雨雪效果已暂停，点击刷新可重试"
            return
        }

        if ($mode -ne $previousMode) { Clear-WeatherEffects }
        $script:weatherMode = $mode
        $script:weatherIntensity = [int]$weather.intensity
        $cacheLabel = if ([bool]$weather.from_cache) { " · 缓存 $([Math]::Max(1,[Math]::Round($cacheAgeMinutes))) 分钟" } else { ' · 实时' }
        $WeatherText.Text = ('{0} · {1} · {2:0.#}°C{3}' -f $weather.city, $weather.description, [double]$weather.temperature, $cacheLabel)
        $WeatherText.ToolTip = "天气数据：Open-Meteo；每 $($script:config.refresh_minutes) 分钟更新；粒子效果：$mode"
    } catch {
        $script:weatherMode = 'none'
        if ($previousMode -ne 'none') { Clear-WeatherEffects }
        $LightningFlash.Opacity = 0
        $WeatherText.Text = "$($script:config.city) · 天气暂不可用"
        $WeatherText.ToolTip = $_.Exception.Message
    }
}

function Add-Splash([double]$x, [double]$y) {
    $ring = New-Object System.Windows.Shapes.Ellipse
    $ring.Stroke = $script:rainBrush
    $ring.StrokeThickness = 1.2
    $ring.Width = 2
    $ring.Height = 1
    $ring.Opacity = 0.85
    [System.Windows.Controls.Canvas]::SetLeft($ring, $x - 1)
    [System.Windows.Controls.Canvas]::SetTop($ring, $y)
    [void]$WeatherCanvas.Children.Add($ring)
    [void]$script:particles.Add([pscustomobject]@{ Kind='splash'; Shape=$ring; X=$x; Y=$y; Age=0; VX=0.0; VY=0.0 })

    foreach ($direction in @(-1,1)) {
        $dot = New-Object System.Windows.Shapes.Ellipse
        $dot.Fill = $script:rainBrush
        $dot.Width = 2.4
        $dot.Height = 2.4
        $dot.Opacity = 0.9
        [System.Windows.Controls.Canvas]::SetLeft($dot, $x)
        [System.Windows.Controls.Canvas]::SetTop($dot, $y)
        [void]$WeatherCanvas.Children.Add($dot)
        $vx = $direction * (1.1 + $script:random.NextDouble() * 1.4)
        $vy = -(1.8 + $script:random.NextDouble() * 1.8)
        [void]$script:particles.Add([pscustomobject]@{ Kind='splashdrop'; Shape=$dot; X=$x; Y=$y; Age=0; VX=$vx; VY=$vy })
    }
}

function Add-RainDrop {
    $width = [Math]::Max(280, $WeatherCanvas.ActualWidth)
    $x = 8 + $script:random.NextDouble() * ($width - 16)
    $length = 13 + $script:random.NextDouble() * 11
    $drop = New-Object System.Windows.Controls.Grid
    $drop.Width = 5
    $drop.Height = $length
    $drop.Opacity = 0.52 + $script:random.NextDouble() * 0.3

    # 半透明渐变尾迹 + 圆润水滴头，比单条斜线更接近高速雨滴。
    $rgb = ([string]$script:season.Rain).TrimStart('#')
    $gradient = New-Object System.Windows.Media.LinearGradientBrush
    $gradient.StartPoint = [System.Windows.Point]::Parse('0.5,0')
    $gradient.EndPoint = [System.Windows.Point]::Parse('0.5,1')
    foreach ($entry in @(@("#00$rgb",0.0), @("#3D$rgb",0.55), @("#B8$rgb",1.0))) {
        $stop = New-Object System.Windows.Media.GradientStop
        $stop.Color = [System.Windows.Media.ColorConverter]::ConvertFromString([string]$entry[0])
        $stop.Offset = [double]$entry[1]
        [void]$gradient.GradientStops.Add($stop)
    }
    $trail = New-Object System.Windows.Shapes.Rectangle
    $trail.Width = 1.35
    $trail.Height = $length - 2.5
    $trail.RadiusX = 0.7
    $trail.RadiusY = 0.7
    $trail.Fill = $gradient
    $trail.HorizontalAlignment = 'Center'
    $trail.VerticalAlignment = 'Top'
    [void]$drop.Children.Add($trail)

    $bead = New-Object System.Windows.Shapes.Ellipse
    $bead.Width = 2.6 + $script:random.NextDouble() * 0.8
    $bead.Height = 3.8 + $script:random.NextDouble() * 1.2
    $bead.Fill = $script:rainBrush
    $bead.HorizontalAlignment = 'Center'
    $bead.VerticalAlignment = 'Bottom'
    [void]$drop.Children.Add($bead)

    $drop.RenderTransformOrigin = [System.Windows.Point]::Parse('0.5,0.5')
    $drop.RenderTransform = New-Object System.Windows.Media.RotateTransform (($script:random.NextDouble()-0.5) * 2.4)
    [System.Windows.Controls.Canvas]::SetLeft($drop, $x)
    [System.Windows.Controls.Canvas]::SetTop($drop, -$length)
    [void]$WeatherCanvas.Children.Add($drop)
    $speed = 7.5 + $script:random.NextDouble() * 5.5 + $script:weatherIntensity
    $wind = ($script:random.NextDouble() - 0.5) * 0.24
    [void]$script:particles.Add([pscustomobject]@{ Kind='rain'; Shape=$drop; X=$x; Y=-$length; Age=0; VX=$wind; VY=$speed })
}

function Add-Snowflake([bool]$ambient) {
    $width = [Math]::Max(280, $WeatherCanvas.ActualWidth)
    $flake = New-Object System.Windows.Shapes.Ellipse
    $size = 2.2 + $script:random.NextDouble() * 3.2
    $flake.Width = $size
    $flake.Height = $size
    $flake.Fill = ConvertTo-Brush '#D8EEFF'
    $flake.Opacity = if ($ambient) { 0.42 } else { 0.72 }
    $x = $script:random.NextDouble() * $width
    [System.Windows.Controls.Canvas]::SetLeft($flake, $x)
    [System.Windows.Controls.Canvas]::SetTop($flake, -8)
    [void]$WeatherCanvas.Children.Add($flake)
    $fallSpeed = if ($ambient) { 0.45 } else { 0.8 + $script:random.NextDouble() }
    [void]$script:particles.Add([pscustomobject]@{ Kind='snow'; Shape=$flake; X=$x; Y=-8.0; Age=0; VX=($script:random.NextDouble()-0.5)*0.55; VY=$fallSpeed })
}

function Add-FogBand {
    $width = [Math]::Max(280, $WeatherCanvas.ActualWidth)
    $height = [Math]::Max(200, $WeatherCanvas.ActualHeight)
    $band = New-Object System.Windows.Controls.Border
    $band.Width = 125 + $script:random.NextDouble() * 110
    $band.Height = 24 + $script:random.NextDouble() * 30
    $band.CornerRadius = New-Object System.Windows.CornerRadius -ArgumentList 30
    $band.Background = ConvertTo-Brush '#38DCE8F2'
    $band.Opacity = 0.22 + $script:random.NextDouble() * 0.18
    $blur = New-Object System.Windows.Media.Effects.BlurEffect
    $blur.Radius = 11
    $band.Effect = $blur
    $x = -$band.Width + $script:random.NextDouble() * ($width + $band.Width)
    $y = 16 + $script:random.NextDouble() * [Math]::Max(30, $height - 65)
    [System.Windows.Controls.Canvas]::SetLeft($band, $x)
    [System.Windows.Controls.Canvas]::SetTop($band, $y)
    [void]$WeatherCanvas.Children.Add($band)
    [void]$script:particles.Add([pscustomobject]@{ Kind='fog'; Shape=$band; X=$x; Y=$y; Age=0; VX=(0.12 + $script:random.NextDouble()*0.18); VY=0.0 })
}

function Add-SeasonParticle {
    $width = [Math]::Max(280, $WeatherCanvas.ActualWidth)
    $height = [Math]::Max(200, $WeatherCanvas.ActualHeight)

    $shape = if ($script:season.Key -in @('autumn','winter')) { New-Object System.Windows.Shapes.Rectangle } else { New-Object System.Windows.Shapes.Ellipse }
    $x = $script:random.NextDouble() * $width
    $y = -8.0
    $vx = ($script:random.NextDouble() - 0.5) * 0.7
    $vy = 0.45 + $script:random.NextDouble() * 0.45
    if ($script:season.Key -eq 'spring') {
        $shape.Width=5; $shape.Height=3; $shape.Fill=ConvertTo-Brush '#F3A8BD'; $shape.Opacity=0.48
    } elseif ($script:season.Key -eq 'summer') {
        $shape.Width=3.5; $shape.Height=3.5; $shape.Fill=ConvertTo-Brush '#FFF09A'; $shape.Opacity=0.65
        $y = $height + 4; $vy = -(0.25 + $script:random.NextDouble() * 0.35)
    } elseif ($script:season.Key -eq 'autumn') {
        $shape.Width=5; $shape.Height=3.2; $shape.Fill=ConvertTo-Brush '#E9914B'; $shape.Opacity=0.5
    } else {
        # 冬季晴天只显示冰晶微光，不使用雪花；雪花仅由真实降雪模式触发。
        $shape.Width=3.2; $shape.Height=3.2; $shape.Fill=ConvertTo-Brush '#C7E7FF'; $shape.Opacity=0.42
        $shape.RenderTransformOrigin = [System.Windows.Point]::Parse('0.5,0.5')
        $shape.RenderTransform = New-Object System.Windows.Media.RotateTransform 45
        $y = 12 + $script:random.NextDouble() * ($height - 24)
        $vx = ($script:random.NextDouble() - 0.5) * 0.12
        $vy = -(0.04 + $script:random.NextDouble() * 0.08)
    }
    [System.Windows.Controls.Canvas]::SetLeft($shape, $x)
    [System.Windows.Controls.Canvas]::SetTop($shape, $y)
    [void]$WeatherCanvas.Children.Add($shape)
    [void]$script:particles.Add([pscustomobject]@{ Kind='ambient'; Shape=$shape; X=$x; Y=$y; Age=0; VX=$vx; VY=$vy })
}

function Update-WeatherEffects {
    $LightningFlash.Opacity = [Math]::Max(0, $LightningFlash.Opacity * 0.72)

    # 季节装饰与天气效果是两条独立视觉通道；恶劣天气下仅降低装饰密度。
    $ambientChance = if ($script:weatherMode -eq 'none') { 0.018 } else { 0.006 }
    if ($script:random.NextDouble() -lt $ambientChance) { Add-SeasonParticle }

    if ($script:weatherMode -in @('rain','thunder')) {
        $count = if ($script:weatherIntensity -ge 3) { 2 } elseif ($script:weatherIntensity -eq 2) { 1 } elseif ($script:random.NextDouble() -lt 0.48) { 1 } else { 0 }
        for ($n=0; $n -lt $count; $n++) { Add-RainDrop }
        if ($script:weatherMode -eq 'thunder' -and $script:random.NextDouble() -lt 0.004) {
            $LightningFlash.Opacity = 0.24 + $script:random.NextDouble() * 0.18
        }
    } elseif ($script:weatherMode -eq 'snow') {
        if ($script:random.NextDouble() -lt (0.28 + 0.16 * $script:weatherIntensity)) { Add-Snowflake $false }
    } elseif ($script:weatherMode -eq 'fog') {
        $fogCount = @($script:particles | Where-Object { $_.Kind -eq 'fog' }).Count
        if ($fogCount -lt 5 -and $script:random.NextDouble() -lt 0.12) { Add-FogBand }
    }

    $height = [Math]::Max(200, $WeatherCanvas.ActualHeight)
    $width = [Math]::Max(280, $WeatherCanvas.ActualWidth)
    for ($i=$script:particles.Count-1; $i -ge 0; $i--) {
        $p = $script:particles[$i]
        $remove = $false
        switch ($p.Kind) {
            'rain' {
                $p.X += $p.VX
                $p.Y += $p.VY
                [System.Windows.Controls.Canvas]::SetLeft($p.Shape, $p.X)
                [System.Windows.Controls.Canvas]::SetTop($p.Shape, $p.Y)
                if (($p.Y + $p.Shape.Height) -ge ($height - 5)) {
                    $remove = $true
                    Add-Splash ($p.X + $p.Shape.Width/2) ($height - 5)
                }
            }
            'splash' {
                $p.Age++
                $w = 2 + $p.Age * 1.8
                $p.Shape.Width = $w
                $p.Shape.Height = [Math]::Max(1, $w * 0.22)
                $p.Shape.Opacity = [Math]::Max(0, 0.85 - $p.Age * 0.07)
                [System.Windows.Controls.Canvas]::SetLeft($p.Shape, $p.X - $w/2)
                [System.Windows.Controls.Canvas]::SetTop($p.Shape, $p.Y - $p.Shape.Height/2)
                if ($p.Age -gt 12) { $remove = $true }
            }
            'splashdrop' {
                $p.Age++; $p.X += $p.VX; $p.Y += $p.VY; $p.VY += 0.28
                $p.Shape.Opacity = [Math]::Max(0, 0.9 - $p.Age * 0.065)
                [System.Windows.Controls.Canvas]::SetLeft($p.Shape, $p.X)
                [System.Windows.Controls.Canvas]::SetTop($p.Shape, $p.Y)
                if ($p.Age -gt 14) { $remove = $true }
            }
            'fog' {
                $p.Age++; $p.X += $p.VX
                if ($p.X -gt ($width + 25)) { $p.X = -$p.Shape.Width }
                [System.Windows.Controls.Canvas]::SetLeft($p.Shape, $p.X)
            }
            default {
                $p.Age++; $p.X += $p.VX; $p.Y += $p.VY
                [System.Windows.Controls.Canvas]::SetLeft($p.Shape, $p.X)
                [System.Windows.Controls.Canvas]::SetTop($p.Shape, $p.Y)
                if ($p.Y -gt ($height + 12) -or $p.Y -lt -20 -or $p.X -lt -20 -or $p.X -gt ($width + 20) -or $p.Age -gt 900) { $remove = $true }
            }
        }
        if ($remove) {
            [void]$WeatherCanvas.Children.Remove($p.Shape)
            $script:particles.RemoveAt($i)
        }
    }
}

function Clear-WeatherEffects {
    $WeatherCanvas.Children.Clear()
    $script:particles.Clear()
    $LightningFlash.Opacity = 0
}

function Show-NextWeatherDemo {
    Clear-WeatherEffects
    $script:demoIndex = ($script:demoIndex + 1) % $script:demoScenes.Count
    $scene = $script:demoScenes[$script:demoIndex]
    if ($scene.Season -eq 'current') { Apply-SeasonTheme } else { Apply-SeasonTheme $scene.Season }
    $script:weatherMode = $scene.Mode
    $script:weatherIntensity = $scene.Intensity
    $TitleText.Text = 'Codex 额度'
    $DemoBadge.Visibility = [System.Windows.Visibility]::Visible
    $WeatherText.Text = "$($scene.WeatherName) · 演示 $($script:demoIndex+1)/$($script:demoScenes.Count)"
    $WeatherText.ToolTip = '展示四季常见天气组合；点击刷新立即切换'

    1..4 | ForEach-Object { Add-SeasonParticle }
    if ($scene.Mode -eq 'snow') {
        1..9 | ForEach-Object { Add-Snowflake $false }
    } elseif ($scene.Mode -eq 'fog') {
        1..4 | ForEach-Object { Add-FogBand }
    } elseif ($scene.Mode -in @('rain','thunder')) {
        1..5 | ForEach-Object { Add-RainDrop }
        if ($scene.Mode -eq 'thunder') { $LightningFlash.Opacity = 0.34 }
    } elseif ($scene.Mode -eq 'none') {
        1..3 | ForEach-Object { Add-SeasonParticle }
    }
}

$window.Add_PreviewMouseLeftButtonDown({
    param($sender, $eventArgs)

    # 让标题、文字、进度条等非按钮区域都能直接拖动窗口。
    # Preview 事件可避免子控件先截获鼠标，刷新和关闭按钮仍保持正常点击。
    $current = $eventArgs.OriginalSource
    while ($current -and $current -ne $window) {
        if ($current -is [System.Windows.Controls.Button]) { return }
        try {
            $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
        } catch {
            $current = $null
        }
    }

    if ($eventArgs.LeftButton -eq [System.Windows.Input.MouseButtonState]::Pressed) {
        $window.DragMove()
        $eventArgs.Handled = $true
    }
})
$CloseButton.Add_Click({ $window.Close() })
$RefreshButton.Add_Click({
    Update-Quota
    if ($DemoWeather) { Show-NextWeatherDemo } else { Update-Weather }
})
$PrimaryTrack.Add_SizeChanged({ Set-BarWidth })
$SecondaryTrack.Add_SizeChanged({ Set-BarWidth })

$window.Add_SourceInitialized({
    try {
        if ($DemoWeather) {
            $window.WindowStartupLocation = 'CenterScreen'
            return
        }
        if (Test-Path -LiteralPath $statePath) {
            $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json
            $virtualLeft = [System.Windows.SystemParameters]::VirtualScreenLeft
            $virtualTop = [System.Windows.SystemParameters]::VirtualScreenTop
            $virtualRight = $virtualLeft + [System.Windows.SystemParameters]::VirtualScreenWidth
            $virtualBottom = $virtualTop + [System.Windows.SystemParameters]::VirtualScreenHeight
            if ($state.left -ge $virtualLeft -and $state.left -lt ($virtualRight - 80) -and $state.top -ge $virtualTop -and $state.top -lt ($virtualBottom - 60)) {
                $window.Left = [double]$state.left
                $window.Top = [double]$state.top
            }
        } else {
            $window.WindowStartupLocation = 'Manual'
            $window.Left = [System.Windows.SystemParameters]::WorkArea.Right - $window.Width - 24
            $window.Top = [System.Windows.SystemParameters]::WorkArea.Top + 24
        }
    } catch {}
})

$window.Add_ContentRendered({
    Apply-SeasonTheme
    Update-Quota
    if ($DemoWeather) { Show-NextWeatherDemo } else { Update-Weather }
})
$window.Add_Closed({
    if ($timer) { $timer.Stop() }
    if ($weatherTimer) { $weatherTimer.Stop() }
    if ($fxTimer) { $fxTimer.Stop() }
    if ($demoTimer) { $demoTimer.Stop() }
    try {
        @{ left = $window.Left; top = $window.Top } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    } catch {}
    if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
})

if ($SmokeTest) {
    Apply-SeasonTheme
    $remainingRatio = (Get-RemainingBarWidth 200 36) / 200
    if ([Math]::Abs($remainingRatio - 0.64) -gt 0.001 -or
        $PrimaryFill.HorizontalAlignment -ne [System.Windows.HorizontalAlignment]::Left) { throw '剩余额度进度条自检失败。' }
    $script:weatherMode = 'rain'
    1..18 | ForEach-Object { Update-WeatherEffects }
    $rainParticles = @($script:particles | Where-Object { $_.Kind -in @('rain','splash','splashdrop') }).Count
    Add-Snowflake $false
    Add-SeasonParticle
    $snowParticles = @($script:particles | Where-Object { $_.Kind -eq 'snow' }).Count
    if ($rainParticles -lt 1 -or $snowParticles -lt 1) { throw '天气粒子自检失败。' }
    $script:demoIndex = -1
    $demoCombinations = @()
    1..$script:demoScenes.Count | ForEach-Object {
        Show-NextWeatherDemo
        $demoCombinations += "$($script:season.Key)/$($script:weatherMode)"
    }
    $invalidDemoModes = @('summer/snow','winter/rain','winter/thunder','autumn/snow','autumn/thunder','spring/snow')
    if ($script:demoScenes.Count -ne 14 -or @($demoCombinations | Select-Object -Unique).Count -ne 14 -or @($demoCombinations | Where-Object { $_ -in $invalidDemoModes }).Count -gt 0) { throw '季节与天气合理组合自检失败。' }
    if ($TitleText.Text -ne 'Codex 额度' -or $DemoBadge.Visibility -ne [System.Windows.Visibility]::Visible) { throw 'Demo 正式版界面一致性自检失败。' }
    $modeResults = @(
        (Get-WeatherEffectMode 0 0 0 0),
        (Get-WeatherEffectMode 53 0 0 0),
        (Get-WeatherEffectMode 45 0 0 0),
        (Get-WeatherEffectMode 75 0 0 0),
        (Get-WeatherEffectMode 95 0 0 0)
    ) -join ','
    $oldCache = [pscustomobject]@{ from_cache=$true; fetched_at=[DateTimeOffset]::Now.AddMinutes(-46).ToString('o') }
    if ($modeResults -ne 'none,rain,fog,snow,thunder' -or -not (Test-WeatherCacheExpired $oldCache 45)) { throw '实时天气模式映射自检失败。' }
    Add-FogBand
    if (@($script:particles | Where-Object { $_.Kind -eq 'fog' }).Count -lt 1) { throw '雾效自检失败。' }
    "UI_OK controls=$($names.Count) remaining_bar=$([Math]::Round($remainingRatio*100))% modes=$modeResults demo_scenes=$($script:demoScenes.Count)"
    if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
    exit 0
}

$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds(15)
$timer.Add_Tick({ Update-Quota })
$timer.Start()

$weatherTimer = $null
$demoTimer = $null
if ($DemoWeather) {
    $demoTimer = New-Object Windows.Threading.DispatcherTimer
    $demoTimer.Interval = [TimeSpan]::FromSeconds(5)
    $demoTimer.Add_Tick({ Show-NextWeatherDemo })
    $demoTimer.Start()
} else {
    $weatherTimer = New-Object Windows.Threading.DispatcherTimer
    $weatherMinutes = [Math]::Min(60, [Math]::Max(5, [double]$script:config.refresh_minutes))
    $weatherTimer.Interval = [TimeSpan]::FromMinutes($weatherMinutes)
    $weatherTimer.Add_Tick({ Update-Weather })
    $weatherTimer.Start()
}

$fxTimer = New-Object Windows.Threading.DispatcherTimer
$fxTimer.Interval = [TimeSpan]::FromMilliseconds(33)
$fxTimer.Add_Tick({ Update-WeatherEffects })
$fxTimer.Start()

[void]$window.ShowDialog()


