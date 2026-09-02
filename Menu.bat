@echo off
rem Punto de entrada del kit: doble clic aqui y sale el menu con todo.
rem Sin pause al final: el menu ya se encarga de esperar entre opciones, y al
rem salir con 'q' se cierra la ventana como se espera de un menu.
powershell -ExecutionPolicy Bypass -File "%~dp0scripts\Menu.ps1" %*
exit /b %ERRORLEVEL%
