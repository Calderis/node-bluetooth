@echo off
setlocal

:: Default paths - adjust if your SDK version differs
set "SDK_VER=10.0.19041.0"
set "WINMD_PATH=C:\Program Files (x86)\Windows Kits\10\UnionMetadata\%SDK_VER%\Windows.winmd"
set "RUNTIME_PATH=C:\Program Files (x86)\Reference Assemblies\Microsoft\Framework\.NETCore\v4.5\System.Runtime.WindowsRuntime.dll"

echo Checking for Windows SDK at %WINMD_PATH%...

if not exist "%WINMD_PATH%" (
    echo [ERROR] Windows.winmd not found.
    echo Please check your Windows SDK version in "C:\Program Files (x86)\Windows Kits\10\UnionMetadata\"
    echo and update SDK_VER in this script.
    exit /b 1
)

echo Compiling win.cs -> win.exe...
csc /target:exe /out:win.exe /r:"%WINMD_PATH%" /r:"%RUNTIME_PATH%" win.cs

if %ERRORLEVEL% EQU 0 (
    echo [SUCCESS] built drivers\win.exe
) else (
    echo [FAIL] Compilation failed.
)
