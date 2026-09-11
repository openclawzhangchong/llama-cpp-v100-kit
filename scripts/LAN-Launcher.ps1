# LAN-Launcher.ps1
# 用途：让 llama-server.exe 监听所有网卡(0.0.0.0)，放行防火墙，
#       使局域网内其他设备可以访问 http://<本机IP>:8080/ 。
#
# 位置无关：脚本放在 llama-server.exe 同级目录或 scripts\ 子目录都能自动识别。
#
# 用法：双击 scripts\LAN-Launcher.bat
#
# 注意：放行防火墙需要【管理员权限】；没有管理员权限时会提示，但服务仍会启动，
#       只是局域网可能连不上。
#
# ============ 可调参数（按需修改） ============
param(
    [string]$Root      = "",                       # 程序根目录；留空则自动识别
    [string]$ModelRel  = "",                       # 模型相对路径；留空则自动取 models 下第一个 .gguf
    [int]   $Context   = 65536,                    # 上下文长度：65536=64K / 131072=128K / 262144=256K
    [string]$Reasoning = "off",                    # 思考强度（仅思考型模型需要）：low / medium / high / off
    [int]   $Port      = 8080,
    [string]$Host      = "0.0.0.0",                # 0.0.0.0=局域网可访问；仅本机用 127.0.0.1
    [int]   $GpuLayers = 99,                       # GPU 卸载层数；无 CUDA 时自动改为 0（纯 CPU）
    [string]$KvType    = "f16"                     # KV 缓存精度：f16 最准 / q8_0 省显存（需 -fa on）
)
# ==============================================

$ErrorActionPreference = 'Continue'

# ---------- 1) 定位程序根目录（兼容脚本在根目录 / scripts 子目录两种摆放） ----------
if (-not $Root) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
    if (Test-Path (Join-Path $scriptDir 'llama-server.exe')) {
        $Root = $scriptDir
    } elseif (Test-Path (Join-Path $scriptDir '..\llama-server.exe')) {
        $Root = (Resolve-Path (Join-Path $scriptDir '..')).Path
    } else {
        $Root = $scriptDir
    }
}
$Root = (Resolve-Path $Root).Path
Write-Host "[信息] 程序根目录：$Root"

$exe = Join-Path $Root 'llama-server.exe'
if (-not (Test-Path $exe)) {
    Write-Host "[错误] 未找到 llama-server.exe（找的是 $exe）。" -ForegroundColor Red
    if (-not $env:GITHUB_ACTIONS) { Read-Host "按回车退出" }
    exit 1
}

# ---------- 2) 结束占用端口的旧进程 ----------
$oldPids = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
             Select-Object -ExpandProperty OwningProcess -Unique)
foreach ($p in $oldPids) {
    if ($p -and $p -ne $PID) {
        try {
            Stop-Process -Id $p -Force -ErrorAction Stop
            Write-Host "[信息] 已结束占用 $Port 端口的旧进程 PID $p"
        } catch {
            Write-Host "[警告] 无法结束进程 PID $p：$_" -ForegroundColor Yellow
        }
    }
}

# ---------- 3) 防火墙入站放行 ----------
$ruleName = "LLAMA$Port`_LAN"
if (-not (Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue)) {
    try {
        New-NetFirewallRule -DisplayName $ruleName -Direction Inbound -Action Allow `
            -Protocol TCP -LocalPort $Port | Out-Null
        Write-Host "[信息] 已添加防火墙入站规则 $ruleName (TCP $Port)"
    } catch {
        Write-Host "[警告] 添加防火墙规则失败（需要以管理员身份运行）：$_" -ForegroundColor Yellow
    }
} else {
    Write-Host "[信息] 防火墙规则 $ruleName 已存在，跳过"
}

# ---------- 4) 定位模型 ----------
$modelsDir = Join-Path $Root 'models'
$modelPath = if ($ModelRel) { Join-Path $Root $ModelRel } else { "" }
if (-not $modelPath -or -not (Test-Path $modelPath)) {
    $alt = Get-ChildItem -Path $modelsDir -Filter *.gguf -ErrorAction SilentlyContinue |
           Sort-Object Length -Descending | Select-Object -First 1
    if ($alt) {
        $modelPath = $alt.FullName
        Write-Host "[信息] 自动选用模型：$($alt.Name)"
    } else {
        Write-Host "[错误] models 目录里没有 .gguf 模型文件。" -ForegroundColor Red
        if (-not $env:GITHUB_ACTIONS) { Read-Host "按回车退出" }
        exit 1
    }
}

# ---------- 5) 检测 CUDA ----------
$cudaOK = $false
try {
    $smi = & "$env:SystemRoot\System32\nvidia-smi.exe" -L 2>&1
    if ($LASTEXITCODE -eq 0 -and ($smi -match 'GPU')) { $cudaOK = $true }
} catch {}
$ngl = $GpuLayers
$useCtx = $Context
if (-not $cudaOK) {
    Write-Host "[提示] 未检测到可用 CUDA（nvidia-smi 失败），自动切到 CPU 模式(-ngl 0)。" -ForegroundColor Yellow
    Write-Host "[提示] CPU 模式上下文自动降到 8192 以防内存不足，速度会明显变慢。" -ForegroundColor Yellow
    $ngl = 0
    $useCtx = 8192
} else {
    Write-Host "[信息] 检测到 CUDA，使用 GPU 加速(-ngl $ngl)。"
}

# ---------- 6) 组装参数并启动 ----------
$argList = @('-m', $modelPath, '-ngl', "$ngl", '-fa', 'on',
             '-c', "$useCtx", '-ctk', $KvType, '-ctv', $KvType,
             '--jinja', '--port', "$Port", '--host', $Host, '--path', 'webui')
if ($Reasoning -and $Reasoning -ne 'off') {
    $argList += @('--chat-template-kwargs', "{`"reasoning_effort`":`"$Reasoning`"}")
}

# V100(TCC) 必须关掉 PDL 检查，否则会误报 CUDA error: invalid device function
$env:GGML_CUDA_PDL = '0'
Write-Host "[信息] 正在启动 llama-server，监听 ${Host}:${Port} ..."
Write-Host "[信息] 模型=$modelPath"
Write-Host "[信息] 上下文=$useCtx  KV=$KvType  思考强度=$Reasoning  加速=$(if($cudaOK){'GPU'}else{'CPU'})"

Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $Root -WindowStyle Normal

# ---------- 7) 显示局域网地址 ----------
try {
    $lanIP = (Get-NetIPAddress -AddressFamily IPv4 |
              Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -match '^192\.168\.|^10\.|^172\.' } |
              Select-Object -First 1).IPAddress
    if ($lanIP) {
        Write-Host "[成功] 局域网访问地址： http://${lanIP}:${Port}/" -ForegroundColor Green
        Write-Host "[成功] 局域网 API 地址： http://${lanIP}:${Port}/v1" -ForegroundColor Green
    }
} catch {}

Write-Host ""
Write-Host "服务已在后台新窗口运行。要停止请双击 scripts\stopall.bat。" -ForegroundColor Cyan
if (-not $env:GITHUB_ACTIONS) { Read-Host "按回车关闭本窗口" }
