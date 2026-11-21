@echo off
rem Starts Startup Manager from the script, without a console window. The execution-policy
rem bypass applies to this run only; no Windows settings are changed.
rem If it doesn't open, run   "Start Startup Manager.cmd" debug   to keep a console and see what it prints.
if /i "%~1"=="debug" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0src\Startup-Manager.ps1"
    pause
) else (
    start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0src\Startup-Manager.ps1"
)
