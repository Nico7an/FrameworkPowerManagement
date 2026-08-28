@echo off
setlocal
cd /d "%~dp0"

echo  Framework Charge Tray - installation
echo  ------------------------------------
echo.
echo  Une invite Windows va demander l elevation :
echo  framework_tool doit parler a l Embedded Controller.
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"

echo.
echo  Termine. Cherche l icone batterie dans la zone de
echo  notification (chevron ^^ si elle est masquee).
echo.
pause
