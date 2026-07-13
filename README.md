# Codex Quota Weather Widget

一个非官方、开源的 Windows Codex Skill：安装可拖动的额度悬浮窗，并根据实时天气与四季显示不同效果。

## 功能

- 根据 Codex 返回的 `window_minutes` 动态显示额度周期；支持单额度或双额度布局，深色剩余条位于左侧。
- 四季主题配色，以及花瓣、萤火、落叶等环境装饰。
- 只有天气数据确实为降雨、雾、雪或雷暴时，才显示对应效果。
- 窗口置顶、可拖动并记住位置。
- 自带与正式界面一致、明确标注 `DEMO` 的天气效果演示。
- 不读取 `auth.json`，不保存 token，不包含遥测或分析服务。

## 用 Codex 安装

把下面这句话发给 Codex 即可：

```text
请从 https://github.com/QvXun/codex-quota-weather-widget/tree/main/skill/codex-quota-weather-widget 安装 Skill，并使用 $codex-quota-weather-widget 为我安装额度天气悬浮窗。
```

Skill 会询问你愿意提供的城市、区县或较宽泛地区，只解析其行政区域中心坐标，显示结果并等待确认；还会询问是否开机自启动。请不要在公开 Issue 中填写精确住址。

Skill 不得通过 IP、Windows 定位、文件、时区、账户资料或历史对话推断位置。如果不愿提供地区，可以关闭天气后继续安装。

## 隐私边界

- 仅扫描本机 Codex 会话文件尾部，并只解析 `event_msg -> token_count -> rate_limits` 额度元数据。
- 普通对话行不会被解析、显示、保存或发送。
- 不读取 `.codex/auth.json` 或任何登录 token。
- 不包含分析或遥测端点。
- 天气开启时，只把用户确认的区域中心坐标发送给 Open-Meteo。
- 配置、天气缓存与窗口位置仅保存在 `%LOCALAPPDATA%\CodexQuotaWeatherWidget`。

## 系统要求

- Windows 10 或更高版本。
- Codex 已在本机产生额度元数据。
- Windows PowerShell 5.1 或更高版本。

## 天气数据

天气由 [Open-Meteo](https://open-meteo.com/) 提供，无需申请 API Key，数据按 CC BY 4.0 使用。其免费接口面向非商业用途，不承诺永久可用、准确率或服务稳定性；详见 [Open-Meteo 条款](https://open-meteo.com/en/terms)与[价格说明](https://open-meteo.com/en/pricing)。普通网络请求也会向服务方暴露连接 IP。

## 说明与许可

本项目是社区作品，与 OpenAI 没有隶属或背书关系。天气仅作装饰与一般信息展示，不应用于应急或安全决策。项目源码采用 MIT License，第三方数据仍遵循其各自条款。

---

Unofficial open-source Windows Skill for a draggable Codex quota HUD with live weather and seasonal effects. See the sections above for installation, privacy boundaries, and third-party terms.
