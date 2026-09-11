<#
.SYNOPSIS
    按官方 redist 组件下载并就地展开指定版本的 CUDA 工具链（免管理员、免完整安装包）。

.DESCRIPTION
    NVIDIA 把 CUDA 工具链按组件拆成了 zip 归档，放在
        https://developer.download.nvidia.com/compute/cuda/redist/
    并且每个版本都有一份机器可读的清单（redistrib_<版本>.json）。
    本脚本读清单 → 挑出需要的 Windows 组件 → 下载 → 校验 sha256 → 展开到目标目录，
    全程不需要管理员权限，也不会往系统里装任何东西、不改注册表。

    为什么不用完整安装包：
      · 完整包 3GB 且要管理员、要重启；
      · 我们只需要「能编译」的最小集合（nvcc + 头文件 + cublas + cub 等），
        下载量小很多，且可精确复现；这也是 llama.cpp 官方 CI 的做法。

.PARAMETER CudaVersion
    CUDA 版本，例如 12.2.0 / 11.8.0 / 12.4.0。
    要兼容旧驱动：驱动 536.25(=CUDA 12.2) 请用 12.2.0 或更低。

.PARAMETER Root
    展开目标目录。默认 <仓库>\.cuda\<版本>。

.EXAMPLE
    ./build/setup-cuda-redist.ps1 -CudaVersion 12.2.0
#>
[CmdletBinding()]
param(
    [string]$CudaVersion = "12.2.0",
    [string]$Root,
    [string[]]$Components = @(
        'cuda_cudart',                # 运行时 + 头文件（cuda_runtime.h 等）
        'cuda_nvcc',                  # nvcc / ptxas / cicc（编译核心）
        'cuda_nvrtc',                 # NVRTC（部分代码路径会用到）
        'cuda_cuobjdump',             # 产物校验用
        'libcublas',                  # cuBLAS（llama.cpp 的矩阵乘）
        'cuda_cccl',                  # CUB / Thrust / libcudacxx 头文件
        'cuda_nvtx',                  # 可选，性能标注
        'cuda_profiler_api',          # 可选
        'visual_studio_integration'   # VS 集成（Ninja 下非必需，兼容留用）
    )
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $Root) {
    $Root = Join-Path (Split-Path -Parent $PSScriptRoot) ".cuda\$CudaVersion"
}
$Root = [System.IO.Path]::GetFullPath($Root)
$Work = Join-Path $env:TEMP "cuda-redist-$CudaVersion"

Write-Host "=================================================="
Write-Host " CUDA 工具链组件获取"
Write-Host "   版本   : $CudaVersion"
Write-Host "   目标   : $Root"
Write-Host "   工作区 : $Work"
Write-Host "=================================================="

New-Item -ItemType Directory -Force -Path $Root, $Work | Out-Null

# ---------------------------------------------------------------- 1) 取清单
$base = "https://developer.download.nvidia.com/compute/cuda/redist"
$manifestUrl = "$base/redistrib_$CudaVersion.json"
Write-Host "`n[1/5] 下载组件清单: $manifestUrl"
$manifest = Invoke-RestMethod -Uri $manifestUrl -TimeoutSec 180
Write-Host "      清单含 $($manifest.PSObject.Properties.Name.Count) 个组件"

# ---------------------------------------------------------------- 2) 逐组件下载
Write-Host "`n[2/5] 下载并展开组件"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$got = @()
foreach ($comp in $Components) {
    $entry = $manifest.$comp
    if (-not $entry) {
        Write-Host ("  - {0,-28} 该版本无此组件，跳过" -f $comp)
        continue
    }
    $plat = $entry.'windows-x86_64'
    if (-not $plat) {
        Write-Host ("  - {0,-28} 无 Windows 版本，跳过" -f $comp)
        continue
    }

    $rel = $plat.relative_path
    $name = Split-Path $rel -Leaf
    $zip = Join-Path $Work $name
    $dst = Join-Path $Work "x_$comp"

    if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
    if (-not (Test-Path $zip) -or (Get-Item $zip).Length -eq 0) {
        Write-Host ("  - {0,-28} 下载 {1}" -f $comp, $name)
        Invoke-WebRequest -Uri "$base/$rel" -OutFile $zip -TimeoutSec 1800
    } else {
        Write-Host ("  - {0,-28} 复用已下载的 {1}" -f $comp, $name)
    }

    # ---- sha256 校验（清单里给了就校验）
    $want = $plat.sha256
    if ($want) {
        $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
        if ($actual -ne $want.ToLower()) {
            Remove-Item $zip -Force
            throw "组件 $comp 校验失败：期望 $want，实际 $actual（已删除坏包，请重跑）"
        }
        Write-Host ("      sha256 OK  ({0:N1} MB)" -f ((Get-Item $zip).Length / 1MB))
    }

    [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $dst)
    $top = Get-ChildItem $dst -Directory | Select-Object -First 1
    if ($top) {
        Copy-Item (Join-Path $top.FullName '*') $Root -Recurse -Force
    } else {
        Copy-Item (Join-Path $dst '*') $Root -Recurse -Force
    }
    $got += $comp
}
Write-Host "      完成 $($got.Count) 个组件: $($got -join ', ')"

