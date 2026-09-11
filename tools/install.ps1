<#
.SYNOPSIS
    llama-cpp-v100-kit 一键部署器。

.DESCRIPTION
    把「能跑的 llama.cpp」铺到目标目录，并备好中文启动脚本。执行顺序：

      1. 环境体检：显卡在不在、驱动什么版本、跟本产物是否匹配
      2. 取产物：目标目录已有就跑第 3 步；否则从本仓库 Release 下载（内置镜像重试）
      3. 铺目录：程序本体 / webui / scripts / models
      4. 生成中文启动脚本（GBK 编码，Windows 中文 cmd 的硬要求）
      5. 打印下一步（去哪放模型、双击哪个脚本）

    这个脚本**不做任何系统级改动**：不装驱动、不写注册表、不开防火墙、不动 PATH。

.PARAMETER TargetDir
    部署目标目录，默认 D:\llamacpp。

.PARAMETER Repo
    产物来源仓库，默认 openclawzhangchong/llama-cpp-v100-kit。

.PARAMETER Tag
    Release 标签，默认 cuda12.2-sm70。

.PARAMETER Force
    即使目标目录已有 llama-server.exe 也重新下载覆盖。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\install.ps1
    powershell -ExecutionPolicy Bypass -File tools\install.ps1 -TargetDir E:\llama -Force
#>
[CmdletBinding()]
param(
    [string]$TargetDir = 'D:\llamacpp',
    [string]$Repo      = 'openclawzhangchong/llama-cpp-v100-kit',
    [string]$Tag       = 'cuda12.2-sm70',
    [switch]$Force,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$repoRoot = Split-Path -Parent $PSScriptRoot

function Say  ($m) { Write-Host $m }
function Line ()   { Write-Host ('=' * 62) }
function Ok   ($m) { Write-Host "[OK]   $m"   -ForegroundColor Green }
function Warn ($m) { Write-Host "[注意] $m"   -ForegroundColor Yellow }
function Bad  ($m) { Write-Host "[错误] $m"   -ForegroundColor Red }
function Step ($m) { Write-Host "`n── $m " -ForegroundColor Cyan }

Line
Say "  llama-cpp-v100-kit  一键部署"
Say "  Tesla V100 / P100 / sm_70 老卡 + 旧驱动专用"
Line

# ============================================================ 1) 环境体检
Step "第 1 步 / 共 5 步：环境体检"

$smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
$gpuOk = $false
if (Test-Path $smi) {
    $out = & $smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>&1
    if ($LASTEXITCODE -eq 0 -and $out -notmatch 'couldn.?t communicate') {
        $gpuOk = $true
        foreach ($l in $out) { Ok "显卡: $l" }
        $drv = (& $smi --query-gpu=driver_version --format=csv,noheader 2>&1 | Select-Object -First 1).Trim()
        Say  "     本包按 CUDA 12.2 编译，需要驱动 >= 452.39（536.25 及以上都行，不必升级）"
        try {
            $dv = [version]$drv
            if ($dv -lt [version]'452.39') {
                Warn "驱动 $drv 太旧，可能仍无法运行，请先更新驱动"
            } else {
                Ok "驱动 $drv 满足要求"
            }
        } catch { Warn "驱动版本号解析不出来：$drv" }
    }
}
if (-not $gpuOk) {
    Warn "没有检测到可用的 NVIDIA 显卡（nvidia-smi 无输出）。"
    Warn "若设备管理器里 V100 是「代码 10」，请先解决 BIOS："
    Warn "    Re-Size BAR Support = Disabled ，Above 4G Decoding = Enabled ，插 CPU 直连的 PCIEX16 槽"
    Warn "详见 README 第四节第 0 步 / docs\05-硬件与驱动实战记录.md"
}

# ============================================================ 2) 取产物
Step "第 2 步 / 共 5 步：准备程序本体"
Say "  目标目录：$TargetDir"

if (-not (Test-Path $TargetDir)) {
    New-Item -ItemType Directory -Force -Path $TargetDir | Out-Null
    Ok "已创建目录 $TargetDir"
}

$haveLocal = Test-Path (Join-Path $TargetDir 'llama-server.exe')
$haveRepo  = Test-Path (Join-Path $repoRoot 'llama-server.exe')   # 解压即用包内自带

if ($haveLocal -and -not $Force) {
    Ok "目标目录里已经有 llama-server.exe，跳过下载（要强制覆盖请加 -Force）"
} elseif ($haveRepo -and -not $Force -and $repoRoot -ne $TargetDir) {
    Say "  检测到本目录就是解压包，直接使用当前目录的文件"
} else {
    # ---- 问 GitHub 要最新资产名
    $api = "https://api.github.com/repos/$Repo/releases/tags/$Tag"
    Say "  查询 Release：$Repo @ $Tag"
    $asset = $null
    try {
        $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'llama-cpp-v100-kit' } -TimeoutSec 60
        $asset = $rel.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
    } catch {
        Warn "查不到 Release 信息（$($_.Exception.Message)）"
    }
    if (-not $asset) {
        Bad "Release 里没有可下载的 zip。"
        Say "  请手动打开下面的地址下载，然后解压到 $TargetDir："
        Say "      https://github.com/$Repo/releases"
        exit 1
    }
    Ok "找到产物：$($asset.name)  ({0:N1} MB)" -f ($asset.size / 1MB)

    # ---- 直连 + 镜像逐个重试
    $urls = @(
        $asset.browser_download_url,
        "https://gh-proxy.com/$($asset.browser_download_url)",
        "https://ghfast.top/$($asset.browser_download_url)",
        "https://ghproxy.net/$($asset.browser_download_url)"
    )
    $zip = Join-Path $env:TEMP $asset.name
    $done = $false
    foreach ($u in $urls) {
        try {
            Say "  下载：$u"
            Invoke-WebRequest -Uri $u -OutFile $zip -TimeoutSec 3600
            if ((Get-Item $zip).Length -gt 10MB) { $done = $true; break }
            Warn "文件太小，换下一个源"
        } catch {
            Warn "失败：$($_.Exception.Message)"
        }
    }
    if (-not $done) {
        Bad "所有下载源都失败了。请挂代理，或手动下载：`n      https://github.com/$Repo/releases"
        exit 1
    }
    Ok "下载完成：{0:N1} MB" -f ((Get-Item $zip).Length / 1MB)

    Say "  解压到 $TargetDir ..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $tmp = Join-Path $env:TEMP ('llamacpp_unzip_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
    Copy-Item (Join-Path $tmp '*') $TargetDir -Recurse -Force
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Ok "程序本体已就位"
}

