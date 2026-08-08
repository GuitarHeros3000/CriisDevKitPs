@echo off
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\Update-Env.ps1" %*

rem El codigo de salida se guarda ANTES del pause. Aqui importa: 1 significa
rem que hay actualizaciones disponibles, no que haya fallado nada.
rem Para encadenar este .bat desde otro script define ASSASSINSKIPADM_NOPAUSE
rem y no se detendra a esperar una tecla.
set "RC=%ERRORLEVEL%"
if not defined ASSASSINSKIPADM_NOPAUSE pause
exit /b %RC%
