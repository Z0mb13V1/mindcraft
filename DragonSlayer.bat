@echo off
title DragonSlayer v4.0 — Mindcraft Launcher
color 0C
echo.
echo   ========================================
echo     DragonSlayer Launcher v4.0
echo   ========================================
echo.

:: Run the PowerShell script from the same directory as this .bat
:: -ExecutionPolicy Bypass  = no admin required, no policy changes
:: -NoProfile               = skip user PS profile for clean startup
:: -File                    = run the .ps1 script

powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%~dp0DragonSlayer-Launcher.ps1"

:: If PowerShell isn't available (very old Win), show error
if errorlevel 9009 (
    echo.
    echo   ERROR: PowerShell not found!
    echo   Install PowerShell: https://aka.ms/powershell
    echo.
    pause
)
