@echo off
title Lumina Studio Dev Launcher
echo ========================================
echo   Lumina Studio 2.0 - Dev Launcher
echo ========================================
echo.
echo Launching via Python...
python3 start_dev.py %*
if errorlevel 1 (
    echo python3 not found, trying python...
    python start_dev.py %*
)
