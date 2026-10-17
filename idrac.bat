@echo off
setlocal
rem Dell iDRAC KVM launcher - see README.txt
if not exist "%~dp0idrac.ps1" (
    echo.
    echo idrac.ps1 blev ikke fundet ved siden af idrac.bat.
    echo Hoejreklik paa zip-filen, vaelg "Udpak alle", og start idrac.bat fra den udpakkede mappe.
    echo.
    pause
    exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0idrac.ps1" %*
if errorlevel 1 pause
