@echo off
title 停止所有 llamacpp 相关进程
rem ================================================
rem  双击即可停止所有从程序目录启动的程序（llama-server 等）
rem  比单个 stop 脚本覆盖更全，是兜底手段
rem ================================================
setlocal enabledelayedexpansion
set "TMPFILE=%TEMP%\llamacpp_procs_%RANDOM%.txt"

rem ---- 先定位程序根目录，用于过滤进程路径 ----
set "ROOT=%~dp0"
if exist "%~dp0llama-server.exe" goto :ROOT_OK
if exist "%~dp0..\llama-server.exe" set "ROOT=%~dp0..\"
:ROOT_OK
pushd "%ROOT%"
set "CURDIR=%CD%"

powershell -NoProfile -Command "Get-Process | Where-Object {$_.Path -like '%CURDIR%\*'} | Sort-Object Id | ForEach-Object { Write-Output ($_.Id.ToString() + '|' + $_.ProcessName) }" > "%TMPFILE%" 2>nul

set COUNT=0
for /f "usebackq delims=" %%p in ("%TMPFILE%") do set /a COUNT+=1

if %COUNT%==0 (
    color 0A
    echo.
    echo  [OK] 没有发现从 %CURDIR% 启动的程序，
    echo       不需要停止任何东西。
    echo.
    del "%TMPFILE%" 2>nul
    timeout /t 3 >nul
    exit /b 0
)

color 0E
echo ============================================
echo   发现 !COUNT! 个相关进程：
echo ============================================
echo.
for /f "usebackq tokens=1,2 delims=|" %%a in ("%TMPFILE%") do (
    echo    PID %%a    %%b
)
echo.
echo  提示：强制停止后，未保存的对话记录会丢失，
echo        但模型文件和数据不受影响，可放心停止。
echo.
choice /C YN /M "确认停止以上全部进程? [Y=停止 / N=取消]"
if errorlevel 2 (
    echo.
    echo  已取消，未做任何改动。
    del "%TMPFILE%" 2>nul
    timeout /t 2 >nul
    exit /b 0
)

for /f "usebackq tokens=1 delims=|" %%a in ("%TMPFILE%") do (
    taskkill /PID %%a /F >nul 2>&1
)

timeout /t 2 >nul
set "LEFT="
powershell -NoProfile -Command "Get-Process | Where-Object {$_.Path -like '%CURDIR%\*'} | ForEach-Object { Write-Output $_.Id }" > "%TMPFILE%" 2>nul
for /f "usebackq delims=" %%p in ("%TMPFILE%") do set "LEFT=%%p"

if not defined LEFT (
    color 0A
    echo.
    echo  [OK] 全部停止成功，显存已释放。
) else (
    color 4F
    echo.
    echo  [注意] 仍有残留进程，正在重试...
    for /f "usebackq delims=" %%p in ("%TMPFILE%") do taskkill /PID %%p /F >nul 2>&1
    timeout /t 2 >nul
    echo  [提示] 若仍在，请打开任务管理器手动结束。
)

del "%TMPFILE%" 2>nul
popd
echo.
pause
