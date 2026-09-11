@echo off
title Qwen3.8-27B-UD-Q4_K_M 启动器（选择上下文长度）
rem ================================================
rem  Qwen3.8-27B-UD-Q4_K_M 交互式启动器
rem  第 1 步选上下文长度
rem  脚本可能在根目录，也可能在 scripts 子目录，下面自动定位；改参数请看仓库 docs
rem ================================================
setlocal enabledelayedexpansion

rem ---- 自动定位程序根目录 ----
set "ROOT=%~dp0"
if exist "%~dp0llama-server.exe" goto :ROOT_OK
if exist "%~dp0..\llama-server.exe" set "ROOT=%~dp0..\"
:ROOT_OK
pushd "%ROOT%"

rem ---- 0. 检查模型文件是否存在 ----
set "MODEL=models\Qwen3.8-27B-UD-Q4_K_M.gguf"
if not exist "!MODEL!" (
    color 4F
    echo.
    echo  [错误] 找不到模型文件：!MODEL!
    echo.
    echo      请把 .gguf 文件放进 models 文件夹，文件名要和上面一致。
    echo.
    pause
    exit /b 1
)

rem ---- 1. 检查端口是否被占用（已有服务在跑会显存不足）----
netstat -ano | findstr ":8080 " | findstr "LISTENING" >nul 2>&1
if not errorlevel 1 (
    color 4F
    echo.
    echo  [错误] 检测到 8080 端口已被占用 —— 说明已经有一个服务在运行！
    echo.
    echo  同一时间只能运行一个服务，否则会显存不足。
    echo  请先找到旧的黑窗口按 Ctrl+C 关闭，或双击 stopall.bat 一键停止。
    echo.
    pause
    exit /b 1
)
color 0A

:CHOICE_CTX
cls
echo ============================================
echo    第 1 步 / 共 1 步：选择上下文长度
echo ============================================
echo.
echo     1)  64K   日常问答、长文档、代码项目（推荐）
echo     2)  128K  超长文档、整本书、大型代码库
echo     3)  256K  极限长上下文（模型原生上限）
echo.
echo --------------------------------------------
echo  上下文 = 模型一次能记住的全部内容（提问 + 回答
echo  + 贴进去的文档）。
echo.
echo  预估显存占用（32GB 总显存）：
echo    64K 约 21GB      128K 约 25GB      256K 约 26GB
echo --------------------------------------------
set "CTX="
set "KVQ="
set "TAG="
set /p "c=请输入 1 / 2 / 3 后按回车: "
if "%c%"=="1" (
    set "CTX=65536"
    set "KVQ=f16"
    set "TAG=64K"
)
if "%c%"=="2" (
    set "CTX=131072"
    set "KVQ=f16"
    set "TAG=128K"
)
if "%c%"=="3" (
    set "CTX=262144"
    set "KVQ=q8_0"
    set "TAG=256K"
)
if not defined CTX (
    echo.
    echo    [提示] 输入无效，请输入 1、2 或 3
    timeout /t 2 >nul
    goto CHOICE_CTX
)

cls
color 0B
echo ============================================
echo    配置确认，即将启动
echo --------------------------------------------
echo    模型      : Qwen3.8-27B-UD-Q4_K_M
echo    上下文    : !TAG!  ( !CTX! tokens )
echo    KV 精度   : !KVQ!
echo    GPU 层数  : 99  （全部上卡）
echo    网页界面  : http://127.0.0.1:8080
echo    API 地址  : http://127.0.0.1:8080/v1
echo    停止服务  : 本窗口按 Ctrl+C，或双击 stopQwen3827b.bat
echo ============================================
echo.
if "!TAG!"=="256K" (
echo  说明：256K 档的 KV 缓存使用 q8_0 精度（f16 需要 16GB，
echo          会顶满显存）。实测对回答质量影响可忽略，仅在
echo          极长文检索的细节记忆上略有衰减。
echo.
)
:LAUNCH
echo 正在加载模型（约 1-2 分钟），出现 listening 字样即就绪...
echo.
rem ---- V100(TCC) 上 CUDA 的 PDL 检查会误报 invalid device function，必须关闭 ----
set GGML_CUDA_PDL=0

llama-server.exe -m "!MODEL!" -ngl 99 -fa on -c !CTX! -ctk !KVQ! -ctv !KVQ! --jinja --alias Qwen3.8-27B --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 --path webui

echo.
echo 服务已停止。
popd
pause
