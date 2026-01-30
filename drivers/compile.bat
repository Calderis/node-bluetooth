@echo off
setlocal

:: Paths to system metadata and .NET Framework
set "WIN_META=C:\Windows\System32\WinMetadata"
set "NET_FX=C:\Windows\Microsoft.NET\Framework64\v4.0.30319"
set "CSC=%NET_FX%\csc.exe"

echo Compiling win.cs -> win.exe using System Metadata...

:: Compile using referencing local system winmd files instead of SDK
"%CSC%" /target:exe /out:win.exe ^
  /r:"%WIN_META%\Windows.Foundation.winmd" ^
  /r:"%WIN_META%\Windows.Devices.winmd" ^
  /r:"%WIN_META%\Windows.Storage.winmd" ^
  /r:"%NET_FX%\System.Runtime.dll" ^
  /r:"%NET_FX%\System.Runtime.InteropServices.WindowsRuntime.dll" ^
  /r:"%NET_FX%\System.Web.Extensions.dll" ^
  win.cs

if %ERRORLEVEL% EQU 0 (
    echo [SUCCESS] built drivers\win.exe
) else (
    echo [FAIL] Compilation failed.
)
