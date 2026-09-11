# llama-cpp-v100-kit

> **在 Windows 上让 Tesla V100（sm_70）这类老计算卡跑起新版 llama.cpp 的一键工具包。**
> 不需要升级显卡驱动、不需要安装 CUDA 工具包、不需要会编译。
>
> 适用显卡：compute capability **7.0 / 7.5** 的 NVIDIA 卡 —— Tesla **V100**、P100、Titan V、RTX 20 系。
> 适用场景：驱动停在**旧版本**（例如 536.25 / 550.x）、官方预编译包一跑就报
> `CUDA error: the provided PTX was compiled with an unsupported toolchain`。

---

## 一、30 秒上手（新机器）

```
① 下载 Release 里的 zip，解压到 D:\llamacpp
      https://github.com/openclawzhangchong/llama-cpp-v100-kit/releases
      （文件：llamacpp-win-x64-cuda12.2.0-sm70_*.zip）

② 把 .gguf 模型文件放进 D:\llamacpp\models\

③ 双击 D:\llamacpp\scripts\ 里对应的启动脚本 → 浏览器打开 http://127.0.0.1:8080
```

包里已经带了 CUDA 运行库，**不需要装驱动以外的任何东西**。

> 网络访问 GitHub 慢/不通时，用镜像前缀下载，例如
> `https://gh-proxy.com/https://github.com/openclawzhangchong/llama-cpp-v100-kit/releases/download/cuda12.2-sm70/<文件名>`
> （`gh-proxy.com` / `ghfast.top` / `ghproxy.net` 三选一，脚本里也内置了自动重试）

也可以先克隆整个仓库再一键部署（会顺手生成中文脚本、检查环境）：

```bat
git clone https://github.com/openclawzhangchong/llama-cpp-v100-kit.git
cd llama-cpp-v100-kit
install.bat
```

---

## 二、这个包解决的是什么问题（先看这一节，能省几小时）

### 现象

在一张 **Tesla V100 + 536.25 驱动**的机器上，下载官方最新的 Windows CUDA 版 llama.cpp，启动即失败：

```
CUDA error: the provided PTX was compiled with an unsupported toolchain.
```

换 `-ngl 0`（纯 CPU）也照样崩，换别的模型也照样崩 —— 说明不是模型的问题，而是 **CUDA 后端在初始化阶段就死了**。

### 根因（实测解剖出来的）

把官方包里的 `ggml-cuda.dll`（521.8 MB）解剖后，事实很清楚：

| 检测项 | 官方包实测值 | 后果 |
|---|---|---|
| 内嵌 **SASS（真机码）** | 只有 `sm_86`、`sm_89` | V100 是 sm_70，**没有可用的真机码** |
| 内嵌 **PTX（中间码）** | 6 个架构，含 sm_70 | 但 PTX 版本是 **ISA 8.4**（CUDA 12.4 编的） |
| 你的驱动 536.25 上限 | PTX ISA **8.2**（= CUDA 12.2） | → 驱动读不懂 8.4 的 PTX，JIT 失败 |

于是 V100 既没有本地真机码、PTX 又太新 —— 两头都堵死。

而官方 release 工作流里**根本没传 `CMAKE_CUDA_ARCHITECTURES`**，工具链写死 `12.4 / 13.3 / 13.4`，
且官方**从未发布过 CUDA 12.2 的 Windows 预编译包**（近 144 个 build 全部核实过）。

### 本仓库的做法

用**与驱动同代的 CUDA 工具链**重新编译，并**显式指定目标架构**：

```yaml
CUDA 12.2.0  +  -DCMAKE_CUDA_ARCHITECTURES=70
```

产物里只有 `sm_70` 的真机码，驱动 536.25 能原生执行 —— 不需要 PTX JIT，不需要升驱动。

### 通用判据（以后遇到同类问题直接套）

> 一份 llama.cpp CUDA 后端能不能在这张卡 + 这个驱动上跑，只看两点：
>
> - **用 CUDA ≤ 12.2 的工具链编译** → PTX ISA ≤ 8.2，老驱动能 JIT → **一定能跑**（有没有 sm_70 真机码都无所谓）
> - **用 CUDA ≥ 12.3 编译** → 则**必须内嵌 sm_70 的真机码**（`-DCMAKE_CUDA_ARCHITECTURES=70`，且编译器要真的为它生成 SASS）

