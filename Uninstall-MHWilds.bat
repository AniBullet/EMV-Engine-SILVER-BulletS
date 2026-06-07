@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-MHWilds.ps1" uninstall -Force
set "CODE=%ERRORLEVEL%"
echo.
if not "%CODE%"=="0" (
	echo Uninstall failed. You can also run:
	echo powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-MHWilds.ps1" uninstall -GameDir "PATH_TO_MONSTER_HUNTER_WILDS" -Force
) else (
	echo Uninstall finished.
)
pause
exit /b %CODE%
