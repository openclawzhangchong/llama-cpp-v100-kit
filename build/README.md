# build/ —— 编译相关

这个目录里的两个脚本，一个负责**拿到 CUDA 工具链**，一个负责**把 llama.cpp 编出来**。
云端流水线（`.github/workflows/build-cuda-windows.yml`）调用的就是它们，
所以本地编译和 CI 出来的产物是同一套配方。

---

## setup-cuda-redist.ps1 —— 免管理员获取 CUDA 工具链

```
./build/setup-cuda-redist.ps1 -CudaVersion 12.2.0
./build/setup-cuda-redist.ps1 -CudaVersion 11.8.0 -Root D:\cuda\11.8
```

它做的事：

1. 读 NVIDIA 官方组件清单
   `https://developer.download.nvidia.com/compute/cuda/redist/redistrib_<版本>.json`
2. 按清单挑出需要的 **Windows 组件**并下载（`cuda_nvcc` / `cuda_cudart` / `libcublas` / `cuda_cccl` / `cuda_cuobjdump` …）
3. 逐个 **sha256 校验**
4. 就地展开到目标目录（默认 `<仓库>\.cuda\<版本>`）
5. 自动放宽「MSVC 版本过新」的编译期拦截
6. 自检并设置 `CUDA_PATH` / `PATH`

**为什么不用完整安装包？**

| | 完整安装包 | 本脚本 |
|---|---|---|
| 体积 | 约 3 GB | 约 250 MB |
| 权限 | 需要管理员 | 不需要 |
| 系统影响 | 写注册表、装服务、可能要重启 | 零，纯解压到目录 |
| 可复现性 | 版本随官网变 | 清单里有 sha256，逐字节可复现 |

这也是 [llama.cpp 官方 CI](https://github.com/ggml-org/llama.cpp/blob/master/.github/actions/windows-setup-cuda/action.yml) 的做法。

### 为什么需要放宽 MSVC 检查

`crt/host_config.h`（由 `cuda_nvcc` 组件提供）里有：

```c
#if !defined(__NV_NO_HOST_COMPILER_CHECK)
  #if _MSC_VER < 1910 || _MSC_VER >= 1940
    #error -- unsupported Microsoft Visual Studio version! ...
```

也就是说 CUDA 12.2 的白名单只到 VS 2022 **17.9**（`_MSC_VER 1939`），
而现在的 VS 2022 已经是 **17.14**（`_MSC_VER 1944`）。
脚本注入 NVIDIA 自己提供的两个正规开关（不删改任何逻辑）：

```c
#define __NV_NO_HOST_COMPILER_CHECK 1
#define _ALLOW_COMPILER_AND_STL_VERSION_MISMATCH 1
```

---

## build-windows-cuda.ps1 —— 本地从源码编译

```
# 默认：CUDA 12.2.0 + sm_70，产物在 dist\
./build/build-windows-cuda.ps1

# 指定源码版本 + 多架构
./build/build-windows-cuda.ps1 -LlamaRef b10901 -CudaArch "70;86"

# CUDA 已装好，跳过下载
./build/build-windows-cuda.ps1 -SkipCudaSetup
```

**必须在「x64 Native Tools Command Prompt for VS 2022」里运行**（需要 `cl.exe` 在 PATH 上）。

流程：检查工具链 → 取 CUDA → 拉源码 → CMake 配置 → Ninja 编译 → 校验架构 → 打 zip。

单机编译 CPU 版和 CUDA 版合计约 **40–90 分钟**；GitHub 免费 runner 上约 30–60 分钟。

---

## 关键 CMake 参数

```powershell
cmake -S src -B build -G Ninja `
  -DCMAKE_BUILD_TYPE=Release `
  -DCMAKE_CUDA_COMPILER="$env:CUDA_PATH\bin\nvcc.exe" `
  -DCMAKE_CUDA_ARCHITECTURES="70" `
  -DCMAKE_CUDA_FLAGS="-allow-unsupported-compiler -D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH" `
  -DGGML_CUDA=ON `
  -DGGML_NATIVE=OFF `
  -DGGML_OPENMP=OFF `
  -DGGML_BACKEND_DL=OFF `
  -DGGML_CUDA_FA_ALL_QUANTS=ON `
  -DLLAMA_CURL=OFF `
  -DLLAMA_BUILD_TESTS=OFF
```

| 参数 | 作用 |
|---|---|
| `CMAKE_CUDA_ARCHITECTURES=70` | **本方案的核心**。只生成 sm_70 的 SASS 真机码，老驱动无需 PTX JIT |
| `GGML_BACKEND_DL=OFF` | 静态链接，产出单文件 exe，不依赖 `ggml-cuda.dll` 等 |
| `GGML_NATIVE=OFF` | 不做本机 CPU 指令集特化，产物可搬到别的电脑 |
| `GGML_OPENMP=OFF` | 去掉 `libomp.dll` 依赖（推理全在 GPU，无实际损失） |
| `GGML_CUDA_FA_ALL_QUANTS=ON` | 让 FlashAttention 支持 q8_0 等量化 KV 缓存 |
| `LLAMA_CURL=OFF` | 不依赖 curl/openssl，省掉一大串坑 |
| `LLAMA_BUILD_TESTS=OFF` | 测试不编，省时间 |

## 校验机制

编译完脚本会用 `cuobjdump --list-elf` 检查产物里到底有没有 `sm_70` 的真机码，
没有就直接报错中止 —— 避免"编出来了但跑不起来还要靠猜"。

```
=== cuobjdump --list-elf ===
ELF file    1: ... .sm_70.cubin
[OK] 架构校验通过：sm_70
```
