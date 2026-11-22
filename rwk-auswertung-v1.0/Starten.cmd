@echo off
rem Starts the Rundenwettkampf Auswertung without a visible window:
rem icon in the notification area (bottom right) and the control page in the default browser.
rem The TV display is opened from the tray menu or the control page when needed.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1" -Launch
