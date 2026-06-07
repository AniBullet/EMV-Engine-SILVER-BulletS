@echo off
setlocal
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-MHWilds.ps1" install -Force
set "CODE=%ERRORLEVEL%"
echo.
if not "%CODE%"=="0" (
	echo Install failed. You can also run:
	echo powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-MHWilds.ps1" install -GameDir "PATH_TO_MONSTER_HUNTER_WILDS" -Force
) else (
	echo Install finished.
)
pause
exit /b %CODE%
