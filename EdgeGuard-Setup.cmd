@echo off
REM EdgeGuard setup launcher. ASCII-only to avoid Windows codepage issues.
setlocal
cd /d "%~dp0"

net session >nul 2>&1
if errorlevel 1 (
  echo Requesting administrator privileges...
  powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

:MENU
cls
echo ============================================================
echo  EdgeGuard - remove Edge at Windows startup
echo.
echo  At logon: if Edge is installed, remove it silently and exit.
echo            if Edge is absent, do nothing and exit.
echo.
echo  NOTE: this creates a scheduled task and writes a log.
echo        See README-ja.md for full details and how to undo it.
echo ============================================================
echo.
echo  [1] Install (at logon only)
echo  [2] Install (at logon + every 30 minutes)
echo  [3] Uninstall (remove task and installed files)
echo  [4] Status
echo  [5] Show log
echo  [0] Exit
echo.
set "SEL="
set /p "SEL=Select [0-5]: "

if "%SEL%"=="1" goto INSTALL
if "%SEL%"=="2" goto INSTALL_REPEAT
if "%SEL%"=="3" goto UNINSTALL
if "%SEL%"=="4" goto STATUS
if "%SEL%"=="5" goto LOG
if "%SEL%"=="0" exit /b
echo Invalid selection.
timeout /t 2 >nul
goto MENU

:INSTALL
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Setup-EdgeGuard.ps1" -Install
goto MENU

:INSTALL_REPEAT
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Setup-EdgeGuard.ps1" -Install -WithPeriodicCheck
goto MENU

:UNINSTALL
echo.
echo This removes the scheduled task and installed files.
set "CONF="
set /p "CONF=Type YES to continue: "
if /i not "%CONF%"=="YES" goto MENU
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Setup-EdgeGuard.ps1" -Uninstall
goto MENU

:STATUS
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\Setup-EdgeGuard.ps1" -Status
goto MENU

:LOG
cls
echo === C:\ProgramData\EdgeGuard\edgeguard.log ===
if exist "%ProgramData%\EdgeGuard\edgeguard.log" (
  type "%ProgramData%\EdgeGuard\edgeguard.log"
) else (
  echo No log file yet.
)
echo.
pause
goto MENU
