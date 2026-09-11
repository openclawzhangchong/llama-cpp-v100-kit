# -*- coding: utf-8 -*-
r"""
重新生成所有中文启动脚本（GBK + CRLF）。

为什么需要这个脚本
------------------
Windows 中文 cmd 的代码页是 936(GBK)：
  · 用 UTF-8 保存的中文 .bat   -> 乱码，甚至直接闪退
  · 用 LF 换行的 .bat          -> cmd 解析失败（要 CRLF）
这两条是踩过坑的硬规则。手改脚本很容易被编辑器悄悄改成 UTF-8，所以把模板固化在这里，
改完跑一下就能重新产出正确编码的成品。

用法
----
    python tools/gen-bats.py                      # 写到 <仓库>/scripts/
    python tools/gen-bats.py --out D:\llamacpp    # 写到 D:\llamacpp\scripts\
    python tools/gen-bats.py --list               # 看看有哪些模型

加新模型
--------
在下面的 MODELS 里复制一段改改就行，然后重跑本脚本。
"""

import argparse
import os
import sys

# ============================================================================
#  在这里配置模型
#  ---------------------------------------------------------------------------
#  template : ctx3        -> 只选上下文长度（三个档位）
#             ctx3effort  -> 先选上下文，再选思考强度（gpt-oss 这类思考模型）
#  tiers    : 三个档位。kv 为 KV 缓存精度（f16 最准 / q8_0 省显存）
#  extra    : 直接拼到 llama-server 命令行后面的参数
# ============================================================================
MODELS = [
    {
        "id": "Qwen3827b",
        "name": "Qwen3.8-27B-UD-Q4_K_M",
        "file": "Qwen3.8-27B-UD-Q4_K_M.gguf",
        "alias": "Qwen3.8-27B",
        "template": "ctx3",
        "port": 8080,
        "ngl": 99,
        "ngl_note": "全部上卡",
        "vram_total": "32GB",
        "tiers": [
            {"tag": "64K",  "ctx": 65536,  "kv": "f16",  "vram": "约 21GB",
             "desc": "日常问答、长文档、代码项目（推荐）"},
            {"tag": "128K", "ctx": 131072, "kv": "f16",  "vram": "约 25GB",
             "desc": "超长文档、整本书、大型代码库"},
            {"tag": "256K", "ctx": 262144, "kv": "q8_0", "vram": "约 26GB",
             "desc": "极限长上下文（模型原生上限）",
             "note": ["说明：256K 档的 KV 缓存使用 q8_0 精度（f16 需要 16GB，",
                      "        会顶满显存）。实测对回答质量影响可忽略，仅在",
                      "        极长文检索的细节记忆上略有衰减。"]},
        ],
        "extra": ("--jinja --alias Qwen3.8-27B "
                  "--temp 1.0 --top-p 0.95 --top-k 20 --min-p 0"),
    },
    {
        "id": "gptoss20b",
        "name": "gpt-oss-20b",
        "file": "gpt-oss-20b-Q4_K_M.gguf",
        "alias": "gpt-oss-20b",
        "template": "ctx3effort",
        "port": 8080,
        "ngl": 99,
        "ngl_note": "全部上卡",
        "vram_total": "32GB",
        "tiers": [
            {"tag": "8K",   "ctx": 8192,   "kv": "f16", "vram": "约 13GB",
             "desc": "日常问答、写作业（最省显存）"},
            {"tag": "32K",  "ctx": 32768,  "kv": "f16", "vram": "约 14GB",
             "desc": "长文档、代码项目（推荐日常）"},
            {"tag": "128K", "ctx": 131072, "kv": "f16", "vram": "约 23GB",
             "desc": "超长文档、整本书（模型上限）"},
        ],
        "efforts": [
            {"tag": "low",    "desc": "快速回答（日常闲聊、翻译）"},
            {"tag": "medium", "desc": "平衡模式（默认，推荐）"},
            {"tag": "high",   "desc": "深度思考（数学/推理/复杂代码）"},
        ],
        "extra": ('--chat-template-kwargs "{\\"reasoning_effort\\":\\"@@EFFORT@@\\"}"'),
        "extra_desc": "思考强度",
    },
]