# ---------------------------------------------------------------- 3) 自愈：补齐 crt/host_config.h
Write-Host "`n[3/5] 校验头文件布局"
$hc     = Join-Path $Root 'include\crt\host_config.h'
$wrapper = Join-Path $Root 'include\host_config.h'
if (-not (Test-Path $hc)) {
    $found = Get-ChildItem $Work -Recurse -Filter 'host_config.h' -File -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -match '\\crt\\' } | Select-Object -First 1
    if ($found) {
        New-Item -ItemType Directory -Force -Path (Split-Path $hc -Parent) | Out-Null
        Copy-Item $found.FullName $hc -Force
        Write-Host "      已从 $($found.FullName) 补齐 crt\host_config.h"
    } elseif (Test-Path $wrapper) {
        Write-Host "      !! 警告：只找到 include\host_config.h（转发文件），缺 crt\host_config.h" -ForegroundColor Yellow
    }
} else {
    Write-Host "      crt\host_config.h 就位"
}

# ---------------------------------------------------------------- 4) 放宽 MSVC 版本拦截
Write-Host "`n[4/5] 放宽「MSVC 版本过新」的编译期拦截"
# 背景：crt/host_config.h（由 cuda_nvcc 组件提供）里有这么一段：
#           #if !defined(__NV_NO_HOST_COMPILER_CHECK)
#             #if _MSC_VER < 1910 || _MSC_VER >= 1940
#               #error -- unsupported Microsoft Visual Studio version! ...
#       即：CUDA 12.2 只认到 VS 2022 17.9（_MSC_VER 1939），
#       而较新的 VS 2022 已经是 194x，于是合法代码也会被硬拦下。
#
#       NVIDIA 自己留了两个正规开关，这里都打开（不做任何删改代码的 hack）：
#         · __NV_NO_HOST_COMPILER_CHECK              —— 关掉上面那个版本比对
#         · _ALLOW_COMPILER_AND_STL_VERSION_MISMATCH —— 允许新 STL 的兼容告警
if (Test-Path $hc) {
    $t = [System.IO.File]::ReadAllText($hc)
    $hdr = ""
    if ($t -notmatch '__NV_NO_HOST_COMPILER_CHECK') {
        $hdr += "#define __NV_NO_HOST_COMPILER_CHECK 1  /* [kit] 跳过 MSVC 版本比对 */`r`n"
        Write-Host "      已注入 __NV_NO_HOST_COMPILER_CHECK"
    }
    if ($t -notmatch '_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH') {
        $hdr += "#define _ALLOW_COMPILER_AND_STL_VERSION_MISMATCH 1  /* [kit] 允许较新的 MSVC/STL */`r`n"
        Write-Host "      已注入 _ALLOW_COMPILER_AND_STL_VERSION_MISMATCH"
    }
    if ($hdr) {
        [System.IO.File]::WriteAllText($hc, $hdr + $t)
    } else {
        Write-Host "      两个开关已存在，无需改动"
    }
    # 顺带确认生效路径
    $n = ([regex]::Matches([System.IO.File]::ReadAllText($hc), '__NV_NO_HOST_COMPILER_CHECK')).Count
    Write-Host "      校验：文件中出现 __NV_NO_HOST_COMPILER_CHECK 共 $n 处"
} else {
    Write-Host "      跳过（未找到 crt/host_config.h）" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- 5) 生效 + 自检
Write-Host "`n[5/5] 环境自检"
$env:CUDA_PATH = $Root
$env:CUDA_HOME = $Root
$env:PATH = "$Root\bin;$Root\bin\x64;$env:PATH"

$nvcc = Join-Path $Root 'bin\nvcc.exe'
if (-not (Test-Path $nvcc)) { throw "没找到 nvcc：$nvcc" }
Write-Host "---- nvcc --version ----"
& $nvcc --version

Write-Host "`n关键文件检查："
foreach ($f in @('bin\nvcc.exe', 'bin\x64\nvcc.exe', 'nvvm\bin\cicc.exe', 'bin\cudart64_*.dll',
                 'include\cuda_runtime.h', 'include\cublas_v2.h', 'include\cub\cub.cuh')) {
    $hit = Get-ChildItem (Join-Path $Root $f) -ErrorAction SilentlyContinue
    Write-Host ("   {0,-34} {1}" -f $f, $(if ($hit) { 'OK' } else { '缺失' }))
}
Write-Host "`n可以这样直接用（当前 PowerShell 会话已生效）："
Write-Host "   `$env:CUDA_PATH = `"$Root`""

# CI 环境：把变量与 PATH 传递给后续步骤
if ($env:GITHUB_ENV) {
    "CUDA_PATH=$Root"            | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    "CUDA_HOME=$Root"            | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    "CUDA_PATH_$($CudaVersion.Replace('.','_'))=$Root" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
    "$Root\bin"                  | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append
    if (Test-Path "$Root\bin\x64") { "$Root\bin\x64" | Out-File -FilePath $env:GITHUB_PATH -Encoding utf8 -Append }
    Write-Host "`n已写入 GITHUB_ENV / GITHUB_PATH"
}
Write-Host "`n完成。CUDA $CudaVersion 已展开在 $Root"
