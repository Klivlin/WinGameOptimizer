@echo off
rem WinGameOptimizer launcher: fixes file encoding (UTF-8 BOM) and starts the script (it asks for admin rights itself).
chcp 65001 >nul
set "WGO_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=Join-Path $env:WGO_DIR 'WinGameOptimizer.ps1'; $t=[IO.File]::ReadAllText($p,[Text.Encoding]::UTF8); [IO.File]::WriteAllText($p,$t,(New-Object Text.UTF8Encoding $true))"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinGameOptimizer.ps1"
