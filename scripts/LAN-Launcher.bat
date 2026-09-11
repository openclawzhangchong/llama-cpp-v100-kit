@echo off
title 局域网访问启动器
rem ================================================
rem  让 llama-server 监听 0.0.0.0，局域网内其他设备也能访问
rem  会自动放行防火墙 TCP 端口（需管理员权限才生效）
rem ================================================
set "ROOT=%~dp0"
if exist "%~dp0llama-server.exe" goto :ROOT_OK
if exist "%~dp0..\llama-server.exe" set "ROOT=%~dp0..\"
:ROOT_OK
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0LAN-Launcher.ps1" -Root "%ROOT%"
