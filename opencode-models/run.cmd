@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0set-opencode-models.ps1" -NoPause %*
echo.
echo Press any key to exit . . .
pause >nul
