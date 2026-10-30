@echo off
rem ==========================================================================
rem run_all.bat : full Phase 0 regression with one command.
rem
rem   scripts\run_all.bat           vectors + all simulations + all syntheses
rem   scripts\run_all.bat sim       vectors + all simulations only
rem
rem 1. Regenerates the test vectors with the Python golden model
rem    (needs the project venv: see docs\how_to_test.md, section F).
rem 2. Runs every self-checking testbench (scripts\run.bat <module> sim).
rem 3. Synthesizes every core for xc7a35tcpg236-1 at 100 MHz.
rem Prints one PASS/FAIL line per step and a summary; the full output of
rem each step is in build\run_all\<step>.txt. Exit code 0 = all passed.
rem ==========================================================================
setlocal enabledelayedexpansion
for %%I in ("%~dp0..") do set "ROOT=%%~fI"
set "OUT=%ROOT%\build\run_all"
if not exist "%OUT%" mkdir "%OUT%"
set FAILS=0
set "PY=%ROOT%\.venv\Scripts\python.exe"

set "SIMS=aes_sbox aes128_core ghash aes_gcm motion_detect ro_puf puf_debias fuzzy_extractor puf_hash puf_keygen trng_health ro_trng session_kdf hello_fsm"
set "SYNTHS=aes128_core ghash aes_gcm motion_detect puf_keygen ro_trng trng_health session_kdf hello_fsm"

echo ===== Test vectors (Python golden model) =====
if exist "%PY%" (
    for %%G in (gen_gcm_vectors gen_ghash_vectors gen_puf_vectors gen_session_vectors) do (
        "%PY%" "%ROOT%\model\%%G.py" > "%OUT%\%%G.txt" 2>&1
        if errorlevel 1 (
            echo FAIL  %%G   ^(see build\run_all\%%G.txt^)
            set /a FAILS+=1
        ) else (
            echo PASS  %%G
        )
    )
) else (
    echo SKIP  Python venv not found: using the vectors already in model\vectors
)

echo ===== Simulations =====
for %%M in (%SIMS%) do (
    call "%ROOT%\scripts\run.bat" %%M sim > "%OUT%\sim_%%M.txt" 2>&1
    if errorlevel 1 (
        echo FAIL  sim   %%M   ^(see build\run_all\sim_%%M.txt^)
        set /a FAILS+=1
    ) else (
        echo PASS  sim   %%M
    )
)

if /i "%~1"=="sim" goto summary

echo ===== Synthesis (xc7a35tcpg236-1, 100 MHz) =====
for %%M in (%SYNTHS%) do (
    call "%ROOT%\scripts\run.bat" %%M synth > "%OUT%\synth_%%M.txt" 2>&1
    if errorlevel 1 (
        echo FAIL  synth %%M   ^(see build\run_all\synth_%%M.txt^)
        set /a FAILS+=1
    ) else (
        for /f "tokens=2,3" %%A in ('findstr /b /c:"LUTs" "%ROOT%\build\synth\%%M\summary.txt"') do set "LUT=%%A"
        for /f "tokens=2" %%A in ('findstr /b /c:"BRAM36" "%ROOT%\build\synth\%%M\summary.txt"') do set "BRAM=%%A"
        for /f "tokens=6" %%A in ('findstr /b /c:"Timing" "%ROOT%\build\synth\%%M\summary.txt"') do set "WNS=%%A"
        echo PASS  synth %%M   LUTs !LUT!  BRAM36 !BRAM!  WNS !WNS! ns
    )
)

:summary
echo =====
if %FAILS%==0 (
    echo *** ALL PASSED ***
    exit /b 0
)
echo *** %FAILS% STEP^(S^) FAILED ***
exit /b 1