官方包两条都不满足 → 必然失败。

### 该选哪个版本？对照表

| 你的显卡驱动 | 能跑的最高 CUDA 工具链 | 本仓库对应参数 |
|---|---|---|
| 536.25 / 535.x（CUDA 12.2） | 12.2 | `cuda_version=12.2.0`（默认） |
| 452.x 及更老（CUDA 11.x） | 11.8 | `cuda_version=11.8.0` |
| 550+（CUDA 12.4+） | 12.4 / 13.x | 直接用官方包即可，不需要本仓库 |

`cuda_arch` 对照：V100 / Titan V = `70`，P100 = `60`，RTX 20 系 = `75`，RTX 30 系 = `86`。
不确定就用 `70;75;86`（体积大一点，但通吃）。

---

## 三、仓库结构

```
llama-cpp-v100-kit/
├── README.md                     ← 你正在看的这份
├── install.bat                   ← 一键部署（下载产物 + 铺目录 + 生成脚本）
├── .github/workflows/
│   └── build-cuda-windows.yml    ★ 云端编译流水线（本仓库的核心）
├── build/
│   ├── setup-cuda-redist.ps1     ★ 免管理员获取 CUDA 工具链（走官方 redist 组件）
│   ├── build-windows-cuda.ps1    ★ 本地从源码编译（和流水线等价）
│   └── README.md
├── scripts/                      ★ 中文启动脚本（GBK 编码，开箱即用）
│   ├── start-server-Qwen3827b.bat    Qwen3.8-27B：选 64K / 128K / 256K
│   ├── stopQwen3827b.bat             停止上面那个服务
│   ├── start-server-gptoss20b.bat    gpt-oss-20b：选上下文 + 思考强度
│   ├── stopgptoss20b.bat             停止 gpt-oss 服务
│   ├── stopall.bat                   停掉所有 llamacpp 进程（兜底）
│   ├── LAN-Launcher.bat              一键开局域网访问（会放行防火墙）
│   └── LAN-Launcher.ps1              上面那个 bat 的实际执行体
├── webui/index.html              简洁的网页聊天界面（含思考过程折叠）
├── tools/
│   ├── install.ps1               install.bat 的实际执行体
│   └── gen-bats.py               重新生成全部中文 bat（省得手改 GBK 编码）
├── models/README.md              模型放哪、去哪下、怎么挑量化
└── docs/
    ├── 01-原理-CUDA版本与驱动的关系.md        ★ 判据与解剖方法（看懂这节能自己定位）
    ├── 02-V100-驱动536.25-CUDA预编译包调研.md  全网第三方预编译包逐个核查的原始调研
    ├── 03-Qwen3.8-27B-参数与显存说明.md       参数逐条解释 + 显存推导
    ├── 04-故障排查手册.md                    按报错阶段分类的排查表
    └── 05-硬件与驱动实战记录.md              BIOS / 代码 10 / 驱动分支的真机记录
```

---

## 四、新机器完整部署流程

### 第 0 步：硬件与 BIOS（V100 上消费级主板的必修课）

这一步最容易卡住，且和软件无关。**如果 `nvidia-smi` 报 "couldn't communicate with the NVIDIA driver"、
设备管理器里显示"代码 10（STATUS_INSUFFICIENT_RESOURCES）"，问题在这里。**

| 项目 | 要求 |
|---|---|
| PCIe 插槽 | 必须插 **CPU 直连的 PCIEX16** 槽（不要走芯片组） |
| **Re-Size BAR Support** | **关闭**（Tesla 卡走 32GB 大 BAR 协商会失败；关掉后退回小 BAR 模式） |
| **Above 4G Decoding** | **开启** |
| PCIe 链路速度 | 固定 **Gen3**（V100 上限就是 Gen3） |
| 供电 | V100 峰值约 250W，需 **2×8pin**（或 8pin + CPU 8pin 转接），电源 ≥ 650W |
| 显示输出 | 由 **核显**承担；V100 建议切 **TCC 模式**（纯计算卡） |

判定成功：进系统后设备管理器里 V100 无黄色感叹号，`nvidia-smi` 能列出卡。

### 第 1 步：显卡驱动

**不要盲目升到最新。** 关键事实：

