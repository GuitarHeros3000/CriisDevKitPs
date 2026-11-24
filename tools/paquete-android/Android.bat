@echo off
rem Punto de entrada del paquete de Android de CriisDevKit: doble clic aqui.
rem Sin pause al final: el menu ya espera entre opciones, y al salir con q
rem se cierra la ventana como se espera de un menu.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\kit\Menu-Android.ps1" %*
exit /b %ERRORLEVEL%
