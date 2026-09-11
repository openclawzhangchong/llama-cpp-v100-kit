<#
.SYNOPSIS
    在本机（Windows x64）从源码编译 llama.cpp 的 CUDA 版本，专为 Tesla V100 这类
    compute capability 7.0 的老卡 + 旧版驱动（如 536.25）准备。

.DESCRIPTION
    和 GitHub Actions 里的流水线等价，只是跑在本地：
      1. 取 CUDA 工具链（默认 12.2.0，走官方 redist，免管理员）
      2. 拉 llama.cpp 源码
      3. CMake 配置 + Ninja 编译（只出目标架构的真机码）
      4. 校验产物架构 + 组装「解压即用」包

    前置要求：Windows x64、Visual Studio 2022（含 C++ 桌面开发）、CMake、Ninja、Git。
    没有 CUDA 工具包也没关系，脚本会自己下。

.EXAMPLE
    # 默认：CUDA 12.2.0 + sm_70，产物在 dist\
    ./build/build-windows-cuda.ps1

.EXAMPLE
    # 指定源码版本与多架构
    ./build/build-windows-cuda.ps1 -LlamaRef b10901 -CudaArch "70;86"
#>
[CmdletBinding()]
param(
    [string]$LlamaRef   = "master",
    [string]$CudaVersion = "12.2.0",
    [string]$CudaArch   = "70",
    [string]$OutDir,
    [switch]$SkipCudaSetup
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'dist' }
$src = Join-Path $repoRoot 'src'
$bld = Join-Path $repoRoot 'build-out'

Write-Host "=================================================="
Write-Host " 本地编译 llama.cpp (Windows x64 + CUDA)"
Write-Host "   llama_ref    : $LlamaRef"
Write-Host "   cuda_version : $CudaVersion"
Write-Host "   cuda_arch    : $CudaArch"
Write-Host "   产物目录     : $OutDir"
Write-Host "=================================================="

# ---------------------------------------------------------------- 0) 前置检查
foreach ($t in 'git', 'cmake', 'ninja') {
    if (-not (Get-Command $t -ErrorAction SilentlyContinue)) {
        throw "缺少工具：$t。请先装 Visual Studio 2022（含 C++ 桌面开发），并在「VS 开发者命令提示符」里运行本脚本。"
    }
}
if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
    throw "没找到 cl.exe。请在「x64 Native Tools Command Prompt for VS 2022」里运行本脚本。"
}

# ---------------------------------------------------------------- 1) CUDA
if (-not $SkipCudaSetup) {
    & (Join-Path $PSScriptRoot 'setup-cuda-redist.ps1') -CudaVersion $CudaVersion
}
if (-not $env:CUDA_PATH) {
    $env:CUDA_PATH = Join-Path $repoRoot ".cuda\$CudaVersion"
}
Write-Host "`n使用 CUDA: $env:CUDA_PATH"

# ---------------------------------------------------------------- 2) 源码
if (-not (Test-Path (Join-Path $src '.git'))) {
    Write-Host "`n拉取 llama.cpp 源码..."
    git clone --depth 1 --branch $LlamaRef https://github.com/ggml-org/llama.cpp.git $src
    if ($LASTEXITCODE -ne 0) { git clone --depth 1 https://github.com/ggml-org/llama.cpp.git $src }
} else {
    Write-Host "`n复用已有源码目录，尝试切到 $LlamaRef"
    git -C $src fetch --depth 1 origin $LlamaRef 2>$null
    git -C $src checkout FETCH_HEAD 2>$null
}
git -C $src log -1 --format="源码版本: %H  %s"

# ---------------------------------------------------------------- 3) 配置 + 编译
Write-Host "`nCMake 配置..."
cmake -S $src -B $bld -G Ninja `
    -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_CUDA_COMPILER="$env:CUDA_PATH\bin\nvcc.exe" `
    -DCMAKE_CUDA_ARCHITECTURES="$CudaArch" `
    -DCMAKE_CUDA_FLAGS="-allow-unsupported-compiler -D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH" `
    -DGGML_CUDA=ON `
    -DGGML_NATIVE=OFF `
    -DGGML_OPENMP=OFF `
    -DGGML_BACKEND_DL=OFF `
    -DGGML_CUDA_FA_ALL_QUANTS=ON `
    -DLLAMA_CURL=OFF `
    -DLLAMA_BUILD_TESTS=OFF `
    -DLLAMA_BUILD_EXAMPLES=ON `
    -DLLAMA_BUILD_TOOLS=ON `
    -DLLAMA_BUILD_SERVER=ON
if ($LASTEXITCODE -ne 0) { throw "CMake 配置失败" }

Write-Host "`n开始编译（单机可能要 40-90 分钟）..."
cmake --build $bld --config Release -j $env:NUMBER_OF_PROCESSORS
if ($LASTEXITCODE -ne 0) { throw "编译失败" }

# ---------------------------------------------------------------- 4) 校验 + 打包
$exe = Join-Path $bld 'bin\llama-server.exe'
if (-not (Test-Path $exe)) { throw "没有生成 $exe" }
$objdump = Join-Path $env:CUDA_PATH 'bin\cuobjdump.exe'
if (Test-Path $objdump) {
    $elf = (& $objdump --list-elf $exe 2>&1 | Out-String)
    Write-Host $elf
    foreach ($a in $CudaArch -split ';') {
        if ($elf -notmatch [regex]::Escape("sm_$($a.Trim())")) { throw "产物缺 sm_$a 真机码" }
    }
}

$stage = Join-Path $OutDir 'llamacpp'
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Copy-Item "$bld\bin\*" $stage -Recurse -Force
foreach ($d in @("$env:CUDA_PATH\bin", "$env:CUDA_PATH\bin\x64")) {
    Get-ChildItem $d -Include 'cudart64_*.dll', 'cublas64_*.dll', 'cublasLt64_*.dll' -File -ErrorAction SilentlyContinue |
        ForEach-Object { Copy-Item $_.FullName $stage -Force }
}
New-Item -ItemType Directory -Force -Path "$stage\webui", "$stage\scripts", "$stage\models" | Out-Null
Copy-Item "$repoRoot\webui\index.html" "$stage\webui\" -Force
Copy-Item "$repoRoot\scripts\*" "$stage\scripts\" -Force
Copy-Item "$repoRoot\models\README.md" "$stage\models\" -Force

$zipName = "llamacpp-win-x64-cuda$CudaVersion-sm$($CudaArch -replace ';','_').zip"
$zipPath = Join-Path $OutDir $zipName
Compress-Archive -Path "$stage\*" -DestinationPath $zipPath -Force -CompressionLevel Optimal
Write-Host "`n[OK] 完成: $zipPath  ({0:N1} MB)" -f ((Get-Item $zipPath).Length / 1MB)
Write-Host "     解压后即可使用；把 .gguf 放进 models\ 再双击 scripts\ 里的启动脚本。"