- NVIDIA 官方口径：**580 分支是最后一个支持 Volta（CC 7.0）的驱动分支**，给这类用户的建议是"驱动停在 580 分支 + CUDA 工具包停在 12.9"。
- Tesla / 数据中心卡在 Windows 上要用 **Data Center（Tesla）驱动包**，装成 GeForce 桌面包或 vGPU 包都可能认不到卡。
- 驱动能用就别动。**本工具包的设计前提就是"驱动不动、从编译侧适配"**。

> 本机实测：582.53（R580）在这张华为 OEM 的 V100 上报代码 10；退回 **536.25** 反而正常识别并可用。
> 这说明具体哪一版能用是**卡个体差异**，经验值不如实测值 —— 详见 `docs/05`。

### 第 2 步：装本工具包

```bat
:: 方式 A：只下产物（推荐，最快）
::   从 Release 下载 zip → 解压到 D:\llamacpp

:: 方式 B：克隆仓库 + 一键部署（会检查环境、生成中文脚本）
git clone https://github.com/openclawzhangchong/llama-cpp-v100-kit.git
cd llama-cpp-v100-kit
install.bat
```

`install.bat` 会做四件事：检测环境 → 从本仓库 Release 下载产物（已存在则跳过）→ 铺开到目标目录 → 生成中文启动脚本。

### 第 3 步：放模型

把 `.gguf` 放进 `D:\llamacpp\models\`，然后双击 `scripts\` 里对应的启动脚本。

模型下载建议（本机实测可用）：

| 模型 | 量化 | 体积 | 大小/上下文 | 说明 |
|---|---|---|---|---|
| **Qwen3.8-27B** | UD-Q4_K_M | 15.3 GB | 27B / 原生 256K | 混合注意力，长上下文极省显存（见 docs/03） |
| gpt-oss-20b | Q4_K_M | 11.6 GB | 20B / 128K | 思考型模型，实测约 295 tok/s |
| Qwen3.6-35B-A3B | UD-IQ4_XS | 17.7 GB | MoE 35B / 长上下文 | 激活参数少，速度快 |

---

## 五、自己重新编译

### 方式 A：云端编译（推荐，不用装任何东西）

GitHub Actions → **Build llama.cpp for Windows (CUDA, 兼容 Volta / 老驱动)** → `Run workflow`：

| 输入 | 说明 | 默认 |
|---|---|---|
| `llama_ref` | `master` 或某个 tag（如 `b10901`） | `master` |
| `cuda_version` | `12.2.0` 兼容 536.25；`11.8.0` 兼容更老 | `12.2.0` |
| `cuda_arch` | `70`（V100）；多档 `70;86` | `70` |
| `asset_tag` | 发布到哪个 Release 标签 | `cuda12.2-sm70` |
| `publish_release` | 是否发布 Release | `true` |

跑完自动出 zip，并发布到 Release。整个流程约 30–60 分钟。
**改了 `build/`、`scripts/`、`tools/`、`webui/` 里任何文件并推到 main，也会自动重新编译。**

### 方式 B：本地编译

```powershell
# 在「x64 Native Tools Command Prompt for VS 2022」里
git clone https://github.com/openclawzhangchong/llama-cpp-v100-kit.git
cd llama-cpp-v100-kit
./build/build-windows-cuda.ps1                     # 默认 CUDA 12.2.0 + sm_70
./build/build-windows-cuda.ps1 -LlamaRef b10901 -CudaArch "70;86"
```

前置：Visual Studio 2022（含 C++ 桌面开发）、CMake、Ninja、Git。**CUDA 不用自己装** ——
`setup-cuda-redist.ps1` 会从 NVIDIA 官方 redist 拉取组件并就地展开（免管理员、免完整安装包、校验 sha256）。

### 编译参数为什么这么配

| 参数 | 为什么 |
|---|---|
| `-DCMAKE_CUDA_ARCHITECTURES=70` | **本方案的核心**：只生成 sm_70 真机码，驱动不需要 JIT |
| `-DGGML_CUDA=ON` | 启用 CUDA 后端 |
| `-DGGML_BACKEND_DL=OFF` | 单文件 exe，不依赖 `ggml-*.dll`，部署最简单 |
| `-DGGML_NATIVE=OFF` | 不做本机 CPU 特化，产物可换机器用 |
| `-DGGML_OPENMP=OFF` | 去掉 `libomp.dll` 依赖（推理全在 GPU） |
| `-DGGML_CUDA_FA_ALL_QUANTS=ON` | 让 FlashAttention 支持 `q8_0` 量化 KV 缓存（256K 档要用） |
| `-DLLAMA_CURL=OFF` | 不依赖 curl/openssl，少一堆坑 |
| `-DCMAKE_CUDA_FLAGS="-allow-unsupported-compiler -D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH"` | 允许较新的 MSVC —— CUDA 12.2 的版本白名单只到 VS2022 17.9 |
| `-DGGML_CUDA_PDL=0`（**运行时**） | V100 对 PDL 支持不完整，不关会误报 `invalid device function` |

---

## 六、运行参数（已适配本机的配置）

`scripts/start-server-Qwen3827b.bat` 里的关键行：

```bat
set GGML_CUDA_PDL=0
llama-server.exe -m "models\Qwen3.8-27B-UD-Q4_K_M.gguf" -ngl 99 -fa on ^
  -c 65536 -ctk f16 -ctv f16 --jinja --alias Qwen3.8-27B ^
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0 ^
  --host 127.0.0.1 --port 8080 --path webui
