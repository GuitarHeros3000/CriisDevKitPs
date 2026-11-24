@echo off
echo ============================================
echo   Start-AndroidLog
echo   Lo que escribe tu app en el telefono
echo ============================================
echo.
powershell -ExecutionPolicy Bypass -File "%~dp0..\..\scripts\start\Start-AndroidLog.ps1" %*

rem El codigo de salida se guarda ANTES del pause. El de un .bat es el del
rem ultimo comando ejecutado, y pause devuelve 0 siempre, asi que el del
rem script se perdia.
rem Para encadenar este .bat desde otro script define CRIISDEVKIT_NOPAUSE
rem y no se detendra a esperar una tecla.
set "RC=%ERRORLEVEL%"
if not defined CRIISDEVKIT_NOPAUSE pause
exit /b %RC%
