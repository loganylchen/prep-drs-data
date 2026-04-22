# prep-drs-data — Nanopore DRS 原始数据预处理流程

一个用于 Nanopore Direct RNA Sequencing (DRS) 原始数据预处理的 Bash 流程。
接受 fast5 或 pod5 输入，根据试剂盒类型自动选择 dorado-legacy 0.9.6（RNA001/RNA002）或 dorado 1.4（RNA004）进行 basecalling，
并输出标准化的 per-sample 目录结构：合并后的 FASTQ、BLOW5 信号文件、以及整理好的原始数据。
所有依赖工具都打包在提供的 Dockerfile 中。

---

## 目录

1. [输出目录结构](#输出目录结构)
2. [系统要求](#系统要求)
3. [工具准备](#工具准备)
4. [构建 Docker 镜像](#构建-docker-镜像)
5. [运行流程](#运行流程)
6. [CLI 参数说明](#cli-参数说明)
7. [典型使用场景](#典型使用场景)
8. [本地运行（不用 Docker）](#本地运行不用-docker)
9. [批量处理多个样品](#批量处理多个样品)
10. [输出验证](#输出验证)
11. [常见问题排查](#常见问题排查)
12. [退出码含义](#退出码含义)
13. [流程内部阶段](#流程内部阶段)
14. [项目结构](#项目结构)
15. [测试](#测试)

---

## 输出目录结构

运行成功后，对于样品名 `SAMPLE01`，会在 `--output` 指定的目录下生成：

```
<output>/SAMPLE01/
├── fastq/
│   └── pass.fq.gz              # 合并后的 pass reads（gzip 压缩的 FASTQ）
├── blow5/
│   └── nanopore.drs.blow5      # 合并后的 BLOW5 信号文件
└── fast5/    ← 或 pod5/        # 移动（或复制）过来的原始数据
```

> 顶层目录名 = 样品名，下一层是 `fastq` / `blow5` / `fast5 或 pod5` 三个子目录，完全符合你提出的要求。

---

## 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Linux（Ubuntu 20.04+ 或 22.04 推荐） |
| GPU | NVIDIA GPU（Pascal 架构及以上，VRAM ≥ 8GB 推荐） |
| 驱动 | NVIDIA Driver ≥ 525（支持 CUDA 11.8） |
| Docker | 20.10+ |
| NVIDIA Container Toolkit | 已安装并配置 |
| 磁盘空间 | 至少 3× 原始数据大小的空闲空间 |
| 内存 | ≥ 16 GB |

**验证 GPU 支持：**

```bash
# 宿主机
nvidia-smi

# Docker + GPU
docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi
```

上面两条命令都能输出 GPU 信息才说明环境正确。

---

## 工具准备

所有 basecaller（dorado 1.4 + dorado 0.9.6）、信号转换工具和模型文件都由 Dockerfile 自动下载，
**不需要任何手动操作**。

### dorado（当前版本，RNA004 basecalling）— 自动下载

构建镜像时 Dockerfile 会自动从 ONT CDN 下载 dorado 1.4.0 以及三个档位的 RNA004 模型
（`rna004_130bps_{fast,hac,sup}@v5.2.0`）。

### dorado-legacy（0.9.6，RNA001/RNA002 basecalling）— 自动下载

dorado 0.9.6 是 **最后一个支持 RNA002 basecalling 并且仍然接受 fast5 输入** 的版本。
Dockerfile 会把它安装为 `/usr/local/bin/dorado-legacy`，与 `dorado`（1.4.0）共存，并预先下载
`rna002_70bps_hac@v3` 模型。

> 📌 **为什么不用 guppy？** guppy 已被 ONT 归档，发布时需要登录 ONT Community 账号，
> 不便于自动化构建。dorado-legacy 0.9.6 能完整覆盖 RNA001/RNA002 的需求，且在 ONT CDN 上
> 公开可下载。

---

## 构建 Docker 镜像

```bash
cd /path/to/prep-drs-data
docker build -t prep-drs:latest .
```

构建耗时约 **15–40 分钟**，取决于网络速度和宿主机性能。主要耗时在：

- 下载 dorado 1.4.0（约 300 MB）
- 下载 dorado 0.9.6（legacy，约 250 MB）
- 下载 3 个 RNA004 模型（约 2–4 GB，已内嵌到镜像中，运行时不需再联网）
- 下载 RNA002 模型 `rna002_70bps_hac@v3`（约 30 MB）
- 下载 slow5tools（约 50 MB）
- `pip install blue-crab pod5`

最终镜像大小约 **9–13 GB**。

**验证构建成功：**

```bash
docker run --rm prep-drs:latest --help
```

应该打印出 `Usage: prep_drs.sh --sample NAME ...` 并正常退出。

---

## 运行流程

### 通用调用模板

```bash
docker run --rm --gpus all \
  -v /宿主机/原始数据目录:/in:ro \
  -v /宿主机/输出目录:/out \
  prep-drs:latest \
  --sample <样品名> \
  --input /in \
  --kit <rna001|rna002|rna004> \
  --output /out
```

**参数解释：**

| Docker 参数 | 含义 |
|-------------|------|
| `--rm` | 运行结束自动删除容器 |
| `--gpus all` | 把宿主机所有 GPU 暴露给容器（必需） |
| `-v /host:/in:ro` | 把原始数据目录只读挂载到容器的 `/in` |
| `-v /host:/out` | 把输出目录可读写挂载到容器的 `/out` |

---

## CLI 参数说明

### 必需参数

| 参数 | 说明 |
|------|------|
| `--sample NAME` | 样品名；作为输出目录的顶层子目录名 |
| `--input DIR` | 原始数据目录，会递归查找 `*.fast5` 或 `*.pod5` |
| `--kit KIT` | 试剂盒类型：`rna001` / `rna002` / `rna004` |
| `--output DIR` | 输出根目录 |

### 可选参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `--threads N` | `nproc` | 并行线程数（影响 slow5tools merge、pigz 等） |
| `--model-tier T` | `hac` | basecalling 精度：`fast` / `hac` / `sup` |
| `--device D` | `cuda:0` | GPU 设备（多卡可用 `cuda:0,cuda:1`） |
| `--copy` | 关 | 复制原始数据而不是移动（占用双倍空间，但不改动源目录） |
| `--zstd` | 关 | BLOW5 使用 zstd 压缩（默认 zlib，兼容性更好） |
| `--force` | 关 | 即使输出已存在也重跑 |
| `--keep-tmp` | 关 | 保留中间文件目录 `.tmp`（调试用） |
| `--help` | — | 打印帮助并退出 |

> **注意 `--sample` 的安全限制**：不允许出现 `/`、`.`、`..`、控制字符。
> 例如 `--sample "../evil"` 会被直接拒绝（退出码 1），防止路径穿越。

---

## 典型使用场景

### 场景 1：RNA002 数据，输入是 fast5（最常见的旧数据）

```bash
docker run --rm --gpus all \
  -v /data/seq/run_2023_05:/in:ro \
  -v /data/drs_prep:/out \
  prep-drs:latest \
  --sample PatientA_RNA002 \
  --input /in \
  --kit rna002 \
  --output /out
```

预期输出：`/data/drs_prep/PatientA_RNA002/{fastq,blow5,fast5}/`

### 场景 2：RNA004 数据，输入是 pod5（最常见的新数据）

```bash
docker run --rm --gpus all \
  -v /data/seq/run_2025_03:/in:ro \
  -v /data/drs_prep:/out \
  prep-drs:latest \
  --sample PatientB_RNA004 \
  --input /in \
  --kit rna004 \
  --output /out \
  --model-tier sup \
  --threads 32
```

### 场景 3：RNA002 但数据是 pod5（新版 MinKNOW 输出）

dorado-legacy 0.9.6 原生支持 pod5，无需转换：

```bash
docker run --rm --gpus all \
  -v /data/seq/run_2024_08:/in:ro \
  -v /data/drs_prep:/out \
  prep-drs:latest \
  --sample SampleC_RNA002 \
  --input /in \
  --kit rna002 \
  --output /out \
  --copy              # 保留原始 pod5 副本，不移动
```

### 场景 4：RNA004 但数据是 fast5（较少见）

流程会自动把 fast5 转成 pod5，再喂给 dorado：

```bash
docker run --rm --gpus all \
  -v /data/old_rna004_fast5:/in:ro \
  -v /data/drs_prep:/out \
  prep-drs:latest \
  --sample SampleD_RNA004 \
  --input /in \
  --kit rna004 \
  --output /out
```

---

## 本地运行（不用 Docker）

如果宿主机已经装好了所有依赖（dorado、dorado-legacy、slow5tools、blue-crab、pod5、pigz），可以直接本地跑：

```bash
cd /path/to/prep-drs-data
./prep_drs.sh \
  --sample TEST01 \
  --input /data/raw_fast5 \
  --kit rna002 \
  --output ./output
```

脚本会自动找 `./lib/` 下的三个库文件。

依赖检查（哪些要装）：

| 试剂盒 | 输入 | 必需工具 |
|--------|------|---------|
| rna001/rna002 | fast5 | `dorado-legacy`, `slow5tools`, `pigz` |
| rna001/rna002 | pod5 | `dorado-legacy`, `slow5tools`, `blue-crab`, `pigz` |
| rna004 | pod5 | `dorado`, `slow5tools`, `blue-crab`, `pigz` |
| rna004 | fast5 | `dorado`, `slow5tools`, `pod5`, `pigz` |

---

## 批量处理多个样品

每次调用只处理一个样品。处理多个样品可以写个简单的 wrapper：

```bash
#!/usr/bin/env bash
# batch_run.sh
set -euo pipefail

IMAGE=prep-drs:latest
OUTPUT=/data/drs_prep

declare -A SAMPLES=(
  ["PatientA"]="/data/raw/runA:rna002"
  ["PatientB"]="/data/raw/runB:rna004"
  ["PatientC"]="/data/raw/runC:rna002"
)

for sample in "${!SAMPLES[@]}"; do
  IFS=':' read -r input_dir kit <<< "${SAMPLES[$sample]}"
  echo ">>> Processing ${sample} (${kit})"

  docker run --rm --gpus all \
    -v "${input_dir}":/in:ro \
    -v "${OUTPUT}":/out \
    "${IMAGE}" \
    --sample "${sample}" \
    --input /in \
    --kit "${kit}" \
    --output /out \
    --copy
done
```

由于脚本本身支持 **幂等**（输出已存在会自动跳过），失败后重跑整个批次也是安全的。
如果要强制重跑，加 `--force`。

---

## 输出验证

### 检查 FASTQ

```bash
# 检查 gzip 完整性
gzip -t /out/SAMPLE01/fastq/pass.fq.gz && echo "OK"

# 看前几条 reads
zcat /out/SAMPLE01/fastq/pass.fq.gz | head -8

# 统计 read 数量
echo $(( $(zcat /out/SAMPLE01/fastq/pass.fq.gz | wc -l) / 4 ))
```

### 检查 BLOW5

```bash
# 在容器里
docker run --rm -v /out:/out prep-drs:latest bash -c \
  'slow5tools quickcheck /out/SAMPLE01/blow5/nanopore.drs.blow5 && echo OK'

# 或者宿主机装了 slow5tools
slow5tools quickcheck /out/SAMPLE01/blow5/nanopore.drs.blow5
slow5tools stats /out/SAMPLE01/blow5/nanopore.drs.blow5
```

### 检查原始数据

```bash
ls /out/SAMPLE01/fast5/ | head    # 或 pod5/
du -sh /out/SAMPLE01/*/           # 看各子目录大小
```

---

## 常见问题排查

### 错误：`nvidia-smi: not available`（退出码 3）

**原因**：容器没拿到 GPU。

**解决**：
1. 确认宿主机 `nvidia-smi` 能用
2. 确认已装 NVIDIA Container Toolkit：`sudo apt install nvidia-container-toolkit && sudo systemctl restart docker`
3. 确认运行时加了 `--gpus all`

### 错误：`Mixed input formats` / `no fast5 or pod5 files found`（退出码 4）

**原因**：`--input` 目录里同时有 fast5 和 pod5，或者两种都没有。

**解决**：把 fast5 和 pod5 分到两个不同目录，分别作为两个样品处理；或者删掉不要的那种。

### 错误：`dorado-legacy: command not found`

**原因**：镜像构建失败或被手改过。dorado-legacy 0.9.6 应该由 Dockerfile 自动安装。

**解决**：重新 `docker build`，确保 `dorado-legacy` 下载步骤没有出错。

### 错误：`dorado: model download failed`

**原因**：构建镜像时没联网。

**解决**：在能联网的机器上构建，然后 `docker save prep-drs:latest > prep-drs.tar` 再 `docker load` 到目标机器。

### 错误：`mv: cannot move ... : Invalid cross-device link`

**原因**：`--input` 和 `--output` 在不同文件系统，`mv` 不能跨挂载点。

**解决**：加 `--copy` 改成复制；或者把输入输出放到同一挂载点下。

### 错误：磁盘空间不足

**原因**：pod5 ↔ fast5 转换、basecalling、BLOW5 merge 都会临时占用磁盘。

**解决**：确保 `--output` 所在磁盘有至少 **3 倍原始数据大小** 的空闲空间。

### 错误：`--sample` 被拒绝

**原因**：样品名含有 `/`、`.`、`..` 或控制字符（防路径穿越的安全检查）。

**解决**：只用字母、数字、下划线、短横线。

### dorado 跑得很慢

**可能原因**：
- 使用了 `--model-tier sup`（最准但最慢）
- GPU 被其他任务占用：检查 `nvidia-smi`

**加速方法**：
- 改用 `--model-tier hac`（默认）或 `fast`
- 增大 `--threads`
- 多 GPU 环境下用 `--device cuda:0,cuda:1`

---

## 退出码含义

| 退出码 | 含义 |
|--------|------|
| 0 | 成功 |
| 1 | 参数错误 |
| 2 | 依赖工具未找到 |
| 3 | 无 GPU / nvidia-smi 失败 |
| 4 | 输入错误（空目录、混合格式、不可读） |
| 5 | Basecalling 失败 |
| 6 | 信号格式转换失败 |
| 7 | 完整性检查失败（gzip -t 或 slow5tools quickcheck） |
| 8 | 原始文件移动/复制失败 |

脚本失败后退出码可以直接用于 shell 的 `if [[ $? -eq 5 ]]; then ...; fi` 分支处理。

---

## 流程内部阶段

`prep_drs.sh` 依次执行以下阶段，任何一步失败都会立即退出：

1. **参数解析与验证** — 检查必需参数、试剂盒类型、模型档位、样品名合法性
2. **依赖和 GPU 检查** — 根据 kit 和输入格式动态决定要检查哪些工具
3. **输入格式检测** — 递归统计 `*.fast5` / `*.pod5`，决定走哪条分支
4. **准备输出目录** — 创建 `fastq/`、`blow5/`、`fast5/` 或 `pod5/`、`.tmp/`；已有输出时幂等跳过（`--force` 可覆盖）
5. **Basecalling** —
   - RNA001/RNA002 → `dorado-legacy` 0.9.6（原生支持 fast5 与 pod5，无需预转换）
   - RNA004 → `dorado` 1.4（若输入是 fast5，先转 pod5）
6. **FASTQ 输出** — dorado / dorado-legacy 直接以 `--emit-fastq` 管道到 pigz，写成 `pass.fq.gz`
7. **FASTQ 完整性检查** — `gzip -t`
8. **信号转 BLOW5** — fast5 用 `slow5tools f2s`，pod5 用 `blue-crab p2s`
9. **BLOW5 合并** — `slow5tools merge` 成单文件 `nanopore.drs.blow5`
10. **BLOW5 完整性检查** — `slow5tools quickcheck`
11. **原始文件归位** — 把 `*.fast5` 或 `*.pod5` move（默认）或 copy（`--copy`）进 `fast5/`/`pod5/`
12. **清理** — 删 `.tmp`（除非 `--keep-tmp`），打印耗时与输出清单

---

## 项目结构

```
prep-drs-data/
├── prep_drs.sh                 # 主入口脚本
├── lib/
│   ├── utils.sh                # 日志、参数解析、GPU/输入检查
│   ├── basecall.sh             # dorado + dorado-legacy 封装、fast5→pod5 转换
│   └── signal_convert.sh       # slow5tools + blue-crab 封装、完整性检查
├── Dockerfile                  # 所有工具的容器镜像
├── .dockerignore
├── README.md                   # 本文档
├── examples/
│   └── run_example.sh          # 四个示例调用
└── test/
    ├── test_cli.sh             # CLI 冒烟测试（19 个测试用例）
    └── fixtures/
        └── README.md           # 端到端测试数据的组织说明
```

---

## 测试

### 冒烟测试（不需要 GPU 或真实数据）

```bash
cd /path/to/prep-drs-data
bash test/test_cli.sh
```

验证 CLI 参数解析、帮助文本、路径穿越防护、输入验证等。预期 **19/19 通过**。

### 端到端测试（需要 GPU 和真实数据）

参见 `test/fixtures/README.md` 的说明，从 [ONT 开放数据集](https://github.com/nanoporetech/ont_open_datasets)
下载小规模 DRS 样本，放到 `test/fixtures/` 下运行完整流程。

---

## 版本信息

| 组件 | 版本 |
|------|------|
| Docker base | `nvidia/cuda:11.8.0-cudnn8-runtime-ubuntu22.04` |
| dorado（当前版，RNA004） | 1.4.0 |
| dorado-legacy（RNA001/RNA002） | 0.9.6（最后一个支持 RNA002 且接受 fast5 输入的版本） |
| dorado RNA004 模型 | `rna004_130bps_{fast,hac,sup}@v5.2.0` |
| dorado RNA002 模型 | `rna002_70bps_hac@v3`（仅 hac 档，由 legacy 版下载） |
| slow5tools | 1.4.0 |
| blue-crab | pip 最新 |
| pod5 | pip 最新 |

---

## 鸣谢

- [Oxford Nanopore Technologies](https://nanoporetech.com/) — dorado, pod5
- [hasindu2008/slow5tools](https://github.com/hasindu2008/slow5tools) — fast5 → BLOW5 转换与合并
- [Psy-Fer/blue-crab](https://github.com/Psy-Fer/blue-crab) — pod5 → BLOW5 直接转换

---

## License

见 `LICENSE`。