```

| 档位 | 上下文 | KV 精度 | 显存 | 用途 |
|---|---|---|---|---|
| 1 | 64K | f16 | ≈21 GB | 日常首选 |
| 2 | 128K | f16 | ≈25 GB | 整本书、大型代码库 |
| 3 | 256K | q8_0 | ≈26 GB | 模型原生上限 |

三档全部 `-ngl 99` 全量上卡（V100-32GB 装得下，推导过程见 `docs/03`）。

- `-fa on` —— FlashAttention，省显存提速，**KV 量化必须开**
- `--jinja` —— 启用模型自带对话模板，**删了多轮对话会错乱**
- `--path webui` —— 用本仓库 `webui/` 的简洁界面（删掉则用官方界面）
- API 地址 `http://127.0.0.1:8080/v1`，模型名 `Qwen3.8-27B`；局域网共享双击 `LAN-Launcher.bat`

---

## 七、故障速查

| 现象 | 原因 / 解法 |
|---|---|
| `the provided PTX was compiled with an unsupported toolchain` | 用到了官方包（CUDA 12.4 编的）。换本仓库产物 |
| `CUDA error: invalid device function` | `set GGML_CUDA_PDL=0` 被删了，加回去 |
| `couldn't communicate with the NVIDIA driver` / 设备管理器代码 10 | **硬件/BIOS 问题**，看第四节第 0 步 |
| `CUDA out of memory` | 关掉另一个在跑的服务；选更小的档位；256K 档确认 `-ctk/-ctv` 是 `q8_0` |
| 双击 bat 一闪就没 | 编码被改坏了（必须是 GBK + CRLF）。用 `tools/gen-bats.py` 重新生成 |
| 网页打不开 | 看黑窗口里 `--port` 是几，地址就用几 |
| 多轮对话答非所问 | `--jinja` 被删了 |
| 加载慢（1–2 分钟） | 正常，15 GB 权重要从磁盘读进显存 |

更多见 `docs/04-故障排查手册.md`。

---

## 八、已知限制与诚实标注

- **本工具包只解决"CUDA 后端跑不起来"这一类问题**，不解决硬件/BIOS/驱动识别问题。
- `sm_70` 真机码在**更新的驱动**上同样能跑（向后兼容），所以本产物不是只能配 536.25。
- 云端编译偶发依赖 NVIDIA 官网与 GitHub 的可用性；`cuda_version` 换 `11.8.0` 是备用路径。
- 仓库里的 `scripts/*.bat` 是 **GBK 编码**（Windows 中文 cmd 的硬要求），在 GitHub 网页上会显示为乱码，属正常现象。

---

## 九、安全提示

- 本仓库**不含任何模型权重**，也不含任何凭据。
- `scripts/*.bat` 只做本地操作：设置环境变量、启动 `llama-server.exe`、结束进程、开防火墙端口。
- 开局域网访问（`LAN-Launcher.bat`）会把服务暴露到同一局域网，**不要在不可信网络里开着**。

## 许可

本仓库的脚本与文档采用 MIT（见 `LICENSE`）。
编译产物源自 [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp)（MIT），CUDA 组件版权归 NVIDIA 所有。
