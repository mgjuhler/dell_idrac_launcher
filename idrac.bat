@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0idrac.ps1" %*
if errorlevel 1 pause
