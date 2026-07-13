param(
    [switch]$Test,
    [switch]$SmokeTest,
    [switch]$TestWeather,
    [switch]$DemoWeather,
    # 公开副本默认使用演示额度；此开关可显式强制使用演示数据。
    [switch]$DemoMode
)

$ErrorActionPreference = 'Stop'

function Get-PublicAppDataDirectory {
    # 公开仓库不保存运行时配置、天气缓存或窗口状态。它们仅位于当前用户的本地应用数据目录。
    $root = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    $path = Join-Path $root 'QuotaWeatherWidgetQBS'
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
    return $path
}

function Get-EnvironmentBoolean([string]$name, [bool]$defaultValue) {
    $raw = [Environment]::GetEnvironmentVariable($name)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $defaultValue }
    switch ($raw.Trim().ToLowerInvariant()) {
        '1' { return $true }
        'true' { return $true }
        'yes' { return $true }
        'on' { return $true }
        '0' { return $false }
        'false' { return $false }
        'no' { return $false }
        'off' { return $false }
        default { return $defaultValue }
    }
}

function Get-PublicQuotaProvider {
    # 默认 DEMO：公开副本不会因启动而读取本机登录数据。
    if ($DemoMode -or $DemoWeather -or (Get-EnvironmentBoolean 'QBS_DEMO_MODE' $true)) {
        return 'demo'
    }
    $configured = [Environment]::GetEnvironmentVariable('QBS_QUOTA_PROVIDER')
    if ($configured -and $configured.Trim().ToLowerInvariant() -eq 'session') {
        return 'session'
    }
    return 'demo'
}

function Get-CodexHome {
    if ($env:CODEX_HOME) { return $env:CODEX_HOME }
    return (Join-Path $env:USERPROFILE '.codex')
}

