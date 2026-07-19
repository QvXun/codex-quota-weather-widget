' 用户主动双击此文件时，以无控制台方式启动同目录的 DEMO 悬浮窗。
' 不下载、不提权、不修改系统执行策略，也不会创建自启动项。
Option Explicit

Dim shell, fileSystem, scriptDirectory, command
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & scriptDirectory & "\CodexQuotaWidget.ps1"" -DemoMode"
shell.Run command, 0, False
