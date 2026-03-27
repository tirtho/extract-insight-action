@echo off
REM =============================================================================
REM Configuration for extract-insight-action Infrastructure Deployment (DOS/CMD)
REM
REM Reads variables from env.config and sets them in the current session.
REM Run this before deployment scripts:
REM   config.cmd
REM   deploy-infrastructure.cmd
REM =============================================================================

if not exist "%~dp0env.config" (
    echo [ERROR] env.config not found in %~dp0
    exit /b 1
)

for /f "usebackq tokens=1,* delims==" %%A in ("%~dp0env.config") do (
    set "%%A=%%~B"
)

echo [INFO] Environment variables loaded from env.config