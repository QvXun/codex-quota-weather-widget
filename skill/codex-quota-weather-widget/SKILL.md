---
name: codex-quota-weather-widget
description: Install, configure, launch, preview, update, or uninstall a Windows floating Codex quota widget with seasonal themes and live weather effects. Use when a user asks for a Codex quota HUD, usage monitor, weather widget, location change, auto-start setup, weather-effect preview, or removal of this widget.
---

# Codex Quota Weather Widget

Install and manage the bundled Windows widget without reading Codex credentials or inferring the user's location.

## Privacy rules

- Never read `.codex/auth.json` or any login token.
- Never infer location from IP, system location services, files, memory, timezone, account data, or prior conversation details.
- Ask the user to type a city, district, or similarly broad region before the first weather-enabled install.
- If the user provides a precise address, ask for a broader region and do not repeat or persist the address.
- Resolve only an administrative-area center coordinate, show the resolved region and coordinates, and obtain confirmation before writing them.
- Explain that weather requests send the confirmed coordinates to Open-Meteo and naturally expose the connection IP to that service.
- Keep weather enabled by default. If the user declines to provide a region, offer installation with weather disabled; never silently choose a default location.

## Install or update

1. Confirm the operating system is Windows. Stop with a clear explanation on other platforms.
2. Ask for a city, district, or broad region when no confirmed widget configuration exists.
3. Resolve the region center using a reputable geocoding source. If results are ambiguous, ask the user to select the intended region.
4. Show the region name, latitude, and longitude. Wait for explicit confirmation.
5. Ask whether to launch automatically at Windows sign-in. Recommend yes but do not assume consent.
6. Run `scripts/install.ps1` with the confirmed region and coordinates. Add `-EnableAutoStart` only after consent.
7. Report the install directory and launch result. Do not expose unrelated local paths.

Example:

```powershell
& "<skill-dir>\scripts\install.ps1" -LocationName "<confirmed region>" -Latitude <latitude> -Longitude <longitude> -EnableAutoStart
```

The installer copies only files from `assets/widget` to `%LOCALAPPDATA%\CodexQuotaWeatherWidget` and creates a Start Menu shortcut. It does not modify Codex itself.

## Change weather location

Ask for a new broad region, resolve and confirm its center coordinates, then run:

```powershell
& "<skill-dir>\scripts\configure-location.ps1" -LocationName "<confirmed region>" -Latitude <latitude> -Longitude <longitude> -Restart
```

## Launch and preview

- Normal widget: run `%LOCALAPPDATA%\CodexQuotaWeatherWidget\CodexQuotaWidget.vbs` with `wscript.exe`.
- Weather demo: start `CodexQuotaWidget.ps1 -DemoWeather` from the install directory.
- The demo uses synthetic effects and must remain visibly marked `DEMO`.

## Uninstall

Explain that uninstall removes the widget, its local configuration, cached weather, saved window position, and shortcuts. Obtain confirmation, then run `scripts/uninstall.ps1`.

## Data boundaries

The widget scans recent local Codex session tails and parses only `event_msg -> token_count -> rate_limits` metadata. It does not parse, display, store, or transmit ordinary conversation lines. Its only external request is the Open-Meteo forecast request when weather is enabled. No telemetry or analytics endpoints are included.