# ============================================================================
#  通用片段
# ============================================================================
PROLOGUE = r"""@echo off
title @@TITLE@@
rem ================================================
rem  @@NAME@@ 交互式启动器
rem  @@SUBTITLE@@
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
set "MODEL=models\@@FILE@@"
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
netstat -ano | findstr ":@@PORT@@ " | findstr "LISTENING" >nul 2>&1
if not errorlevel 1 (
    color 4F
    echo.
    echo  [错误] 检测到 @@PORT@@ 端口已被占用 —— 说明已经有一个服务在运行！
    echo.
    echo  同一时间只能运行一个服务，否则会显存不足。
    echo  请先找到旧的黑窗口按 Ctrl+C 关闭，或双击 stopall.bat 一键停止。
    echo.
    pause
    exit /b 1
)
color 0A
"""

CTX_MENU = r"""
:CHOICE_CTX
cls
echo ============================================
echo    第 @@NSTEP@@ 步 / 共 @@TOTSTEP@@ 步：选择上下文长度
echo ============================================
echo.
@@MENU@@echo.
echo --------------------------------------------
echo  上下文 = 模型一次能记住的全部内容（提问 + 回答
echo  + 贴进去的文档）。
echo.
echo  预估显存占用（@@VRAMTOTAL@@ 总显存）：
echo    @@VRAMLINE@@
echo --------------------------------------------
set "CTX="
set "KVQ="
set "TAG="
set /p "c=请输入 1 / 2 / 3 后按回车: "
@@TIERLOGIC@@if not defined CTX (
    echo.
    echo    [提示] 输入无效，请输入 1、2 或 3
    timeout /t 2 >nul
    goto CHOICE_CTX
)
"""

EFFORT_MENU = r"""
:CHOICE_EFF
cls
echo ============================================
echo    第 2 步 / 共 2 步：选择思考强度
echo ============================================
echo.
@@MENU@@echo.
echo --------------------------------------------
set "EFF="
set /p "e=请输入 1 / 2 / 3 后按回车: "
@@EFFLOGIC@@if not defined EFF (
    echo.
    echo    [提示] 输入无效，请输入 1、2 或 3
    timeout /t 2 >nul
    goto CHOICE_EFF
)
"""

CONFIRM = r"""
cls
color 0B
echo ============================================
echo    配置确认，即将启动
echo --------------------------------------------
echo    模型      : @@NAME@@
echo    上下文    : !TAG!  ( !CTX! tokens )
echo    KV 精度   : !KVQ!
@@EFFLINE@@echo    GPU 层数  : @@NGL@@  （@@NGLNOTE@@）
echo    网页界面  : http://127.0.0.1:@@PORT@@
echo    API 地址  : http://127.0.0.1:@@PORT@@/v1
echo    停止服务  : 本窗口按 Ctrl+C，或双击 @@STOPBAT@@
echo ============================================
echo.
@@NOTES@@:LAUNCH
echo 正在加载模型（约 1-2 分钟），出现 listening 字样即就绪...
echo.
rem ---- V100(TCC) 上 CUDA 的 PDL 检查会误报 invalid device function，必须关闭 ----
set GGML_CUDA_PDL=0

llama-server.exe -m "!MODEL!" -ngl @@NGL@@ -fa on -c !CTX! -ctk !KVQ! -ctv !KVQ! @@EXTRA@@ --path webui

echo.
echo 服务已停止。
popd
pause
"""

STOPPER = r"""@echo off
title @@NAME@@ 停止器（关闭 llama-server）
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
"""

STOPALL = r"""@echo off
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
"""

INSTALL_BAT = r"""@echo off
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
"""


LAN_BAT = r"""@echo off
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
"""


