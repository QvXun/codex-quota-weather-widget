# Quota Weather Widget（公开审查副本）

这是一个面向 Windows 的 PowerShell + WPF 悬浮窗示例。它显示额度摘要、可选天气信息，并提供顶部、左侧和右侧的屏幕边缘折叠交互。

> 重要：本副本默认使用 DEMO 数据。它不读取 auth.json，不保存 Token，也不包含遥测或分析服务。

## 当前许可状态

本地审查时没有发现可验证的上游许可证。根目录 LICENSE 是许可状态声明，不是开源授权。因此在补齐上游许可证、版权归属和第三方资源许可前，**暂不建议公开上传或分发**。

## 功能

- 5 小时和 7 天额度摘要、进度条、重置时间、立即刷新与自动刷新。
- 顶部、左侧、右侧屏幕边缘吸附、延迟隐藏、折叠条唤出和可反向平滑动画。
- 顶部横向额度摘要；左右竖向 5 小时剩余进度，数字跟随填充端点。
- 任意普通位置与三种边缘的展开/折叠状态恢复。
- 多显示器、负坐标显示器与 Windows DPI 缩放处理。
- 可选天气、四季主题及由实时天气决定的雨、雾、雪、雷暴效果。
- 无任务栏常驻图标、圆角透明窗口、置顶与拖动。

实际新增或完善的功能简表见 新增功能简介.md。

## 系统要求

- Windows 10 或更高版本。
- Windows PowerShell 5.1。
- Windows 自带 WPF / .NET 桌面组件。

不需要安装 Node.js、Python、浏览器扩展或第三方遥测 SDK。

## 安全 DEMO 启动

推荐双击 启动-DEMO.vbs。它只启动同目录的 CodexQuotaWidget.ps1，并使用无控制台窗口方式运行。

也可以在 Windows PowerShell 中手动执行：

    powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\CodexQuotaWidget.ps1 -DemoMode

这里的 ExecutionPolicy 参数只作用于本次进程，不会修改系统或用户级执行策略。DEMO 界面会显示 DEMO 标识，额度和重置时间均为虚构数据。

## 本地自检

在仓库目录运行：

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\CodexQuotaWidget.ps1 -Test
    powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File .\CodexQuotaWidget.ps1 -SmokeTest

第一个命令验证默认 DEMO 数据提供器，第二个命令执行 WPF 界面与停靠逻辑自检。两者都不需要认证文件或真实位置。

## 额度数据提供器

默认：

    QBS_DEMO_MODE=true
    QBS_QUOTA_PROVIDER=demo

若用户明确希望使用本机 Codex 会话中的额度元数据，可在当前 PowerShell 会话中设置：

    $env:QBS_DEMO_MODE = 'false'
    $env:QBS_QUOTA_PROVIDER = 'session'

session 模式只查找本机会话目录中的 token_count/rate_limits 元数据，不读取认证文件、Token、Cookie 或会话正文；不会把额度发送到网络。没有可用额度元数据时，界面会提示错误而不会读取其他凭据。

## 可选天气配置

天气默认关闭，避免在未配置前产生网络请求。要启用天气，请仅在本机环境变量中填写自己的值：

    $env:QBS_WEATHER_ENABLED = 'true'
    $env:QBS_LOCATION_NAME = 'YOUR_LOCATION_NAME'
    $env:QBS_LATITUDE = 'YOUR_LATITUDE'
    $env:QBS_LONGITUDE = 'YOUR_LONGITUDE'

程序只会在天气已启用且经纬度有效时请求 Open-Meteo。请求会发送经纬度，服务端也自然可见网络连接 IP；不会发送 Codex 登录信息、额度、Token、本机用户名或文件路径。

.env.example 只是变量说明，程序不会自动加载 .env。请勿把真实 .env、本地配置或截图提交到 Git。

## 本地数据与清理

程序把以下运行时文件写入当前用户的本地应用数据目录 QuotaWeatherWidgetQBS：

- widget-config.json：天气和界面配置。
- widget-state.json：窗口位置、显示器、停靠边缘与展开/折叠状态。
- weather-cache.json：可选天气缓存。

这些文件不会写入仓库，已被 .gitignore 排除。删除该本地目录即可移除这些运行时数据。

## 网络与隐私

- 默认 DEMO 模式不发起天气网络请求。
- 启用天气后，唯一预期网络端点是 api.open-meteo.com。
- 不含遥测、分析、广告、崩溃自动上传、远程控制、自动下载更新或本地监听端口。
- 不读取 auth.json，不保存 Token，不要求用户把凭据放进仓库。

详细说明见 PRIVACY.md 和 SECURITY.md。

## Windows 登录自启动

公开副本不会自动创建登录自启动项。若要自行配置，请使用 Windows 的常规“启动”文件夹或任务计划界面，并确保启动命令只指向自己审查过的本地启动器。取消自启动只需删除对应的本地快捷方式或任务。

## 卸载

关闭悬浮窗后，删除该仓库目录以及本地应用数据目录 QuotaWeatherWidgetQBS 即可。若用户手动创建过登录自启动项，也应一并删除。

## 发布前检查

1. 确认并补齐上游 LICENSE、版权和第三方资源许可。
2. 检查 git status 与 git diff --cached。
3. 确保没有 .env、窗口状态、日志、缓存、截图、构建产物或本机路径。
4. 在本地运行秘密扫描；不要把源码上传到在线扫描站点。
5. 仅在许可证与隐私审查全部通过后，再由仓库所有者手动添加远程地址并上传。
