@echo off
rem ==========================================================================
rem run.bat : simulate + synthesize one module with one command.
rem
rem   scripts\run.bat aes128_core          simulation and synthesis
rem   scripts\run.bat aes128_core sim      simulation only
rem   scripts\run.bat aes128_core synth    synthesis only
rem
rem Vivado: VIVADO_BIN if set, else the default 2026.1 install path.
rem Work files: ROVER_BUILD if set, else %LOCALAPPDATA%\rover_fpga_build
rem (outside OneDrive; Vivado implementation fails inside a synced folder).
rem Logs and reports are copied to build\ in the project.
rem Exit code 0 = everything passed.
rem ==========================================================================
setlocal
if "%VIVADO_BIN%"=="" set "VIVADO_BIN=C:\AMDDesignTools\2026.1\Vivado\bin"
if "%ROVER_BUILD%"=="" set "ROVER_BUILD=%LOCALAPPDATA%\rover_fpga_build"
set "MOD=%~1"
set "WHAT=%~2"
if "%MOD%"=="" set "MOD=aes128_core"
if "%WHAT%"=="" set "WHAT=all"

if not exist "%VIVADO_BIN%\vivado.bat" (
    echo ERROR: Vivado not found in %VIVADO_BIN%
    echo Set VIVADO_BIN to your Vivado\bin folder.
    exit /b 1
)
set "PATH=%VIVADO_BIN%;%PATH%"
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
if not exist "%ROOT%\build" mkdir "%ROOT%\build"
if not exist "%ROVER_BUILD%" mkdir "%ROVER_BUILD%"
cd /d "%ROVER_BUILD%"

if /i "%WHAT%"=="synth" goto synth
del /q "%ROOT%\build\sim_%MOD%*.log" 2>nul
call vivado.bat -mode batch -nojournal -log "%ROOT%\build\sim_%MOD%.log" -source "%ROOT%\scripts\sim.tcl" -tclargs %MOD%
if errorlevel 1 (
    echo.
    echo *** SIMULATION FAILED: see build\sim_%MOD%.log ***
    exit /b 1
)
if /i "%WHAT%"=="sim" goto ok

:synth
del /q "%ROOT%\build\synth_%MOD%*.log" 2>nul
call vivado.bat -mode batch -nojournal -log "%ROOT%\build\synth_%MOD%.log" -source "%ROOT%\scripts\synth.tcl" -tclargs %MOD%
if not errorlevel 1 goto synth_ok
rem Windows sometimes locks Vivado's temp folder (error Designutils 20-411): retry once
findstr /c:"20-411" "%ROOT%\build\synth_%MOD%.log" >nul || goto synth_fail
echo Vivado temp folder was locked; retrying synthesis once...
del /q "%ROOT%\build\synth_%MOD%*.log" 2>nul
call vivado.bat -mode batch -nojournal -log "%ROOT%\build\synth_%MOD%.log" -source "%ROOT%\scripts\synth.tcl" -tclargs %MOD%
if not errorlevel 1 goto synth_ok
:synth_fail
echo.
echo *** SYNTHESIS FAILED: see build\synth_%MOD%.log ***
exit /b 1
:synth_ok
type "%ROOT%\build\synth\%MOD%\summary.txt"

:ok
echo.
echo *** %MOD%: ALL CHECKS PASSED ***
exit /b 0
