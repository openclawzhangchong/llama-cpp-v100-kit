# 01 · 原理：CUDA 工具链、驱动、显卡架构三者到底是什么关系

> 这份文档解释「为什么官方包在老卡 + 老驱动上跑不起来」，以及**怎么自己判断任意一个
> llama.cpp CUDA 包能不能在你的机器上跑**。看懂这一节，同类问题基本都能自己定位。

---

## 一、三个版本号，别混

| 名词 | 是什么 | 谁决定它 | 例子 |
|---|---|---|---|
| **显卡架构 / compute capability** | 显卡的硬件能力等级，编译时的 `sm_XX` | 硬件出厂就定了 | V100 = **sm_70**，RTX 4090 = sm_89 |
| **CUDA 工具链版本** | `nvcc` 编译器版本，决定生成什么格式的机器码 | 编译这套程序的人 | 官方包用的是 12.4 / 13.x |
| **显卡驱动版本** | 装在系统里的 `nvlddmkm.sys`，负责执行机器码 | 你装的那个驱动包 | 本机是 **536.25**（对应 CUDA 12.2） |

**关键：驱动必须"读得懂"程序里带的机器码。** 读不懂就报错，跟程序写得对不对无关。

---

## 二、程序里的机器码有两种，命运完全不同

编译 CUDA 程序时，产物里可能同时带两种东西：

### 1. SASS（真机码 / cubin）

已经翻译成**某代显卡专用的汇编**。驱动拿到就能直接跑，**不需要任何翻译**。

- 必须为具体架构生成：`sm_70` 的 SASS 只能在 sm_70 及以上的卡上跑
- 特点：启动最快，但"认架构"

### 2. PTX（中间码）

一种**半成品**的中间表示。驱动拿到后，要靠内置的 **JIT 编译器**现场翻译成这台卡的 SASS。

- 好处：一份 PTX 能给多种架构用
- 坏处：**PTX 有版本号（ISA 版本），驱动只认自己那一代及更早的**

| CUDA 工具链 | PTX ISA 版本 | 需要的最低驱动 |
|---|---|---|
| 11.8 | 7.8 | 452.39 |
| **12.2** | **8.2** | **536.25** ← 本机 |
| 12.4 | 8.4 | 551.61 |
| 12.8 | 8.7 | 570.x |
| 13.x | 9.x | 580.x+ |

> 于是在驱动 536.25（认到 ISA 8.2）上：
> **PTX ISA ≤ 8.2 能 JIT ✅** ，**PTX ISA ≥ 8.3 直接报错 ❌**
>
> 报错原文就是：`CUDA error: the provided PTX was compiled with an unsupported toolchain.`

---

## 三、官方包为什么必然失败（实测解剖）

解剖官方 `ggml-cuda.dll`（521.8 MB，build b10853）得到的硬数据：

| 检测项 | 实测值 | 对 V100 的意义 |
|---|---|---|
| 内嵌 SASS 架构 | **只有 `sm_86`、`sm_89`** | V100 是 sm_70 → **没有可用的真机码** |
| 内嵌 PTX 架构 | 6 个，含 sm_70 | 架构是有，但… |
| PTX ISA 版本 | **8.4**（CUDA 12.4） | 驱动 536.25 只认 8.2 → **JIT 失败** |

**两头都堵死：** 真机码没有 sm_70 的，中间码版本又太新。

这也解释了为什么 `-ngl 0`（纯 CPU 模式）和换模型都一样崩 —— CUDA 后端是在
**初始化阶段**就失败的，还没轮到"用不用 GPU"。

官方为什么不出低版本 CUDA 的包？看它的 release 工作流就知道：
**根本没有传 `CMAKE_CUDA_ARCHITECTURES`**，架构列表走 CMake 默认规则
（老架构给 PTX、新架构给 SASS），工具链写死 `12.4 / 13.3 / 13.4`。
官方期望的用法就是"装新驱动"。

---

## 四、通用判据（背下来）

> **一份 llama.cpp CUDA 后端能不能在这张卡 + 这个驱动上跑，只看两点：**
>
> 1. **用 CUDA ≤ 12.2 的工具链编译** → PTX ISA ≤ 8.2，老驱动能 JIT → **一定能跑**
>    （有没有 sm_70 真机码都无所谓）
> 2. **用 CUDA ≥ 12.3 编译** → 则**必须内嵌 sm_70 的 SASS 真机码**才能跑

