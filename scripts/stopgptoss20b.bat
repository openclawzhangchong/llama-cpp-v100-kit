@echo off
title gpt-oss-20b 停止器（关闭 llama-server）
rem ================================================
rem  双击即可停止正在运行的 llama-server 服务
rem ================================================

tasklist /FI "IMAGENAME eq llama-server.exe" 2>nul | find /I "llama-server.exe" >nul
if errorlevel 1 (
    color 0A
    echo.
    echo  [OK] 当前没有正在运行的 llama-server 服务，
    echo       不需要停止任何东西。
    echo.
    timeout /t 3 >nul
    exit /b 0
)

color 0E
echo ============================================
echo   发现正在运行的 llama-server 服务：
echo ============================================
echo.
tasklist /FI "IMAGENAME eq llama-server.exe" 2>nul | find /I "llama-server.exe"
echo.
echo  提示：强制停止后，未保存的对话记录会丢失，
echo        但模型文件和数据不受影响，可放心停止。
echo.
choice /C YN /M "确认停止以上服务? [Y=停止 / N=取消]"
if errorlevel 2 (
    echo.
    echo  已取消，未做任何改动。
    timeout /t 2 >nul
    exit /b 0
)

taskkill /IM llama-server.exe /F >nul 2>&1

rem ---- 验证是否真的停了 ----
timeout /t 2 >nul
tasklist /FI "IMAGENAME eq llama-server.exe" 2>nul | find /I "llama-server.exe" >nul
if errorlevel 1 (
    color 0A
    echo.
    echo  [OK] 服务已成功停止，显存已释放。
) else (
    color 4F
    echo.
    echo  [注意] 还有残留进程，正在重试...
    taskkill /F /IM llama-server.exe >nul 2>&1
    timeout /t 2 >nul
    tasklist /FI "IMAGENAME eq llama-server.exe" 2>nul | find /I "llama-server.exe" >nul
    if errorlevel 1 (
        color 0A
        echo  [OK] 重试后服务已停止。
    ) else (
        echo  [错误] 仍无法停止，请截图此窗口排查。
    )
)
echo.
pause
