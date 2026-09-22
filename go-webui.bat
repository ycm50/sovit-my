@echo off
setlocal
chcp 65001 >nul
set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
cd /d "%ROOT%"

if exist "%ROOT%\.venv\Scripts\python.exe" goto use_venv
if exist "%ROOT%\runtime\python.exe" goto use_runtime

echo No usable Python interpreter found.
echo   A. Manual install: run "pwsh -File install.ps1" first (installs into .venv).
echo   B. Official bundle: put the runtime directory at the repository root.
set "EXITCODE=1"
goto finish

:use_venv
echo Using .venv ...
"%ROOT%\.venv\Scripts\python.exe" "%ROOT%\webui.py" zh_CN
set "EXITCODE=%ERRORLEVEL%"
goto finish

:use_runtime
echo Using bundled runtime ...
set "PATH=%ROOT%\runtime;%PATH%"
"%ROOT%\runtime\python.exe" -I "%ROOT%\webui.py" zh_CN
set "EXITCODE=%ERRORLEVEL%"
goto finish

:finish
if not "%EXITCODE%"=="0" echo Exit code: %EXITCODE%
pause
exit /b %EXITCODE%
