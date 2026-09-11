# models/ —— 模型放这里

本仓库**不含任何模型权重**（单个 15 GB 以上，放不进 Git）。

## 用法

把下载好的 `.gguf` 文件直接丢进这个目录，然后双击 `scripts\` 里对应的启动脚本。
脚本里写的是相对路径 `models\xxx.gguf`，所以文件名必须对得上 —— 对不上就改脚本里的 `-m` 那一行。

## 本机实测可用的模型

| 模型 | 量化 | 体积 | 上下文 | 说明 |
|---|---|---|---|---|
| `Qwen3.8-27B-UD-Q4_K_M.gguf` | UD-Q4_K_M | 15.3 GB | 原生 256K | 混合注意力（16 层全注意力 + 48 层线性），长上下文极省显存。三档 64K/128K/256K 全部可全量上卡 |
| `gpt-oss-20b-Q4_K_M.gguf` | Q4_K_M | 11.6 GB | 128K | 思考型模型，实测约 295 tok/s |
| `Qwen3.6-35B-A3B-UD-IQ4_XS.gguf` | UD-IQ4_XS | 17.7 GB | 长上下文 | MoE 架构，激活参数少，速度快 |

## 下载去哪

- **HuggingFace**：搜索模型名 + `GGUF`，选 `unsloth` / `bartowski` / `ggml-org` 这类发布者的量化版本
- 推荐用 `hf` CLI 或 `huggingface-cli download`，断点续传更省心
- 国内网络可先用镜像（如 `hf-mirror.com`）设置 `HF_ENDPOINT` 环境变量

```bash
# 例：HuggingFace 官方 CLI
pip install -U "huggingface_hub[cli]"
hf download <repo_id> <文件名> --local-dir D:\llamacpp\models
```

## 怎么挑量化

| 量化 | 每参数位宽 | 说明 |
|---|---|---|
| `Q8_0` | 8.5 bit | 几乎无损，体积最大 |
| `Q6_K` | 6.6 bit | 很接近无损 |
| **`Q4_K_M`** | 4.5 bit | **甜点**：体积、速度、质量平衡最好，日常首选 |
| `UD-Q4_K_M` | 动态 4 bit | Unsloth 动态量化，重要层保留更高精度，优于普通 Q4_K_M |
| `IQ4_XS` | 4.25 bit | 体积更小，质量略降 |
| `Q3_K_M` 及以下 | ≤3.5 bit | 除非显存实在紧张，不建议 |

> 32 GB 显存的 V100：**27B 级模型用 Q4_K_M 最舒服**；想上更大模型就降到 IQ4_XS 或 Q3_K_M。

## 显存不够怎么办（按优先级）

1. 换更小的量化（Q4_K_M → IQ4_XS → Q3_K_M）
2. 减少上下文长度（`-c`）
3. KV 缓存降到 `q8_0`（`-ctk q8_0 -ctv q8_0`，配 `-fa on`）
4. 确实装不下时，把部分层留在 CPU（减小 `-ngl`）—— 但速度会明显下降，慎用

详细显存推导见 `docs/03`。