if (-not (Test-Path (Join-Path $TargetDir 'llama-server.exe'))) {
    Bad "目标目录里还是没有 llama-server.exe，请检查压缩包内容。"
    exit 1
}

# ============================================================ 3) 铺目录
Step "第 3 步 / 共 5 步：补齐目录结构"
foreach ($d in 'models', 'webui', 'scripts') {
    $p = Join-Path $TargetDir $d
    if (-not (Test-Path $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null; Ok "新建 $d\" }
    else { Say "  已存在 $d\" }
}
# webui 从仓库补
$webSrc = Join-Path $repoRoot 'webui\index.html'
if ((Test-Path $webSrc) -and -not (Test-Path (Join-Path $TargetDir 'webui\index.html'))) {
    Copy-Item $webSrc (Join-Path $TargetDir 'webui\index.html') -Force
    Ok "已放入 webui\index.html"
}

# ============================================================ 4) 启动脚本
Step "第 4 步 / 共 5 步：生成中文启动脚本"
$scriptsDir = Join-Path $TargetDir 'scripts'
$srcScripts = Join-Path $repoRoot 'scripts'
$gen = Join-Path $repoRoot 'tools\gen-bats.py'

$copied = 0
if (Test-Path $srcScripts) {
    Get-ChildItem $srcScripts -File | ForEach-Object {
        $dst = Join-Path $scriptsDir $_.Name
        if ((Test-Path $dst) -and -not $Force) { Say "  跳过已存在的 $($_.Name)" }
        else { Copy-Item $_.FullName $dst -Force; $copied++ }
    }
    Ok "从仓库复制了 $copied 个脚本"
}

# 用 Python 重新生成（确保 GBK 编码无误，也能加上新模型）
$py = Get-Command python -ErrorAction SilentlyContinue
if ($py -and (Test-Path $gen)) {
    try {
        & $py.Source $gen --out $TargetDir 2>&1 | ForEach-Object { Say "    $_" }
        Ok "已用生成器刷新脚本（GBK + CRLF）"
    } catch {
        Warn "生成器执行失败，使用复制来的脚本：$($_.Exception.Message)"
    }
} else {
    Say "  （没装 Python，跳过生成器；仓库里已备好成品脚本）"
}

# ============================================================ 5) 收尾
Step "第 5 步 / 共 5 步：完成"
$gguf = @()
if (Test-Path (Join-Path $TargetDir 'models')) {
    $gguf = Get-ChildItem (Join-Path $TargetDir 'models') -Filter '*.gguf' -File -ErrorAction SilentlyContinue
}
if ($gguf.Count -eq 0) {
    Warn "models\ 里还没有 .gguf 模型文件 —— 这是唯一还需要你手动做的"
    Say  "     把下载好的 .gguf 复制进 $TargetDir\models\ ，然后双击 scripts\ 里的启动脚本。"
} else {
    Ok "已有 $($gguf.Count) 个模型：$($gguf.Name -join ', ')"
}

Say ""
Line
Say "  部署完成！"
Line
Say "  程序目录 : $TargetDir"
Say "  启动脚本 : $TargetDir\scripts\"
Say "  网页界面 : 启动后浏览器打开 http://127.0.0.1:8080"
Say "  API 地址 : http://127.0.0.1:8080/v1"
Say ""
Say "  停止服务 : 黑窗口按 Ctrl+C，或双击 scripts\ 里的 stop 脚本"
Line

if (-not $NoPause) {
    Say ""
    Read-Host "按回车退出"
}