# ============================================================================
#  生成逻辑
# ============================================================================
def render(model):
    tiers = model["tiers"]
    n_effort = model["template"] == "ctx3effort"
    tot = 2 if n_effort else 1

    # ---- 上下文菜单
    menu = ""
    for i, t in enumerate(tiers, 1):
        menu += "echo     %d)  %-5s %s\n" % (i, t["tag"], t["desc"])

    vram_line = "      ".join("%s %s" % (t["tag"], t["vram"]) for t in tiers)

    tier_logic = ""
    for i, t in enumerate(tiers, 1):
        tier_logic += ('if "%%c%%"=="%d" (\n'
                       '    set "CTX=%d"\n'
                       '    set "KVQ=%s"\n'
                       '    set "TAG=%s"\n'
                       ')\n') % (i, t["ctx"], t["kv"], t["tag"])

    notes = ""
    for t in tiers:
        if t.get("note"):
            cond = 'if "!TAG!"=="%s" (\n' % t["tag"]
            for ln in t["note"]:
                cond += "echo  %s\n" % ln
            cond += "echo.\n)\n"
            notes += cond

    stop_bat = "stop%s.bat" % model["id"]

    txt = PROLOGUE
    txt += CTX_MENU
    if n_effort:
        emenu = ""
        for i, e in enumerate(model["efforts"], 1):
            emenu += "echo     %d)  %-8s %s\n" % (i, e["tag"], e["desc"])
        elogic = ""
        for i, e in enumerate(model["efforts"], 1):
            elogic += 'if "%%e%%"=="%d" set "EFF=%s"\n' % (i, e["tag"])
        txt += EFFORT_MENU
        txt = txt.replace("@@MENU@@", emenu).replace("@@EFFLOGIC@@", elogic)
    txt += CONFIRM

    # ---- 思考强度那一行（只有 ctx3effort 才有）
    if n_effort:
        txt = txt.replace("@@EFFLINE@@",
                          "echo    思考强度  : !EFF!  （越低越快，越高越深思）\n")
    else:
        txt = txt.replace("@@EFFLINE@@", "")

    extra = model["extra"]
    if "@@EFFORT@@" in extra:
        extra = extra.replace("@@EFFORT@@", "%EFF%")

    # ---- 统一替换（用 @@TOKEN@@ 而不是 .format()，避免 bat 里的 % 和 {} 打架）
    rep = {
        "@@TITLE@@":      "%s 启动器（选择上下文%s）" % (model["name"], "与思考强度" if n_effort else "长度"),
        "@@NAME@@":       model["name"],
        "@@SUBTITLE@@":   ("第 1 步选上下文长度%s" % ("，第 2 步选思考强度" if n_effort else "")),
        "@@FILE@@":       model["file"],
        "@@PORT@@":       str(model["port"]),
        "@@NGL@@":        str(model["ngl"]),
        "@@NGLNOTE@@":    model["ngl_note"],
        "@@VRAMTOTAL@@":  model["vram_total"],
        "@@VRAMLINE@@":   vram_line,
        "@@MENU@@":       menu,
        "@@TIERLOGIC@@":  tier_logic,
        "@@NSTEP@@":      "1",
        "@@TOTSTEP@@":    str(tot),
        "@@NOTES@@":      notes,
        "@@STOPBAT@@":    stop_bat,
        "@@EXTRA@@":      extra,
    }
    for k, v in rep.items():
        txt = txt.replace(k, v)
    return txt


def w(path, text, enc="gbk"):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding=enc, newline="\r\n") as f:
        f.write(text)
    print("  %-44s %6d B  [%s + CRLF]" % (os.path.basename(path), os.path.getsize(path), enc.upper()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=None, help="输出目录（脚本会写进 <out>/scripts/）")
    ap.add_argument("--list", action="store_true", help="只列出已配置的模型")
    a = ap.parse_args()

    if a.list:
        for m in MODELS:
            print("%-12s %-28s %s" % (m["id"], m["name"], m["template"]))
        return

    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.dirname(here)
    out = a.out or root
    scripts = os.path.join(out, "scripts")
    os.makedirs(scripts, exist_ok=True)

    print("输出目录: %s\n" % scripts)

    for m in MODELS:
        w(os.path.join(scripts, "start-server-%s.bat" % m["id"]), render(m))
        w(os.path.join(scripts, "stop%s.bat" % m["id"]),
          STOPPER.replace("@@NAME@@", m["name"]))

    w(os.path.join(scripts, "stopall.bat"), STOPALL)
    w(os.path.join(scripts, "LAN-Launcher.bat"), LAN_BAT)
    w(os.path.join(out, "install.bat"), INSTALL_BAT)

    print("\n完成。注意：这些文件是 GBK 编码，用记事本编辑后请勿另存为 UTF-8。")


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    main()
