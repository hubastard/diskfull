@echo off
rem Builds diskfull.exe (no console window).
odin build src -o:speed -out:diskfull.exe -subsystem:windows || exit /b 1
echo Built diskfull.exe
