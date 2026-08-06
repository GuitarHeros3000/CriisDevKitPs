@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\Start-JavaEnv.ps1" %*

rem El codigo de salida se guarda ANTES del pause. El de un .bat es el del
rem ultimo comando ejecutado, y pause devuelve 0 siempre, asi que el del
rem script se perdia: Doctor-Env sale con 1 si encuentra algo grave y no
rem habia forma de enterarse desde fuera.
rem Para encadenar este .bat desde otro script define ASSASSINSKIPADM_NOPAUSE
rem y no se detendra a esperar una tecla.
set "RC=%ERRORLEVEL%"
if not defined ASSASSINSKIPADM_NOPAUSE pause
exit /b %RC%
