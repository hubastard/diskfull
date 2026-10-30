@echo off
setlocal
rem Builds diskfull.exe (no console window).

rem Version from git: "0.1.1" on a release tag, "0.1.1-3-gabc1234" after it.
set VERSION=dev
for /f %%v in ('git describe --tags --always --dirty 2^>nul') do set VERSION=%%v
if "%VERSION:~0,1%"=="v" set VERSION=%VERSION:~1%

odin build src -o:speed -out:diskfull.exe -subsystem:windows -define:VERSION=%VERSION% || exit /b 1
echo Built diskfull.exe %VERSION%
