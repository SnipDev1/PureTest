@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo ============================================================
echo   Compiling and running CPU CheckMate Benchmark on Windows
echo   Optimizations: /O2 /Oi /Ot /Oy /arch:AVX2 /EHsc /std:c++17
echo ============================================================

set "VCVARS="
if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" (
    set "VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
)
if not defined VCVARS if exist "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" (
    set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
)
if not defined VCVARS if exist "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat" (
    set "VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Auxiliary\Build\vcvars64.bat"
)
if not defined VCVARS if exist "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat" (
    set "VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat"
)

if not defined VCVARS (
    echo [ERROR] MSVC environment ^(vcvars64.bat^) not found.
    pause
    exit /b 1
)

call "!VCVARS!" >nul 2>&1

echo [1/2] Compiling checkmate.cpp with AVX-512 and AVX2 support...
cl.exe /nologo /O2 /Oi /Ot /Oy /arch:AVX2 /EHsc /std:c++17 checkmate.cpp /Fe:checkmate.exe

if errorlevel 1 (
    echo [ERROR] Compilation failed.
    pause
    exit /b 1
)

echo.
echo [2/2] Running checkmate.exe (output saved to out.txt)...
echo.
powershell -NoProfile -Command ".\checkmate.exe | Tee-Object -FilePath out.txt"

echo.
pause
