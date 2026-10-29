@echo off
rem Test double for the Azure CLI. It contacts nothing and prints synthetic data; FAKE_AZ_MODE selects the behavior.
if "%FAKE_AZ_MODE%"=="fail" exit /b 3
if "%FAKE_AZ_MODE%"=="slow" goto slow
if "%FAKE_AZ_MODE%"=="empty" goto empty
if "%FAKE_AZ_MODE%"=="args" goto args
echo {"accessToken":"fixture-cli-token","tokenType":"Bearer"}
exit /b 0
:slow
rem ping waits about a second per count; unlike the timeout command it needs no console.
ping -n 8 127.0.0.1 >nul
echo {"accessToken":"too-late-token"}
exit /b 0
:empty
echo {"accessToken":""}
exit /b 0
:args
rem Some launchers quote every argument; drop the quotes so the output stays valid JSON.
set ARGS=%*
set ARGS=%ARGS:"=%
echo {"accessToken":"%ARGS%"}
exit /b 0
