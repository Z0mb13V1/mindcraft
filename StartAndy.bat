@echo off
title Andy Minecraft Bot
color 0A

:: Set working directory to the folder containing this script
cd /d "%~dp0"

:: Check if node_modules exists, if not, install dependencies
if not exist "node_modules\" (
    echo Installing dependencies...
    call npm install
    echo.
)

:loop
cls
echo =====================================================
echo    STARTING Bot
echo =====================================================
echo.

:: Use npm start to automatically find the correct main file
call npm start

:: If the bot crashes, show the error code and wait
echo.
echo =====================================================
echo    WARNING: Andy crashed or stopped!
echo    Exit Code: %ERRORLEVEL%
echo.
echo    Restarting in 10 seconds...
echo    (Press Ctrl+C to quit fully)
echo =====================================================

timeout /t 10 >nul
goto loop