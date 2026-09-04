@echo off
REM =============================================================================
REM Configuration for extract-insight-action Infrastructure Deployment (DOS/CMD)
REM
REM Reads variables from a selected config file (default: env.config) and sets them in the current session.
REM Run this before deployment scripts:
REM   config.cmd
REM   deploy-infrastructure.cmd
REM =============================================================================

set "DEFAULT_CONFIG_FILE_NAME=env.config"
set /p "CONFIG_FILE_NAME=Enter config file name [%DEFAULT_CONFIG_FILE_NAME%]: "
if "%CONFIG_FILE_NAME%"=="" set "CONFIG_FILE_NAME=%DEFAULT_CONFIG_FILE_NAME%"

set "CONFIG_FILE=%CONFIG_FILE_NAME%"
if not exist "%CONFIG_FILE%" set "CONFIG_FILE=%~dp0%CONFIG_FILE_NAME%"

if not exist "%CONFIG_FILE%" (
    echo [ERROR] Config file '%CONFIG_FILE_NAME%' not found at %CONFIG_FILE%
    exit /b 1
)

for /f "usebackq tokens=1,* delims==" %%A in ("%CONFIG_FILE%") do (
    set "%%A=%%~B"
)

echo [INFO] Environment variables loaded from %CONFIG_FILE_NAME%