function Get-DemoCodexRateLimit {
    # 演示数据固定为虚构数值，便于离线验证界面；不会包含真实额度或重置时间。
    $now = [DateTimeOffset]::Now
    return [pscustomobject]@{
        TimestampUtc = [DateTime]::UtcNow
        SourceFile   = 'DEMO'
        Limits       = [pscustomobject]@{
            plan_type = 'DEMO'
            primary   = [pscustomobject]@{
                used_percent   = 30
                window_minutes = 300
                resets_at      = $now.AddHours(3).ToUnixTimeSeconds()
            }
            secondary = [pscustomobject]@{
                used_percent   = 18
                window_minutes = 10080
                resets_at      = $now.AddDays(4).ToUnixTimeSeconds()
            }
            credits = $null
        }
    }
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

    # 大多数 15 秒刷新前会话文件并未改变；复用已解析的额度元数据，
    # 但文件时间戳或长度变化时立即失效，避免无意义的重复读取。
    $signature = (@($files | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)|$($_.Length)" }) -join "`n")
    if ($script:rateLimitCache -and $script:rateLimitCacheSignature -eq $signature) {
        return $script:rateLimitCache
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
    $script:rateLimitCacheSignature = $signature
    $script:rateLimitCache = $best
    return $best
}

function Get-QuotaData {
    # 仅在用户显式设为 session 时，读取本地会话中的 token_count/rate_limits 元数据；
    # 不读取登录数据，也不解析会话正文。
    if ((Get-PublicQuotaProvider) -eq 'demo') {
        return Get-DemoCodexRateLimit
    }
    return Get-LatestCodexRateLimit
}

function Apply-PublicEnvironmentOverrides($config) {
    $locationName = [Environment]::GetEnvironmentVariable('QBS_LOCATION_NAME')
    if (-not [string]::IsNullOrWhiteSpace($locationName)) {
        $config.city = $locationName.Trim()
    }

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $latitudeRaw = [Environment]::GetEnvironmentVariable('QBS_LATITUDE')
    $longitudeRaw = [Environment]::GetEnvironmentVariable('QBS_LONGITUDE')
    $latitude = 0.0
    $longitude = 0.0
    $hasLatitude = [double]::TryParse($latitudeRaw, [Globalization.NumberStyles]::Float, $culture, [ref]$latitude)
    $hasLongitude = [double]::TryParse($longitudeRaw, [Globalization.NumberStyles]::Float, $culture, [ref]$longitude)
    if ($hasLatitude -and $hasLongitude -and $latitude -ge -90 -and $latitude -le 90 -and $longitude -ge -180 -and $longitude -le 180) {
        $config.latitude = $latitude
        $config.longitude = $longitude
        $config.weather_configured = $true
    }

    $config.weather_enabled = Get-EnvironmentBoolean 'QBS_WEATHER_ENABLED' ([bool]$config.weather_enabled)
    return $config
}

function Get-WidgetConfig {
    $configPath = Join-Path (Get-PublicAppDataDirectory) 'widget-config.json'
    $defaults = [ordered]@{
        weather_enabled = $false
        weather_configured = $false
        city            = '示例城市'
        latitude        = 0
        longitude       = 0
        refresh_minutes = 15
        weather_cache_max_minutes = 45
        autoHideEnabled = $true
        edgeSnapThreshold = 10
        visibleStripSize = 8
        hideDelayMs = 500
        animationDurationMs = 200
        hideAnimationDurationMs = 240
        showAnimationDurationMs = 280
        animationFrameIntervalMs = 16
        collapsedBarEnabled = $true
        collapsedBarHeight = 28
         collapsedBarPadding = 10
         collapsedBarOpacity = 0.9
         collapsedBarShowResetTime = $true
         sideCollapsedBarEnabled = $true
         sideCollapsedBarWidth = 64
         sideCollapsedBarHeight = 180
         sideCollapsedBarPadding = 8
         sideProgressTrackWidth = 14
         sideCollapsedBarOpacity = 0.92
         sideProgressChangeDurationMs = 240
    }

    if (-not (Test-Path -LiteralPath $configPath)) {
        $defaults | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
        return Apply-PublicEnvironmentOverrides ([pscustomobject]$defaults)
    }

    try {
        $loaded = Get-Content -Raw -Encoding UTF8 -LiteralPath $configPath | ConvertFrom-Json
        $changed = $false
        # 旧版侧边越界上限已废弃：横向拖到屏幕外仍可成为侧边停靠候选，
        # 因此静默移除旧字段，不改变其他用户设置。
        foreach ($legacyKey in @('edgeOvershootTolerance', 'sideEdgeSnapThreshold')) {
            if ($null -ne $loaded.PSObject.Properties[$legacyKey]) {
                $loaded.PSObject.Properties.Remove($legacyKey)
                $changed = $true
            }
        }
        foreach ($key in $defaults.Keys) {
            if ($null -eq $loaded.$key) {
                $loaded | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key]
                $changed = $true
            }
        }
        if ($changed) { $loaded | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8 }
        return Apply-PublicEnvironmentOverrides $loaded
    } catch {
        return Apply-PublicEnvironmentOverrides ([pscustomobject]$defaults)
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
    if (-not [bool]$config.weather_enabled -or -not [bool]$config.weather_configured) {
        throw '天气功能未配置；请先在本地配置或环境变量中提供示例以外的位置。'
    }
    $cachePath = Join-Path (Get-PublicAppDataDirectory) 'weather-cache.json'
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
    $result = Get-QuotaData
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
# 版本化互斥锁，避免旧版本遗留锁阻止新的状态恢复宿主启动。
$mutexName = if ($SmokeTest) { 'Local\CodexQuotaFloatingWidgetSmokeTest' } elseif ($DemoWeather) { 'Local\CodexQuotaFloatingWidgetDemo' } else { 'Local\CodexQuotaFloatingWidgetV2' }
$mutex = New-Object Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) { exit 0 }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Codex 额度" Width="330" Height="246"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ResizeMode="NoResize" ShowInTaskbar="False">
  <Border Name="RootBorder" CornerRadius="18" Background="#F2162229" BorderBrush="#4CBFC9" BorderThickness="1" Padding="18">
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
$window.ShowInTaskbar = $false

[xml]$collapsedBarXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Height="28" SizeToContent="Width" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ResizeMode="NoResize" ShowInTaskbar="False"
        ShowActivated="False">
  <Border Name="CollapsedBarBorder" Background="#E61C2229" BorderBrush="#526B7789" BorderThickness="1"
          CornerRadius="8" Padding="10,0">
    <TextBlock Name="CollapsedText" Text="Codex｜正在读取额度…" Foreground="#F2F5FA" FontSize="11.5"
               FontFamily="Microsoft YaHei UI" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
  </Border>
</Window>
'@
$collapsedBarReader = New-Object System.Xml.XmlNodeReader $collapsedBarXaml
$collapsedBar = [Windows.Markup.XamlReader]::Load($collapsedBarReader)
$CollapsedText = $collapsedBar.FindName('CollapsedText')
$CollapsedBarBorder = $collapsedBar.FindName('CollapsedBarBorder')

[xml]$sideCollapsedBarXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="64" Height="180" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ResizeMode="NoResize" ShowInTaskbar="False"
        ShowActivated="False">
  <!-- 侧边条保持扁平：仅进度槽、填充和文字三层；
       透明宿主仍提供足够的鼠标唤出区域。 -->
  <Canvas Name="SideCanvas" Background="Transparent" ClipToBounds="True">
    <Border Name="SideTrack" Width="36" Height="172" Background="#E72A3038"
            BorderThickness="0" CornerRadius="1" ClipToBounds="True">
      <Border Name="SideFill" Height="0" VerticalAlignment="Bottom" Background="#50E3C2" CornerRadius="0"/>
    </Border>
    <TextBlock Name="SidePercentText" Text="--%" Foreground="#F4F7FB" Background="Transparent"
               FontSize="12.5" FontWeight="Bold" FontFamily="Microsoft YaHei UI"
               Height="21" TextAlignment="Center" VerticalAlignment="Center"/>
  </Canvas>
</Window>
'@
$sideCollapsedBarReader = New-Object System.Xml.XmlNodeReader $sideCollapsedBarXaml
$sideCollapsedBar = [Windows.Markup.XamlReader]::Load($sideCollapsedBarReader)
$SideCanvas = $sideCollapsedBar.FindName('SideCanvas')
$SideTrack = $sideCollapsedBar.FindName('SideTrack')
$SideFill = $sideCollapsedBar.FindName('SideFill')
$SidePercentText = $sideCollapsedBar.FindName('SidePercentText')

$names = @('RootBorder','StatusDot','DragArea','TitleText','PlanText','DemoBadge','RefreshButton','CloseButton','PrimaryText','PrimaryTrack','PrimaryFill','PrimaryReset','SecondaryText','SecondaryTrack','SecondaryFill','SecondaryReset','SeasonBadge','SeasonText','WeatherText','StatusText','WeatherCanvas','LightningFlash')
foreach ($name in $names) { Set-Variable -Name $name -Value $window.FindName($name) }

$script:primaryUsed = 0.0
$script:secondaryUsed = 0.0
$script:busy = $false
$script:manualRefreshBusy = $false
$script:lastManualRefreshStarted = [DateTime]::MinValue
$script:manualRefreshTimer = $null
$script:statePath = Join-Path (Get-PublicAppDataDirectory) 'widget-state.json'
$script:config = Get-WidgetConfig
$script:quotaProvider = Get-PublicQuotaProvider
$script:season = Get-SeasonInfo ([datetime]::Now) ([double]$script:config.latitude)
$script:primaryAccent = $script:season.Primary
$script:secondaryAccent = $script:season.Secondary
$script:weatherMode = 'none'
$script:weatherIntensity = 1
$script:particles = New-Object System.Collections.ArrayList
$script:random = New-Object System.Random
$script:brushConverter = New-Object System.Windows.Media.BrushConverter
$script:brushCache = @{}
$script:rainBrush = $script:brushConverter.ConvertFromString($script:season.Rain)
$script:autoHideState = 'normal'
$script:dockEdge = 'none'
$script:isDragging = $false
$script:normalLeft = $null
$script:normalTop = $null
$script:hideDelayTimer = $null
$script:autoHideAnimationTimer = $null
$script:autoHideAnimationStart = $null
$script:autoHideAnimationFrom = $null
$script:autoHideAnimationTo = $null
$script:autoHideAnimationFinalState = $null
$script:autoHideAnimationDurationMs = 0
$script:autoHideInitialized = $false
$script:collapsedBarVisible = $false
$script:sideCollapsedBarVisible = $false
$script:sideProgressDisplay = 0.0
$script:sideProgressActual = 0.0
$script:sideProgressTimer = $null
$script:sideProgressAnimationStart = $null
$script:sideProgressAnimationFrom = 0.0
$script:sideProgressAnimationTo = 0.0
$script:normalMonitorId = $null
$script:restoredWindowState = $null
$script:lastDragWorkArea = $null
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
    # 主题、额度和侧边进度只会使用有限的颜色集合。缓存冻结后的画刷，
    # 避免动画帧重复分配相同 WPF 对象；冻结画刷可安全供多个控件共享。
    $key = $color.ToUpperInvariant()
    if (-not $script:brushCache.ContainsKey($key)) {
        $brush = $script:brushConverter.ConvertFromString($color)
        if ($brush -is [System.Windows.Freezable] -and $brush.CanFreeze) { $brush.Freeze() }
        $script:brushCache[$key] = $brush
    }
    return $script:brushCache[$key]
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
    if ($script:busy) { return $false }
    $script:busy = $true
    try {
        $result = Get-QuotaData
        $limits = $result.Limits
        $script:primaryUsed = [double]$limits.primary.used_percent
        if ($limits.secondary) { $script:secondaryUsed = [double]$limits.secondary.used_percent } else { $script:secondaryUsed = 0 }

        $PrimaryText.Text = ('已用 {0:0.#}% · 剩余 {1:0.#}%' -f $script:primaryUsed, [Math]::Max(0, 100 - $script:primaryUsed))
        $SecondaryText.Text = if ($limits.secondary) { ('已用 {0:0.#}% · 剩余 {1:0.#}%' -f $script:secondaryUsed, [Math]::Max(0, 100 - $script:secondaryUsed)) } else { '当前方案未返回' }
        $PrimaryReset.Text = Get-ResetDescription $limits.primary.resets_at
        $SecondaryReset.Text = if ($limits.secondary) { Get-ResetDescription $limits.secondary.resets_at } else { '无第二额度窗口' }
        $isDemoQuota = ($script:quotaProvider -eq 'demo')
        $PlanText.Text = if ($limits.plan_type) { ([string]$limits.plan_type).ToUpperInvariant() } else { '' }
        $DemoBadge.Visibility = if ($isDemoQuota) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Collapsed }
         $PrimaryFill.Background = ConvertTo-Brush (Get-UsageColor $script:primaryUsed $script:primaryAccent)
         $SecondaryFill.Background = ConvertTo-Brush (Get-UsageColor $script:secondaryUsed $script:secondaryAccent)
         Set-BarWidth
         Update-CollapsedBarText $limits
         Set-SideProgressTarget (Get-PrimaryRemainingPercent)

        $age = [DateTime]::UtcNow - $result.TimestampUtc
        if ($age.TotalMinutes -lt 2) { $freshness = '刚刚更新' }
        elseif ($age.TotalHours -lt 1) { $freshness = ('{0} 分钟前更新' -f [Math]::Floor($age.TotalMinutes)) }
        else { $freshness = ('{0} 小时前更新' -f [Math]::Floor($age.TotalHours)) }
        $StatusText.Foreground = '#697487'
        $StatusText.Text = if ($isDemoQuota) { 'DEMO 数据 · 不读取认证文件 · 点击刷新可验证界面' } else { "$freshness · 自动刷新（仅读取额度元数据）" }
        return $true
    } catch {
        $StatusText.Text = $_.Exception.Message
        $StatusText.Foreground = '#FF8A9B'
        return $false
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
        return $true
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
            return $false
        }

        if ($mode -ne $previousMode) { Clear-WeatherEffects }
        $script:weatherMode = $mode
        $script:weatherIntensity = [int]$weather.intensity
        $cacheLabel = if ([bool]$weather.from_cache) { " · 缓存 $([Math]::Max(1,[Math]::Round($cacheAgeMinutes))) 分钟" } else { ' · 实时' }
        $WeatherText.Text = ('{0} · {1} · {2:0.#}°C{3}' -f $weather.city, $weather.description, [double]$weather.temperature, $cacheLabel)
        $WeatherText.ToolTip = "天气数据：Open-Meteo；每 $($script:config.refresh_minutes) 分钟更新；粒子效果：$mode"
        return $true
    } catch {
        $script:weatherMode = 'none'
        if ($previousMode -ne 'none') { Clear-WeatherEffects }
        $LightningFlash.Opacity = 0
        $WeatherText.Text = "$($script:config.city) · 天气暂不可用"
        $WeatherText.ToolTip = $_.Exception.Message
        return $false
    }
}

function Invoke-ManualRefresh {
    $now = [DateTime]::UtcNow
    if ($script:manualRefreshBusy -or (($now - $script:lastManualRefreshStarted).TotalMilliseconds -lt 750)) { return }

    $script:manualRefreshBusy = $true
    $script:lastManualRefreshStarted = $now
    $RefreshButton.IsEnabled = $false
    $RefreshButton.Content = '…'
    $RefreshButton.ToolTip = '正在刷新…'
    if (-not $script:manualRefreshTimer) {
        $script:manualRefreshTimer = New-Object Windows.Threading.DispatcherTimer
        $script:manualRefreshTimer.Interval = [TimeSpan]::FromMilliseconds(1)
        $script:manualRefreshTimer.Add_Tick({
            $script:manualRefreshTimer.Stop()
            try {
                $quotaOk = Update-Quota
                $weatherOk = if ($DemoWeather) { Show-NextWeatherDemo; $true } else { Update-Weather }
                if ($quotaOk -and $weatherOk) {
                    $StatusText.Foreground = '#697487'
                    $StatusText.Text = '刚刚手动刷新 · 额度和天气已更新'
                } else {
                    $StatusText.Foreground = '#FFB454'
                    $StatusText.Text = '手动刷新部分失败，已保留现有数据'
                }
            } catch {
                $StatusText.Foreground = '#FF8A9B'
                $StatusText.Text = '手动刷新失败，已保留现有数据'
            } finally {
                $RefreshButton.Content = '↻'
                $RefreshButton.ToolTip = '立即刷新'
                $RefreshButton.IsEnabled = $true
                $script:manualRefreshBusy = $false
            }
        })
    }
    $script:manualRefreshTimer.Stop()
    $script:manualRefreshTimer.Start()
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
    if ($LightningFlash.Opacity -gt 0) {
        $LightningFlash.Opacity = [Math]::Max(0, $LightningFlash.Opacity * 0.72)
    }

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

function Pause-WeatherEffects {
    if ($fxTimer) { $fxTimer.Stop() }
}

function Resume-WeatherEffects {
    if ($fxTimer -and -not $fxTimer.IsEnabled) { $fxTimer.Start() }
}

function Get-CollapsedResetLabel($epochSeconds) {
    if (-not $epochSeconds) { return '重置时间未知' }
    try { return ('{0:MM-dd HH:mm} 重置' -f [DateTimeOffset]::FromUnixTimeSeconds([long]$epochSeconds).ToLocalTime()) }
    catch { return '重置时间未知' }
}

function Update-CollapsedBarText {
    param($Limits)

    if (-not $CollapsedText) { return }
    $primaryRemaining = [Math]::Max(0, 100 - $script:primaryUsed)
    $secondaryRemaining = [Math]::Max(0, 100 - $script:secondaryUsed)
    $primaryPart = ('5小时剩余：{0:0.#}%' -f $primaryRemaining)
    $secondaryPart = if ($Limits.secondary) { ('本周剩余：{0:0.#}%' -f $secondaryRemaining) } else { '本周额度：未提供' }
    if ([bool]$script:config.collapsedBarShowResetTime) {
        $primaryPart += "（$(Get-CollapsedResetLabel $Limits.primary.resets_at)）"
        if ($Limits.secondary) { $secondaryPart += "（$(Get-CollapsedResetLabel $Limits.secondary.resets_at)）" }
    }
    $CollapsedText.Text = "Codex ｜ $primaryPart ｜ $secondaryPart"
}

function Update-CollapsedBarPosition {
    if ($script:dockEdge -ne 'top') { return }
    $workArea = Get-WidgetWorkArea
    $collapsedBar.UpdateLayout()
    $barWidth = [double]$collapsedBar.ActualWidth
    $barHeight = [double]$collapsedBar.ActualHeight
    $left = $script:normalLeft + (($window.Width - $barWidth) / 2)
    $top = $workArea.Top

    # 横向状态条始终限制在当前显示器工作区内。
    $left = [Math]::Max($workArea.Left, [Math]::Min($left, $workArea.Right - $barWidth))
    $top = [Math]::Max($workArea.Top, [Math]::Min($top, $workArea.Bottom - $barHeight))
    $collapsedBar.Left = $left
    $collapsedBar.Top = $top
}

function Show-CollapsedBar {
    if (-not [bool]$script:config.collapsedBarEnabled -or $script:dockEdge -ne 'top') { return }
    Hide-SideCollapsedBar
    if (-not $script:collapsedBarVisible) {
        # 测量和定位期间保持不可见，避免状态条在 0,0 闪现。
        $collapsedBar.Opacity = 0
        $collapsedBar.Show()
        $script:collapsedBarVisible = $true
    }
    Update-CollapsedBarPosition
    $collapsedBar.Opacity = [Math]::Max(0.1, [Math]::Min(1, [double]$script:config.collapsedBarOpacity))
}

function Hide-CollapsedBar {
    if ($script:collapsedBarVisible) { $collapsedBar.Hide() }
    $script:collapsedBarVisible = $false
}

function Get-PrimaryRemainingPercent {
    return [Math]::Max([double]0, [Math]::Min([double]100, ([double]100 - [double]$script:primaryUsed)))
}

function Update-SideCollapsedBarPosition {
    if ($script:dockEdge -notin @('left','right')) { return }
    $workArea = Get-WidgetWorkArea
    $sideCollapsedBar.UpdateLayout()
    $barWidth = [Math]::Max(48, [double]$sideCollapsedBar.ActualWidth)
    $barHeight = [Math]::Max(100, [double]$sideCollapsedBar.ActualHeight)
    $desiredTop = [double]$script:normalTop + (($window.Height - $barHeight) / 2)
    $sideCollapsedBar.Left = if ($script:dockEdge -eq 'left') { $workArea.Left } else { $workArea.Right - $barWidth }
    $sideCollapsedBar.Top = [Math]::Max($workArea.Top, [Math]::Min($desiredTop, $workArea.Bottom - $barHeight))
}

function Update-SideCollapsedBarVisual {
    param([double]$Remaining)

    $remaining = [Math]::Max([double]0, [Math]::Min([double]100, $Remaining))
    $sideCollapsedBar.UpdateLayout()
    $barWidth = [Math]::Max(40, [double]$sideCollapsedBar.ActualWidth)
    $barHeight = [Math]::Max(100, [double]$sideCollapsedBar.ActualHeight)
    # 参考样式的竖向版本只保留一个宽进度槽、填充和文字，不增加边框。
    # 进度槽贴住对应屏幕边缘；透明窗口的其余区域仅用于扩大鼠标进入范围。
    $trackWidth = [Math]::Max(30, [Math]::Min(38, $barWidth))
    $trackHeight = [Math]::Max(72, $barHeight - 8)
    $trackTop = 4.0
    $trackLeft = if ($script:dockEdge -eq 'right') { $barWidth - $trackWidth } else { 0.0 }
    $fillHeight = $trackHeight * $remaining / 100
    $fillTop = $trackTop + ($trackHeight - $fillHeight)
    $labelWidth = $trackWidth
    $labelHeight = 21.0
    $labelLeft = $trackLeft
    $labelGap = 4.0
    # 完整数字位于填充端点正上方的未填充区域。两端由 Clamp 保证可见；
    # 接近顶部仅切换文字颜色，不添加标签、边框、阴影或背景板。
    $labelTop = [Math]::Max(
        $trackTop + 2,
        [Math]::Min($fillTop - $labelHeight - $labelGap, $trackTop + $trackHeight - 2 - $labelHeight)
    )
    $labelOverFill = ($labelTop + $labelHeight) -gt ($fillTop - 0.5)

    $SideTrack.Width = $trackWidth
    $SideTrack.Height = $trackHeight
    $SideFill.Height = $fillHeight
    $SideFill.Background = ConvertTo-Brush (Get-UsageColor (100 - $remaining) $script:primaryAccent)
    $SideTrack.BorderThickness = [System.Windows.Thickness]::new(0)
    $SidePercentText.Width = $labelWidth
    $SidePercentText.Height = $labelHeight
    $SidePercentText.Text = ('{0:0.#}%' -f $remaining)
    $SidePercentText.Foreground = ConvertTo-Brush $(if ($labelOverFill) { '#122127' } else { '#F4F7FB' })
    [System.Windows.Controls.Canvas]::SetLeft($SideTrack, $trackLeft)
    [System.Windows.Controls.Canvas]::SetTop($SideTrack, $trackTop)
    [System.Windows.Controls.Canvas]::SetLeft($SidePercentText, $labelLeft)
    [System.Windows.Controls.Canvas]::SetTop($SidePercentText, $labelTop)
    [System.Windows.Controls.Panel]::SetZIndex($SideTrack, 0)
    [System.Windows.Controls.Panel]::SetZIndex($SidePercentText, 10)
}

function Set-SideProgressTarget {
    param([double]$Remaining)

    $target = [Math]::Max([double]0, [Math]::Min([double]100, $Remaining))
    $script:sideProgressActual = $target
    if (-not $script:sideCollapsedBarVisible -or -not $script:sideProgressTimer) {
        $script:sideProgressDisplay = $target
        Update-SideCollapsedBarVisual $target
        return
    }

    $script:sideProgressTimer.Stop()
    $from = [double]$script:sideProgressDisplay
    if ([Math]::Abs($from - $target) -lt 0.05) {
        $script:sideProgressDisplay = $target
        Update-SideCollapsedBarVisual $target
        return
    }
    $script:sideProgressAnimationFrom = $from
    $script:sideProgressAnimationTo = $target
    $script:sideProgressAnimationStart = [DateTime]::UtcNow
    $script:sideProgressTimer.Start()
}

function Show-SideCollapsedBar {
    if (-not [bool]$script:config.sideCollapsedBarEnabled -or $script:dockEdge -notin @('left','right')) { return }
    Hide-CollapsedBar
    if (-not $script:sideCollapsedBarVisible) {
        $sideCollapsedBar.Opacity = 0
        $sideCollapsedBar.Show()
        $script:sideCollapsedBarVisible = $true
    }
    Update-SideCollapsedBarPosition
    Set-SideProgressTarget (Get-PrimaryRemainingPercent)
    $sideCollapsedBar.Opacity = [Math]::Max(0.1, [Math]::Min(1, [double]$script:config.sideCollapsedBarOpacity))
}

function Hide-SideCollapsedBar {
    if ($script:sideCollapsedBarVisible) { $sideCollapsedBar.Hide() }
    $script:sideCollapsedBarVisible = $false
    if ($script:sideProgressTimer) { $script:sideProgressTimer.Stop() }
}

function Hide-AllCollapsedBars {
    Hide-CollapsedBar
    Hide-SideCollapsedBar
}

function Show-ActiveCollapsedBar {
    # 停靠方向只决定折叠呈现形式；所有边缘共用延迟与过渡状态。
    switch ($script:dockEdge) {
        'top' { Show-CollapsedBar }
        'left' { Show-SideCollapsedBar }
        'right' { Show-SideCollapsedBar }
    }
}

function Convert-ScreenWorkAreaToWidgetUnits {
    param($Screen)

    # Screen.WorkingArea 按显示器返回且不含任务栏。将物理像素换算为 WPF 单位，
    # 使吸附在 DPI 缩放下仍保持正确。
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
    $scaleX = [Math]::Max(0.1, [double]$dpi.DpiScaleX)
    $scaleY = [Math]::Max(0.1, [double]$dpi.DpiScaleY)
    $area = $Screen.WorkingArea
    $left = [double]$area.Left / $scaleX
    $top = [double]$area.Top / $scaleY
    $width = [double]$area.Width / $scaleX
    $height = [double]$area.Height / $scaleY
    return [pscustomobject]@{ Left=$left; Top=$top; Right=($left + $width); Bottom=($top + $height); MonitorId=$Screen.DeviceName }
}

function Get-WindowIntersectingWorkArea {
    try {
        $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($window)
        $scaleX = [Math]::Max(0.1, [double]$dpi.DpiScaleX)
        $scaleY = [Math]::Max(0.1, [double]$dpi.DpiScaleY)
        $windowLeft = [double]$window.Left
        $windowTop = [double]$window.Top
        $windowRight = $windowLeft + [double]$window.Width
        $windowBottom = $windowTop + [double]$window.Height
        $largestOverlap = 0.0
        $best = $null

        foreach ($screen in [System.Windows.Forms.Screen]::AllScreens) {
            $bounds = $screen.Bounds
            $screenLeft = [double]$bounds.Left / $scaleX
            $screenTop = [double]$bounds.Top / $scaleY
            $screenRight = $screenLeft + ([double]$bounds.Width / $scaleX)
            $screenBottom = $screenTop + ([double]$bounds.Height / $scaleY)
            $overlapWidth = [Math]::Max(0, [Math]::Min($windowRight, $screenRight) - [Math]::Max($windowLeft, $screenLeft))
            $overlapHeight = [Math]::Max(0, [Math]::Min($windowBottom, $screenBottom) - [Math]::Max($windowTop, $screenTop))
            $overlap = $overlapWidth * $overlapHeight
            if ($overlap -gt $largestOverlap) {
                $largestOverlap = $overlap
                $best = Convert-ScreenWorkAreaToWidgetUnits $screen
            }
        }
        return $best
    } catch {
        if ($SmokeTest) { throw }
        return $null
    }
}

function Get-WidgetWorkArea {
    param([switch]$UseLastDragWorkArea)

    # 优先选择实际重叠面积最大的显示器。窗口完全离开所有显示器时，
    # 保留本次拖动最后接触的显示器，不能放弃侧边停靠判定。
    $intersecting = Get-WindowIntersectingWorkArea
    if ($null -ne $intersecting) { return $intersecting }
    if ($UseLastDragWorkArea -and $null -ne $script:lastDragWorkArea) { return $script:lastDragWorkArea }

    try {
        $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        if ($handle -ne [IntPtr]::Zero) {
            return Convert-ScreenWorkAreaToWidgetUnits ([System.Windows.Forms.Screen]::FromHandle($handle))
        }
    } catch {}

    $fallback = [System.Windows.SystemParameters]::WorkArea
    return [pscustomobject]@{ Left=[double]$fallback.Left; Top=[double]$fallback.Top; Right=[double]$fallback.Right; Bottom=[double]$fallback.Bottom; MonitorId=$null }
}

function Get-WidgetWorkAreaForMonitorId {
    param([string]$MonitorId)

    try {
        $screen = $null
        if (-not [string]::IsNullOrWhiteSpace($MonitorId)) {
            $screen = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $MonitorId } | Select-Object -First 1
        }
        if ($null -eq $screen) { $screen = [System.Windows.Forms.Screen]::PrimaryScreen }
        if ($null -ne $screen) { return Convert-ScreenWorkAreaToWidgetUnits $screen }
    } catch {}
    return Get-WidgetWorkArea
}

function Get-StateNumber {
    param($State, [string]$Name, [double]$Fallback)

    try {
        $property = $State.PSObject.Properties[$Name]
        if ($null -ne $property -and $null -ne $property.Value) {
            $value = [double]$property.Value
            if (-not [double]::IsNaN($value) -and -not [double]::IsInfinity($value)) { return $value }
        }
    } catch {}
    return $Fallback
}

function Read-WindowState {
    if (-not (Test-Path -LiteralPath $script:statePath)) { return $null }
    try {
        $rawState = Get-Content -Raw -LiteralPath $script:statePath | ConvertFrom-Json
        $savedLeft = Get-StateNumber $rawState 'normalLeft' (Get-StateNumber $rawState 'left' ([double]::NaN))
        $savedTop = Get-StateNumber $rawState 'normalTop' (Get-StateNumber $rawState 'top' ([double]::NaN))
        if ([double]::IsNaN($savedLeft) -or [double]::IsNaN($savedTop)) { return $null }
        $dockEdge = if ([string]$rawState.dockState -in @('top','left','right')) { [string]$rawState.dockState } else { 'none' }
        $displayState = if ([string]$rawState.displayState -eq 'collapsed' -and $dockEdge -ne 'none') { 'collapsed' } else { 'expanded' }
        return [pscustomobject]@{
            NormalLeft = $savedLeft
            NormalTop = $savedTop
            MonitorId = if ($null -ne $rawState.monitorId) { [string]$rawState.monitorId } else { $null }
            DockEdge = $dockEdge
            DisplayState = $displayState
        }
    } catch {
        if ($SmokeTest) { throw }
        return $null
    }
}

function Get-NormalizedDockedPosition {
    param([ValidateSet('top','left','right')][string]$Edge, $WorkArea, [double]$Left, [double]$Top)

    $safeLeft = Clamp-WindowCoordinate $Left $WorkArea.Left ($WorkArea.Right - $window.Width)
    $safeTop = Clamp-WindowCoordinate $Top $WorkArea.Top ($WorkArea.Bottom - $window.Height)
    switch ($Edge) {
        'top' { $safeTop = $WorkArea.Top }
        'left' { $safeLeft = $WorkArea.Left }
        'right' { $safeLeft = $WorkArea.Right - $window.Width }
    }
    return [pscustomobject]@{ Left=$safeLeft; Top=$safeTop }
}

function Apply-RestoredWindowState {
    $state = Read-WindowState
    if ($null -eq $state) { return $false }

    $workArea = Get-WidgetWorkAreaForMonitorId $state.MonitorId
    $position = if ($state.DockEdge -eq 'none') {
        [pscustomobject]@{
            Left=(Clamp-WindowCoordinate $state.NormalLeft $workArea.Left ($workArea.Right - $window.Width))
            Top=(Clamp-WindowCoordinate $state.NormalTop $workArea.Top ($workArea.Bottom - $window.Height))
        }
    } else {
        Get-NormalizedDockedPosition $state.DockEdge $workArea $state.NormalLeft $state.NormalTop
    }

    $script:normalLeft = [double]$position.Left
    $script:normalTop = [double]$position.Top
    $script:normalMonitorId = $workArea.MonitorId
    $script:dockEdge = $state.DockEdge
    $script:autoHideState = if ($state.DisplayState -eq 'collapsed') { 'collapsed' } elseif ($state.DockEdge -eq 'none') { 'normal' } else { 'expanded' }
    $script:restoredWindowState = [pscustomobject]@{ DockEdge=$state.DockEdge; DisplayState=$state.DisplayState }

    if ($state.DisplayState -eq 'collapsed') {
        $hidden = Get-DockedHiddenWindowPosition $state.DockEdge $workArea
        $window.Left = $hidden.Left
        $window.Top = $hidden.Top
    } else {
        $window.Left = $position.Left
        $window.Top = $position.Top
    }
    return $true
}

function Test-DockedEdge {
    param($workArea)

    # 与顶部停靠使用相同的工作区阈值。横向越界不再设上限：
    # 即使远离左右边缘，仍代表对应方向的停靠请求。
    $threshold = [Math]::Max(1, [double]$script:config.edgeSnapThreshold)

    $topOffset = [double]$window.Top - [double]$workArea.Top
    $leftOffset = [double]$window.Left - [double]$workArea.Left
    $rightOffset = ([double]$window.Left + [double]$window.Width) - [double]$workArea.Right
    $topDistance = [Math]::Abs($topOffset)
    $leftDistance = [Math]::Abs($leftOffset)
    $rightDistance = [Math]::Abs($rightOffset)

    # 侧边停靠使用单向条件，不能改成绝对距离比较；
    # 否则窗口拖到目标显示器外较远处会被错误拒绝。
    $topCandidate = $topDistance -le $threshold
    $leftCandidate = $leftOffset -le $threshold
    $rightCandidate = $rightOffset -ge (-$threshold)
    if (-not ($topCandidate -or $leftCandidate -or $rightCandidate)) { return 'none' }

    $candidateDistances = @()
    if ($topCandidate) { $candidateDistances += $topDistance }
    if ($leftCandidate) { $candidateDistances += $leftDistance }
    if ($rightCandidate) { $candidateDistances += $rightDistance }
    $minimum = ($candidateDistances | Measure-Object -Minimum).Minimum

    # 仅在真正相等或非常接近时顶部优先；保持角落行为，
    # 但不妨碍明显更接近侧边时的吸附。
    if ($topCandidate -and $topDistance -le ($minimum + 0.5)) { return 'top' }
    if ($leftCandidate -and $leftDistance -le ($minimum + 0.5)) { return 'left' }
    return 'right'
}

function Clamp-WindowCoordinate([double]$Value, [double]$Minimum, [double]$Maximum) {
    return [Math]::Max($Minimum, [Math]::Min($Value, [Math]::Max($Minimum, $Maximum)))
}

function Get-DockedExpandedWindowPosition {
    param([ValidateSet('top','left','right')][string]$Edge, $WorkArea)
    return Get-NormalizedDockedPosition $Edge $WorkArea ([double]$window.Left) ([double]$window.Top)
}

function Get-DockedVisibleStrip([string]$Edge) {
    $hasIndependentBar = if ($Edge -eq 'top') { [bool]$script:config.collapsedBarEnabled } else { [bool]$script:config.sideCollapsedBarEnabled }
    if ($hasIndependentBar) { return 0.0 }
    return [Math]::Max(1, [Math]::Min([double]$script:config.visibleStripSize, [Math]::Min($window.Width, $window.Height) - 1))
}

function Get-DockedHiddenWindowPosition {
    param([ValidateSet('top','left','right')][string]$Edge, $WorkArea)

    $strip = Get-DockedVisibleStrip $Edge
    switch ($Edge) {
        'top' { return [pscustomobject]@{ Left=[double]$script:normalLeft; Top=([double]$WorkArea.Top - $window.Height + $strip) } }
        'left' { return [pscustomobject]@{ Left=([double]$WorkArea.Left - $window.Width + $strip); Top=[double]$script:normalTop } }
        'right' { return [pscustomobject]@{ Left=([double]$WorkArea.Right - $strip); Top=[double]$script:normalTop } }
    }
}

function Test-WindowFullyOutsideDockEdge {
    param([ValidateSet('top','left','right')][string]$Edge, $WorkArea)

    switch ($Edge) {
        'left' { return (([double]$window.Left + [double]$window.Width) -le [double]$WorkArea.Left) }
        'right' { return ([double]$window.Left -ge [double]$WorkArea.Right) }
        default { return $false }
    }
}

function Get-TopHiddenWindowPosition {
    param(
        $WorkArea,
        [double]$Height,
        [double]$VisibleStrip,
        [double]$NormalLeft
    )

    return [pscustomobject]@{ Left=$NormalLeft; Top=([double]$WorkArea.Top - $Height + $VisibleStrip) }
}

function Set-NormalWindowPosition {
    $script:normalLeft = [double]$window.Left
    $script:normalTop = [double]$window.Top
    $workArea = Get-WindowIntersectingWorkArea
    if ($null -ne $workArea) { $script:normalMonitorId = $workArea.MonitorId }
}

function Get-WindowMonitorId {
    try {
        $handle = [System.Windows.Interop.WindowInteropHelper]::new($window).Handle
        if ($handle -ne [IntPtr]::Zero) { return [System.Windows.Forms.Screen]::FromHandle($handle).DeviceName }
    } catch {}
    return $null
}

function Save-WindowState {
    try {
        $normalLeft = if ($null -ne $script:normalLeft) { [double]$script:normalLeft } else { [double]$window.Left }
        $normalTop = if ($null -ne $script:normalTop) { [double]$script:normalTop } else { [double]$window.Top }
        $dockState = if ($script:dockEdge -in @('top','left','right')) { $script:dockEdge } else { 'none' }
        $displayState = if ($script:autoHideState -in @('collapsed','hiding')) { 'collapsed' } else { 'expanded' }
        $workArea = Get-WidgetWorkArea -UseLastDragWorkArea

        # 拖动中关闭也必须归一为稳定可见位置或标准停靠状态；
        # 绝不保存临时坐标或远离屏幕的 DragMove 坐标。
        if ($script:isDragging) {
            $dragEdge = Test-DockedEdge $workArea
            if ($dragEdge -eq 'none') {
                $normalLeft = Clamp-WindowCoordinate ([double]$window.Left) $workArea.Left ($workArea.Right - $window.Width)
                $normalTop = Clamp-WindowCoordinate ([double]$window.Top) $workArea.Top ($workArea.Bottom - $window.Height)
                $dockState = 'none'
                $displayState = 'expanded'
            } else {
                $normalized = Get-NormalizedDockedPosition $dragEdge $workArea ([double]$window.Left) ([double]$window.Top)
                $normalLeft = $normalized.Left
                $normalTop = $normalized.Top
                $dockState = $dragEdge
                $displayState = if (Test-WindowFullyOutsideDockEdge $dragEdge $workArea) { 'collapsed' } else { 'expanded' }
            }
        } elseif ($dockState -ne 'none') {
            $normalized = Get-NormalizedDockedPosition $dockState $workArea $normalLeft $normalTop
            $normalLeft = $normalized.Left
            $normalTop = $normalized.Top
        } else {
            $normalLeft = Clamp-WindowCoordinate $normalLeft $workArea.Left ($workArea.Right - $window.Width)
            $normalTop = Clamp-WindowCoordinate $normalTop $workArea.Top ($workArea.Bottom - $window.Height)
        }

        $monitorId = if (-not [string]::IsNullOrWhiteSpace([string]$script:normalMonitorId)) { $script:normalMonitorId } else { $workArea.MonitorId }
        if ([string]::IsNullOrWhiteSpace([string]$monitorId)) { $monitorId = Get-WindowMonitorId }

        $payload = [ordered]@{
            version = 3
            left = $normalLeft
            top = $normalTop
            normalLeft = $normalLeft
            normalTop = $normalTop
            monitorId = $monitorId
            dockState = $dockState
            displayState = $displayState
            savedAt = [DateTimeOffset]::Now.ToString('o')
        }
        $tempPath = "$script:statePath.tmp"
        $payload | ConvertTo-Json | Set-Content -LiteralPath $tempPath -Encoding UTF8
        if (Test-Path -LiteralPath $script:statePath) {
            [System.IO.File]::Replace($tempPath, $script:statePath, $null)
        } else {
            [System.IO.File]::Move($tempPath, $script:statePath)
        }
    } catch {}
    finally {
        if (Test-Path -LiteralPath "$script:statePath.tmp") { Remove-Item -LiteralPath "$script:statePath.tmp" -Force -ErrorAction SilentlyContinue }
    }
}

function Stop-PendingAutoHide {
    if ($script:hideDelayTimer) { $script:hideDelayTimer.Stop() }
}

function Get-AutoHideAnimationDuration([string]$finalState) {
    $configured = if ($finalState -eq 'collapsed') { $script:config.hideAnimationDurationMs } else { $script:config.showAnimationDurationMs }
    return [Math]::Max(80, [Math]::Min(1200, [double]$configured))
}

function Get-AutoHideEasedProgress([double]$progress, [string]$finalState) {
    $p = [Math]::Max([double]0, [Math]::Min([double]1, [double]$progress))
    if ($finalState -eq 'collapsed') {
        # easeInCubic：开始轻缓，随后自然加速收回。
        return $p * $p * $p
    }
    # easeOutCubic：立即出现，接近最终停靠点时平稳减速。
    return 1 - ((1 - $p) * (1 - $p) * (1 - $p))
}

function Stop-AutoHideAnimation {
    if ($script:autoHideAnimationTimer) { $script:autoHideAnimationTimer.Stop() }
}

function Complete-DockedTransition {
    param([ValidateSet('collapsed','expanded')][string]$FinalState)

    $script:autoHideState = $FinalState
    if ($FinalState -eq 'collapsed') {
        Show-ActiveCollapsedBar
        Pause-WeatherEffects
    } else {
        Hide-AllCollapsedBars
    }
}

function Start-AutoHideAnimation {
    param(
        [double]$TargetLeft,
        [double]$TargetTop,
        [ValidateSet('collapsed','expanded')][string]$FinalState
    )

    if (-not $script:autoHideAnimationTimer) {
        $window.Left = $TargetLeft
        $window.Top = $TargetTop
        Complete-DockedTransition $FinalState
        return
    }

    Stop-AutoHideAnimation
    $script:autoHideAnimationFrom = [pscustomobject]@{ Left=[double]$window.Left; Top=[double]$window.Top }
    $script:autoHideAnimationTo = [pscustomobject]@{ Left=$TargetLeft; Top=$TargetTop }
    $script:autoHideAnimationStart = [DateTime]::UtcNow
    $script:autoHideAnimationFinalState = $FinalState
    $script:autoHideAnimationDurationMs = Get-AutoHideAnimationDuration $FinalState
    $script:autoHideState = if ($FinalState -eq 'collapsed') { 'hiding' } else { 'showing' }

    if ([Math]::Abs($window.Left - $TargetLeft) -lt 0.1 -and [Math]::Abs($window.Top - $TargetTop) -lt 0.1) {
        Complete-DockedTransition $FinalState
        return
    }
    $script:autoHideAnimationTimer.Start()
}

function Hide-DockedWindow {
    if (-not [bool]$script:config.autoHideEnabled -or $script:isDragging -or $script:dockEdge -eq 'none') { return }
    if ($script:autoHideState -in @('collapsed','hiding')) { return }

    $workArea = Get-WidgetWorkArea
    $target = Get-DockedHiddenWindowPosition $script:dockEdge $workArea
    Start-AutoHideAnimation $target.Left $target.Top 'collapsed'
}

function Show-DockedWindow {
    Stop-PendingAutoHide
    if ($script:dockEdge -eq 'none' -or $null -eq $script:normalLeft -or $null -eq $script:normalTop) { return }
    Resume-WeatherEffects
    # 与顶部停靠完全一致：弹出过渡开始即移除当前折叠面，
    # 之后每个方向都由同一个控制器负责移动。
    Hide-AllCollapsedBars
    if ($script:autoHideState -eq 'expanded') { return }
    Start-AutoHideAnimation $script:normalLeft $script:normalTop 'expanded'
}

function Request-AutoHide {
    if (-not [bool]$script:config.autoHideEnabled -or $script:isDragging -or $script:dockEdge -eq 'none') { return }
    # 与顶部行为一致：移除折叠面期间产生的离开事件会被忽略。
    # 主窗口完全显示后，真实的离开事件才启动共享延迟。
    if ($script:autoHideState -ne 'expanded') { return }
    Stop-PendingAutoHide
    if ($script:hideDelayTimer) { $script:hideDelayTimer.Start() }
}

function Update-DockedState {
    if (-not [bool]$script:config.autoHideEnabled) {
        Hide-AllCollapsedBars
        Resume-WeatherEffects
        $script:dockEdge = 'none'
        $script:autoHideState = 'normal'
        Set-NormalWindowPosition
        return
    }

    Stop-PendingAutoHide
    Stop-AutoHideAnimation
    # 仅拖动可切换边缘。计算新方向前先清除旧折叠面，
    # 防止旧方向的计时器、动画或状态条泄漏到新方向。
    Hide-AllCollapsedBars
    Resume-WeatherEffects
    $script:dockEdge = 'none'
    $workArea = Get-WidgetWorkArea -UseLastDragWorkArea
    $script:normalMonitorId = $workArea.MonitorId
    $edge = Test-DockedEdge $workArea
    $script:dockEdge = $edge
    if ($edge -ne 'none') {
        $fullyOutsideSide = Test-WindowFullyOutsideDockEdge $edge $workArea
        $position = Get-DockedExpandedWindowPosition $edge $workArea
        $window.Left = $position.Left
        $window.Top = $position.Top
        Set-NormalWindowPosition
        if ($fullyOutsideSide) {
            # 主窗口完全出屏后无法可靠触发后续 MouseLeave；
            # 立即归一到标准隐藏坐标并显示侧边唤出条。
            $target = Get-DockedHiddenWindowPosition $edge $workArea
            $window.Left = $target.Left
            $window.Top = $target.Top
            Complete-DockedTransition 'collapsed'
        } else {
            $script:autoHideState = 'expanded'
        }
    } else {
        $script:autoHideState = 'normal'
        Hide-AllCollapsedBars
        Resume-WeatherEffects
    }
    if ($edge -eq 'none') { Set-NormalWindowPosition }
    $script:lastDragWorkArea = $null
}

function Initialize-AutoHide {
    if ($DemoWeather -or $script:autoHideInitialized) { return }
    $script:autoHideInitialized = $true

    $barHeight = [Math]::Max(24, [Math]::Min(40, [double]$script:config.collapsedBarHeight))
    $barPadding = [Math]::Max(4, [Math]::Min(24, [double]$script:config.collapsedBarPadding))
    $collapsedBar.Height = $barHeight
    $CollapsedBarBorder.Padding = [System.Windows.Thickness]::new($barPadding, 0, $barPadding, 0)
    $sideCollapsedBar.Width = [Math]::Max(56, [Math]::Min(84, [double]$script:config.sideCollapsedBarWidth))
    $sideCollapsedBar.Height = [Math]::Max(140, [Math]::Min(230, [double]$script:config.sideCollapsedBarHeight))

    $script:hideDelayTimer = New-Object Windows.Threading.DispatcherTimer
    $script:hideDelayTimer.Interval = [TimeSpan]::FromMilliseconds([Math]::Max(0, [double]$script:config.hideDelayMs))
    $script:hideDelayTimer.Add_Tick({
        $script:hideDelayTimer.Stop()
        Hide-DockedWindow
    })

    $script:autoHideAnimationTimer = New-Object Windows.Threading.DispatcherTimer
    $frameInterval = [Math]::Max(10, [Math]::Min(33, [double]$script:config.animationFrameIntervalMs))
    $script:autoHideAnimationTimer.Interval = [TimeSpan]::FromMilliseconds($frameInterval)
    $script:autoHideAnimationTimer.Add_Tick({
        $duration = [Math]::Max(1, [double]$script:autoHideAnimationDurationMs)
        $progress = [Math]::Min([double]1, (([DateTime]::UtcNow - $script:autoHideAnimationStart).TotalMilliseconds / $duration))
        $eased = Get-AutoHideEasedProgress $progress $script:autoHideAnimationFinalState
        $window.Left = $script:autoHideAnimationFrom.Left + (($script:autoHideAnimationTo.Left - $script:autoHideAnimationFrom.Left) * $eased)
        $window.Top = $script:autoHideAnimationFrom.Top + (($script:autoHideAnimationTo.Top - $script:autoHideAnimationFrom.Top) * $eased)
        if ($progress -ge 1) {
            $window.Left = $script:autoHideAnimationTo.Left
            $window.Top = $script:autoHideAnimationTo.Top
            Stop-AutoHideAnimation
            Complete-DockedTransition $script:autoHideAnimationFinalState
        }
    })

    $script:sideProgressTimer = New-Object Windows.Threading.DispatcherTimer
    $script:sideProgressTimer.Interval = [TimeSpan]::FromMilliseconds(16)
    $script:sideProgressTimer.Add_Tick({
        $duration = [Math]::Max(80, [Math]::Min(1200, [double]$script:config.sideProgressChangeDurationMs))
        $progress = [Math]::Min([double]1, (([DateTime]::UtcNow - $script:sideProgressAnimationStart).TotalMilliseconds / $duration))
        $eased = Get-AutoHideEasedProgress $progress 'expanded'
        $script:sideProgressDisplay = $script:sideProgressAnimationFrom + (($script:sideProgressAnimationTo - $script:sideProgressAnimationFrom) * $eased)
        Update-SideCollapsedBarVisual $script:sideProgressDisplay
        if ($progress -ge 1) {
            $script:sideProgressDisplay = $script:sideProgressAnimationTo
            Update-SideCollapsedBarVisual $script:sideProgressDisplay
            $script:sideProgressTimer.Stop()
        }
    })

    $window.Add_MouseEnter({ Show-DockedWindow })
    $window.Add_MouseLeave({ Request-AutoHide })
    $collapsedBar.Add_MouseEnter({ Show-DockedWindow })
    $collapsedBar.Add_MouseLeave({ Request-AutoHide })
    $sideCollapsedBar.Add_MouseEnter({ Show-DockedWindow })
    $sideCollapsedBar.Add_MouseLeave({ Request-AutoHide })
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
        Stop-PendingAutoHide
        if ($script:autoHideState -in @('collapsed','hiding')) {
            Show-DockedWindow
            return
        }
        Stop-AutoHideAnimation
        Hide-AllCollapsedBars
        $script:isDragging = $true
        $script:lastDragWorkArea = Get-WidgetWorkArea
        $script:autoHideState = 'dragging'
        try {
            $window.DragMove()
        } finally {
            $script:isDragging = $false
            Update-DockedState
        }
        $eventArgs.Handled = $true
    }
})
$CloseButton.Add_Click({ $window.Close() })
$RefreshButton.Add_Click({ Invoke-ManualRefresh })
$PrimaryTrack.Add_SizeChanged({ Set-BarWidth })
$SecondaryTrack.Add_SizeChanged({ Set-BarWidth })

$window.Add_LocationChanged({
    if ($script:isDragging) {
        $intersectingWorkArea = Get-WindowIntersectingWorkArea
        if ($null -ne $intersectingWorkArea) { $script:lastDragWorkArea = $intersectingWorkArea }
    }
})

$window.Add_SourceInitialized({
    try {
        if ($DemoWeather) {
            $window.WindowStartupLocation = 'CenterScreen'
            return
        }
        $window.WindowStartupLocation = 'Manual'
        if (-not (Apply-RestoredWindowState)) {
            $window.Left = [System.Windows.SystemParameters]::WorkArea.Right - $window.Width - 24
            $window.Top = [System.Windows.SystemParameters]::WorkArea.Top + 24
            Set-NormalWindowPosition
        }
        if ($null -eq $script:normalLeft -or $null -eq $script:normalTop) {
            $window.Left = [System.Windows.SystemParameters]::WorkArea.Right - $window.Width - 24
            $window.Top = [System.Windows.SystemParameters]::WorkArea.Top + 24
            Set-NormalWindowPosition
        }
    } catch {}
})

$window.Add_ContentRendered({
    if (-not $DemoWeather) {
        if ($null -eq $script:normalLeft -or $null -eq $script:normalTop) { Set-NormalWindowPosition }
        Initialize-AutoHide
        if ($null -ne $script:restoredWindowState) {
            if ($script:restoredWindowState.DisplayState -eq 'collapsed') {
                # 首次渲染前主窗口已置于屏幕外；此时只显示已保存方向的唤出条。
                $workArea = Get-WidgetWorkAreaForMonitorId $script:normalMonitorId
                $target = Get-DockedHiddenWindowPosition $script:dockEdge $workArea
                $window.Left = $target.Left
                $window.Top = $target.Top
                Complete-DockedTransition 'collapsed'
            } else {
                Hide-AllCollapsedBars
                Resume-WeatherEffects
            }
        } else {
            # 首次启动没有可恢复的用户状态，仅在此时执行常规停靠检测。
            Update-DockedState
        }
    }
    Apply-SeasonTheme
    Update-Quota
    if ($DemoWeather) { Show-NextWeatherDemo } else { Update-Weather }
})
$window.Add_Closed({
    if ($timer) { $timer.Stop() }
    if ($weatherTimer) { $weatherTimer.Stop() }
    if ($fxTimer) { $fxTimer.Stop() }
    if ($demoTimer) { $demoTimer.Stop() }
    if ($script:manualRefreshTimer) { $script:manualRefreshTimer.Stop() }
    if ($script:hideDelayTimer) { $script:hideDelayTimer.Stop() }
    if ($script:autoHideAnimationTimer) { $script:autoHideAnimationTimer.Stop() }
    if ($script:sideProgressTimer) { $script:sideProgressTimer.Stop() }
    Hide-AllCollapsedBars
    try { $collapsedBar.Close() } catch {}
    try { $sideCollapsedBar.Close() } catch {}
    Save-WindowState
    if ($mutex) { $mutex.ReleaseMutex(); $mutex.Dispose() }
})

if ($SmokeTest) {
    Apply-SeasonTheme
    if ($RootBorder.Effect -ne $null) { throw '主窗口仍包含外部阴影效果。' }
    if (-not $RefreshButton.IsEnabled -or [string]$RefreshButton.ToolTip -ne '立即刷新') { throw '立即刷新按钮初始状态自检失败。' }
    if ($window.ShowInTaskbar -or $collapsedBar.ShowInTaskbar -or $sideCollapsedBar.ShowInTaskbar) { throw '悬浮窗或折叠辅助窗口仍会显示在任务栏。' }
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
    $testWorkArea = [pscustomobject]@{ Left=0; Top=0; Right=1920; Bottom=1040 }
    $topHidden = Get-TopHiddenWindowPosition $testWorkArea 246 8 300
    if ($topHidden.Left -ne 300 -or $topHidden.Top -ne -238) { throw '顶部自动隐藏坐标自检失败。' }
    $window.Left = 0; $window.Top = 120
    $leftPosition = Test-DockedEdge $testWorkArea
    $window.Left = 1590; $window.Top = 120
    $rightPosition = Test-DockedEdge $testWorkArea
    $window.Left = 300; $window.Top = 0
    $topPosition = Test-DockedEdge $testWorkArea
    $window.Left = 0; $window.Top = 0
    $cornerPosition = Test-DockedEdge $testWorkArea
    # 任意程度的左右越界（含完全出屏）都属于有效停靠候选；
    # 展开和隐藏目标始终使用标准坐标。
    $window.Left = -24; $window.Top = 120
    $leftOvershootPosition = Test-DockedEdge $testWorkArea
    $leftExpanded = Get-DockedExpandedWindowPosition 'left' $testWorkArea
    $window.Left = 1614; $window.Top = 120
    $rightOvershootPosition = Test-DockedEdge $testWorkArea
    $rightExpanded = Get-DockedExpandedWindowPosition 'right' $testWorkArea
    $window.Left = -1000; $window.Top = 120
    $farLeftPosition = Test-DockedEdge $testWorkArea
    $farLeftOutside = Test-WindowFullyOutsideDockEdge 'left' $testWorkArea
    $window.Left = 10000; $window.Top = 120
    $farRightPosition = Test-DockedEdge $testWorkArea
    $farRightOutside = Test-WindowFullyOutsideDockEdge 'right' $testWorkArea
    if ($leftPosition -ne 'left' -or $rightPosition -ne 'right' -or $topPosition -ne 'top' -or $cornerPosition -ne 'top' -or
        $leftOvershootPosition -ne 'left' -or $rightOvershootPosition -ne 'right' -or $farLeftPosition -ne 'left' -or $farRightPosition -ne 'right' -or
        -not $farLeftOutside -or -not $farRightOutside -or
        $leftExpanded.Left -ne 0 -or $rightExpanded.Left -ne 1590) { throw '屏幕边缘停靠判断或越界容忍自检失败。' }
    $script:normalLeft = 0; $script:normalTop = 120
    $leftHidden = Get-DockedHiddenWindowPosition 'left' $testWorkArea
    $script:normalLeft = 1590; $script:normalTop = 120
    $rightHidden = Get-DockedHiddenWindowPosition 'right' $testWorkArea
    if ($leftHidden.Left -ne -330 -or $leftHidden.Top -ne 120 -or $rightHidden.Left -ne 1920 -or $rightHidden.Top -ne 120) { throw '左右自动隐藏坐标自检失败。' }
    $script:primaryUsed = 21; $script:secondaryUsed = 18
    $testLimits = [pscustomobject]@{
        primary = [pscustomobject]@{ resets_at=1781323440 }
        secondary = [pscustomobject]@{ resets_at=1781861460 }
    }
    Update-CollapsedBarText $testLimits
    if ($CollapsedText.Text -notlike '*Codex*' -or $CollapsedText.Text -notlike '*5小时剩余：79%*' -or $CollapsedText.Text -notlike '*本周剩余：82%*') { throw '折叠状态条额度同步自检失败。' }
    $script:dockEdge = 'left'
    $sideCollapsedBar.Width = 64; $sideCollapsedBar.Height = 180
    $sideCollapsedBar.Show(); $script:sideCollapsedBarVisible = $true
    Update-SideCollapsedBarVisual 0
    $labelAtZero = [System.Windows.Controls.Canvas]::GetTop($SidePercentText)
    $fillAtZero = [double]$SideFill.Height
    Update-SideCollapsedBarVisual 20
    $labelAtTwenty = [System.Windows.Controls.Canvas]::GetTop($SidePercentText)
    $fillAtTwenty = [double]$SideFill.Height
    Update-SideCollapsedBarVisual 50
    $labelAtHalf = [System.Windows.Controls.Canvas]::GetTop($SidePercentText)
    $fillAtHalf = [double]$SideFill.Height
    Update-SideCollapsedBarVisual 70
    $labelAtSeventy = [System.Windows.Controls.Canvas]::GetTop($SidePercentText)
    $fillAtSeventy = [double]$SideFill.Height
    $fillTopAtSeventy = [System.Windows.Controls.Canvas]::GetTop($SideTrack) + [double]$SideTrack.Height - $fillAtSeventy
    $labelBottomAtSeventy = $labelAtSeventy + [double]$SidePercentText.Height
    Update-SideCollapsedBarVisual 100
    $labelAtFull = [System.Windows.Controls.Canvas]::GetTop($SidePercentText)
    $fillAtFull = [double]$SideFill.Height
    Hide-SideCollapsedBar
    if ($sideCollapsedBar.FindName('SidePercentBadge') -ne $null -or $sideCollapsedBar.FindName('SideCollapsedBorder') -ne $null -or
        $SideTrack.Width -lt 30 -or $SideTrack.BorderThickness.Left -ne 0 -or [System.Windows.Controls.Panel]::GetZIndex($SidePercentText) -le [System.Windows.Controls.Panel]::GetZIndex($SideTrack) -or
        $fillAtZero -ne 0 -or $fillAtTwenty -le $fillAtZero -or $fillAtHalf -le $fillAtTwenty -or $fillAtSeventy -le $fillAtHalf -or $fillAtFull -le $fillAtSeventy -or
        $labelAtZero -le $labelAtTwenty -or $labelAtTwenty -le $labelAtHalf -or $labelAtHalf -le $labelAtSeventy -or $labelAtSeventy -le $labelAtFull -or
        $labelBottomAtSeventy -gt $fillTopAtSeventy -or
        $SidePercentText.Text -ne '100%') { throw '侧边块状进度条或百分比跟随位置自检失败。' }
    $hideCurve = Get-AutoHideEasedProgress 0.5 'collapsed'
    $showCurve = Get-AutoHideEasedProgress 0.5 'expanded'
    if ([Math]::Abs($hideCurve - 0.125) -gt 0.001 -or [Math]::Abs($showCurve - 0.875) -gt 0.001 -or (Get-AutoHideAnimationDuration 'collapsed') -lt 80 -or (Get-AutoHideAnimationDuration 'expanded') -lt 80) { throw '自动隐藏动画缓动自检失败。' }
    $originalStatePath = $script:statePath
    $script:statePath = Join-Path ([System.IO.Path]::GetTempPath()) ("CodexQuotaWidget-state-smoke-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    try {
        $restoreWorkArea = Get-WidgetWorkAreaForMonitorId ([System.Windows.Forms.Screen]::PrimaryScreen.DeviceName)
        $normalRestore = [ordered]@{ version=3; normalLeft=($restoreWorkArea.Left + 80); normalTop=($restoreWorkArea.Top + 100); monitorId=$restoreWorkArea.MonitorId; dockState='none'; displayState='expanded' }
        $normalRestore | ConvertTo-Json | Set-Content -LiteralPath $script:statePath -Encoding UTF8
        $script:normalLeft = $null; $script:normalTop = $null; $script:normalMonitorId = $null; $script:dockEdge = 'none'; $script:restoredWindowState = $null
        $readBack = Read-WindowState
        if ($null -eq $readBack) { throw ("状态文件读取自检失败: path={0}; exists={1}" -f $script:statePath,(Test-Path -LiteralPath $script:statePath)) }
        if (-not (Apply-RestoredWindowState) -or $script:dockEdge -ne 'none' -or $script:autoHideState -ne 'normal' -or [Math]::Abs($window.Left - ($restoreWorkArea.Left + 80)) -gt 0.1 -or [Math]::Abs($window.Top - ($restoreWorkArea.Top + 100)) -gt 0.1) { throw ("普通任意位置恢复自检失败: expected={0},{1}; actual={2},{3}; edge={4}; state={5}; monitor={6}" -f ($restoreWorkArea.Left + 80),($restoreWorkArea.Top + 100),$window.Left,$window.Top,$script:dockEdge,$script:autoHideState,$script:normalMonitorId) }

        # 保持旧 v2 状态文件可读取：其普通窗口仅保存 left/top，
        # 且没有可靠的显示器标识。
        $legacyNormalRestore = [ordered]@{ version=2; left=($restoreWorkArea.Left + 180); top=($restoreWorkArea.Top + 160); monitorId=$null; dockState='none'; displayState='expanded' }
        $legacyNormalRestore | ConvertTo-Json | Set-Content -LiteralPath $script:statePath -Encoding UTF8
        $script:normalLeft = $null; $script:normalTop = $null; $script:normalMonitorId = $null; $script:dockEdge = 'none'; $script:restoredWindowState = $null
        if (-not (Apply-RestoredWindowState) -or $script:dockEdge -ne 'none' -or $script:autoHideState -ne 'normal' -or [Math]::Abs($window.Left - ($restoreWorkArea.Left + 180)) -gt 0.1 -or [Math]::Abs($window.Top - ($restoreWorkArea.Top + 160)) -gt 0.1) { throw '旧版普通位置恢复自检失败。' }

        $legacyCollapsedRestore = [ordered]@{ version=2; left=($restoreWorkArea.Left + 120); top=($restoreWorkArea.Top + 140); monitorId=$null; dockState='left'; displayState='collapsed' }
        $legacyCollapsedRestore | ConvertTo-Json | Set-Content -LiteralPath $script:statePath -Encoding UTF8
        $script:normalLeft = $null; $script:normalTop = $null; $script:normalMonitorId = $null; $script:dockEdge = 'none'; $script:restoredWindowState = $null
        if (-not (Apply-RestoredWindowState) -or $script:dockEdge -ne 'left' -or $script:autoHideState -ne 'collapsed') { throw '旧版折叠状态恢复自检失败。' }

        foreach ($edge in @('top','left','right')) {
            $expandedRestore = [ordered]@{ version=3; normalLeft=($restoreWorkArea.Left + 120); normalTop=($restoreWorkArea.Top + 140); monitorId=$restoreWorkArea.MonitorId; dockState=$edge; displayState='expanded' }
            $expandedRestore | ConvertTo-Json | Set-Content -LiteralPath $script:statePath -Encoding UTF8
            $script:normalLeft = $null; $script:normalTop = $null; $script:normalMonitorId = $null; $script:dockEdge = 'none'; $script:restoredWindowState = $null
            $expectedExpanded = Get-NormalizedDockedPosition $edge $restoreWorkArea ($restoreWorkArea.Left + 120) ($restoreWorkArea.Top + 140)
            if (-not (Apply-RestoredWindowState) -or $script:dockEdge -ne $edge -or $script:autoHideState -ne 'expanded' -or [Math]::Abs($window.Left - $expectedExpanded.Left) -gt 0.1 -or [Math]::Abs($window.Top - $expectedExpanded.Top) -gt 0.1) { throw "${edge} 展开状态恢复自检失败。" }
        }

        foreach ($edge in @('top','left','right')) {
            $collapsedRestore = [ordered]@{ version=3; normalLeft=($restoreWorkArea.Left + 120); normalTop=($restoreWorkArea.Top + 140); monitorId=$restoreWorkArea.MonitorId; dockState=$edge; displayState='collapsed' }
            $collapsedRestore | ConvertTo-Json | Set-Content -LiteralPath $script:statePath -Encoding UTF8
            $script:normalLeft = $null; $script:normalTop = $null; $script:normalMonitorId = $null; $script:dockEdge = 'none'; $script:restoredWindowState = $null
            if (-not (Apply-RestoredWindowState) -or $script:dockEdge -ne $edge -or $script:autoHideState -ne 'collapsed' -or $script:restoredWindowState.DisplayState -ne 'collapsed') { throw "${edge} 折叠状态恢复自检失败。" }
            $expectedHidden = Get-DockedHiddenWindowPosition $edge $restoreWorkArea
            if ([Math]::Abs($window.Left - $expectedHidden.Left) -gt 0.1 -or [Math]::Abs($window.Top - $expectedHidden.Top) -gt 0.1) { throw "${edge} 折叠隐藏坐标恢复自检失败。" }
        }

        Set-Content -LiteralPath $script:statePath -Value '{invalid-json' -Encoding UTF8
        $invalidStateWasRejected = $false
        try { [void](Read-WindowState) } catch { $invalidStateWasRejected = $true }
        if (-not $invalidStateWasRejected) { throw '损坏状态文件自检失败。' }
    } finally {
        Remove-Item -LiteralPath $script:statePath -Force -ErrorAction SilentlyContinue
        $script:statePath = $originalStatePath
    }
    "UI_OK controls=$($names.Count) remaining_bar=$([Math]::Round($remainingRatio*100))% modes=$modeResults dock_state=unified(top,left,right) unlimited_side_overshoot=OK side_progress=OK animation=OK state_restore=OK legacy_state=OK"
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