官方包两条都不满足 → 必然失败。
本仓库用第 1 条：CUDA 12.2.0 + `-DCMAKE_CUDA_ARCHITECTURES=70`，双保险。

---

## 五、怎么自己解剖一个包（可复现）

不用装 CUDA，也不用跑起来，直接读二进制就行。

### 方法 A：用 `cuobjdump`（装了 CUDA 的话最省事）

```bat
cuobjdump --list-elf ggml-cuda.dll     :: 看有哪些真机码（SASS）
cuobjdump --list-ptx ggml-cuda.dll     :: 看有哪些中间码（PTX）
```

输出里出现 `sm_70` 才说明给 V100 准备了东西。

### 方法 B：纯 Python 扫 fatbin（不需要任何工具链）

CUDA 的 fatbin 就是一串拼接的 ELF 文件，直接扫就行：

```python
import mmap, struct, re, collections

def scan(path):
    f = open(path, 'rb'); mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
    n, p, elf, ptx = len(mm), 0, collections.Counter(), collections.Counter()
    while True:                                  # 找所有 cubin（ELF 头 + e_machine=190=CUDA）
        i = mm.find(b'\x7fELF', p)
        if i < 0: break
        p = i + 4
        if i + 64 <= n and struct.unpack_from('<H', mm, i + 18)[0] == 190:
            # e_flags 低 8 位 = SM 版本；48=0x30→sm_48 … 70=0x46→sm_70
            elf[struct.unpack_from('<I', mm, i + 48)[0] & 0xFF] += 1
    p = 0
    while True:                                  # 找所有 .target sm_XX（PTX 段）
        i = mm.find(b'.target sm_', p)
        if i < 0: break
        p = i + 1
        ptx[mm[i+11:i+14].decode('latin1')] += 1
    print('SASS(cubin) 架构 :', dict(sorted(elf.items())))
    print('PTX  目标架构    :', dict(sorted(ptx.items())))
    # PTX ISA 版本
    ver = collections.Counter(re.findall(rb'\.version (\d+\.\d+)', mm))
    print('PTX ISA 版本     :', {k.decode(): v for k, v in sorted(ver.items())})
    mm.close(); f.close()

scan(r'D:\llamacpp\ggml-cuda.dll')
```

输出示例（官方包）：

```
SASS(cubin) 架构 : {86: 1, 89: 1}
PTX  目标架构    : {'50': 12, '61': 3, '70': 480, '75': 40, '80': 200, '90': 123}
PTX ISA 版本     : {'8.4': 858}
```

→ 没有 70 的真机码，PTX 又是 8.4 → **在 536.25 上必然失败**，结论一眼可见。

---

## 六、那升级驱动行不行？

行，但有代价和风险，而且**本仓库的设计前提就是"驱动不动"**：

| 方案 | 代价 |
|---|---|
| 升到 ≥551.61 的驱动 | Volta（CC 7.0）从 R580 之后就不再被支持；且本机实测某些新分支反而认不到卡（见 `docs/05`） |
| 换 CUDA 11.8 的第三方包 | 可行（koboldcpp-oldpc 等），但要换掉接口和整套脚本 |
| **本仓库：自己用 CUDA 12.2 编一份** | 只多花一次编译时间（云端 30–60 分钟），之后零维护 |

NVIDIA 官方口径也支持"不动驱动"这条路：

> *"The NVIDIA driver from branch 580 … will be the final branch that supports GPUs before CC 7.5."*
> 给 pre-CC 7.5 用户的建议：**驱动停在 580 分支 + CUDA 工具包停在 12.9。**

---

## 参考

- llama.cpp 官方 release 工作流：`ggml-org/llama.cpp/.github/workflows/release.yml`
- 官方 Windows CUDA 安装 action：`.github/actions/windows-setup-cuda/action.yml`
- NVIDIA CUDA 组件分发清单：`https://developer.download.nvidia.com/compute/cuda/redist/redistrib_<版本>.json`
- 第三方预编译包逐个核查：见 `docs/02-V100-驱动536.25-CUDA预编译包调研.md`
