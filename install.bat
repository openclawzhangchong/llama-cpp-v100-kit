@echo off
title llama-cpp-v100-kit 一键部署
rem ================================================
rem  双击即可：下载已编译好的 llama.cpp + 生成中文启动脚本
rem  本脚本只做本地操作，不改系统、不装驱动、不写注册表
rem ================================================
cd /d "%~dp0"

color 0B
echo ============================================================
echo   llama-cpp-v100-kit  一键部署
echo   Tesla V100 / P100 / sm_70 老卡 + 旧驱动专用
echo ============================================================
echo.

where powershell.exe >nul 2>&1
if errorlevel 1 (
    color 4F
    echo  [错误] 找不到 PowerShell。Windows 10/11 自带，请检查系统。
    echo.
    pause
    exit /b 1
)

if not exist "%~dp0tools\install.ps1" (
    color 4F
    echo  [错误] 找不到 tools\install.ps1
    echo.
    echo      请确认是在本仓库根目录里双击本文件。
    echo.
    pause
    exit /b 1
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\install.ps1" %*
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    color 4F
    echo  [错误] 部署未完成，退出码 %RC%
    echo         请把上面的报错截图发出来。
    echo.
    pause
    exit /b %RC%
)

exit /b 0
