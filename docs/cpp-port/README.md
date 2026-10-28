# GPT-SoVITS 推理 C++ 化验证（P0–P4）

本目录记录把 GPT-SoVITS 推理迁移到 C++ 的验证结果、构建方法与所需补丁。
结论先行：**在本机（Windows + MSYS2 UCRT64，无 MSVC/无 vcpkg）上，C++ + ONNX Runtime 推理链路已跑通**，
相对 Python(torch) 路径首段延迟 −54%、RTF −43%；TensorRT 路径经评估在 4 GB 显存下不可行。

训练、ASR 打标、UVR5 人声分离仍保留在 Python 侧，不在本次范围内。

---

## 1. 验收数据（同机实测）

硬件：i7-12700H / RTX 3050 Ti Laptop 4 GB / 24 GB RAM / Windows。
工具链：MSYS2 UCRT64 `g++ 16.2` + `cmake 4.4.3` + `ninja`，**未使用 MSVC、未使用 vcpkg**。
模型：v2ProPlus（`s1v3.ckpt` + `s2Gv2ProPlus.pth`），CPU 推理。

| 阶段 | 结论 | 关键数据 |
| --- | --- | --- |
| P0 链接冒烟 | 通过 | MinGW 可直接链接 ORT 的 MSVC 导入库（无需 gendef）；`CreateEnv` 成功 |
| P1 导出与对齐 | 通过 | 8 张 ONNX 图与 PyTorch 对齐：最大绝对误差 3.8e-6 ~ 1.1e-5，余弦相似度 ≈ 1 |
| P2 C++ ONNX 推理 | 通过 | 首段 5.24 s、RTF 1.82、峰值内存 4341 MB（CPU）；Python 基线为首段 11.44 s、RTF 3.21 |
| P3 流式 | 通过（有取舍） | chunk 8/24/48 → 首包 1.66 / 3.32 / 5.64 s，RTF 7.55 / 3.73 / 2.46；无爆音 |
| P4 ORT TensorRT EP | 不可行 | GPU 包含 `onnxruntime_providers_tensorrt.dll`，但依赖 CUDA 13（实测缺 `cublas64_13.dll`）；补齐需约 2.4 GB 运行时，且 4 GB 显存装不下全链路引擎 |

逐张图的对齐结果（fp32，CPU）：

| 图 | 指标 |
| --- | --- |
| ssl.onnx | max_abs 7.0e-6，cos 0.9999998 |
| bert.onnx | max_abs 1.1e-5，cos 1.0 |
| vq_encoder.onnx | max_abs 0（完全一致） |
| spectrogram.onnx | max_abs 3.1e-5，cos 1.0 |
| sv_embedding.onnx | max_abs 3.8e-6，cos 1.0 |
| gpt_encoder.onnx | topk 4.5e-6 / k_cache 6.7e-6 / v_cache 6.2e-6 |
| gpt_step.onnx | topk 2.9e-6 / k_cache 5.2e-6 / v_cache 2.9e-6 |
| sovits.onnx | audio max_abs 4.2e-6，cos 0.9999999996 |

> 注意：不要用"两次端到端生成的 wav 相关性"当验收标准。AR 采样与声码器噪声都是随机的，
> 同一实现跑两次结果也不同。正确做法是**同一输入张量分别喂 PyTorch 与 ORT**做图级对齐。

---

## 2. 复现步骤

### 2.1 准备 ONNX Runtime（预编译包，无需编译）

下载 Windows x64 包并解压，例如 `onnxruntime-win-x64-1.31.1.zip`（CPU）或
`onnxruntime-win-x64-gpu_cuda13-1.31.1.zip`（GPU）：

```powershell
# 解压后目录形如：onnxruntime-win-x64-1.31.1/{include,lib}
$ort = "<解压目录>/onnxruntime-win-x64-1.31.1"
```

**重要**：运行时必须把 `onnxruntime.dll` 放在 exe 同级目录。
系统目录里可能存在旧版 `onnxruntime.dll`（本机为 1.17.1），会先于 PATH 被加载，
导致 `GetApi()` 返回 null。

### 2.2 导出 ONNX 模型

使用上游 `GPT-SoVITS-Devel/GPT-SoVITS_minimal_inference` 的 `export_onnx.py`（本仓库自带的
`GPT_SoVITS/onnx_export.py` 只覆盖 v1/v2 且只导出 t2s/vits 四张图，不足以给 C++ 侧使用）：

```powershell
python export_onnx.py `
  --gpt_path    <s1v3.ckpt> `
  --sovits_path <s2Gv2ProPlus.pth> `
  --cnhubert_base_path <chinese-hubert-base> `
  --bert_path   <chinese-roberta-wwm-ext-large> `
  --sv_path     <pretrained_eres2netv2w24s4ep4.ckpt> `
  --output_dir  <输出目录> --max_len 1000 --validate --validation_device cpu
```

导出 8 张图：`ssl / bert / vq_encoder / gpt_encoder / gpt_step / sovits / spectrogram / sv_embedding` + `config.json`。

导出脚本内置校验器的"相对误差"在接近 0 的元素上会放大导致判负，**以绝对误差和余弦相似度为准**。

### 2.3 获取并补丁化 C++ 工程

```powershell
git clone https://github.com/GPT-SoVITS-Devel/GPT-SoVITS-cpp.git
# 子模块（含两层嵌套）建议用 codeload tarball 拉取，git 协议在部分网络下极慢
git apply --check docs/cpp-port/patches/0001-mingw-gcc-compat.patch
git apply          docs/cpp-port/patches/0001-mingw-gcc-compat.patch
```

补丁基于 `384a2f9`（GPT-SoVITS-cpp master）生成，覆盖主仓库与 4 个子模块里的 18 个文件。
补丁按 LF 行尾生成：若目标检出为 CRLF，`git apply` 会按 `core.autocrlf` 处理；
改用 `patch` 命令时请加 `--binary`，避免它把 CRLF 剥成 LF 造成整文件 diff。

补丁内容见第 3 节。

### 2.4 构建（MinGW + Ninja）

```powershell
cmake -S . -B build-ort-cpu -G Ninja `
  -DCMAKE_BUILD_TYPE=Release `
  -DCMAKE_C_COMPILER=gcc -DCMAKE_CXX_COMPILER=g++ `
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 `
  -DCMAKE_TLS_CAINFO=<cacert.pem> `
  -DUSE_ONNX=ON -DUSE_TENSORRT=OFF -DENABLE_CUDA=OFF `
  -DONNXRUNTIME_PATH=<onnxruntime 解压目录> `
  -DCPP_PINYIN_BUILD_TESTS=OFF -DCPP_PINYIN_INSTALL=OFF -DBUILD_TESTING=OFF

cmake --build build-ort-cpu -j 8
# 若并行构建时 res/ 目录复制报错（多目标并发 copy_directory），用 -j 1 重跑即可
```

### 2.5 运行

```powershell
# 1) 创建说话人数据包（参考音频 + 参考文本）
.\build-ort-cpu\gpt_sovits_cpp_cloud_create_onnx.exe speaker_zh ref.wav "<参考文本>" zh speaker_zh.gsppkg

# 2) 非流式推理
.\build-ort-cpu\gpt_sovits_cpp_edge_inference_onnx.exe speaker_zh.gsppkg "<文本>" zh speaker_zh out.wav

# 3) 流式推理
.\build-ort-cpu\gpt_sovits_cpp_streaming_onnx.exe `
  --speaker-package speaker_zh.gsppkg --lang zh --speaker-name speaker_zh `
  --chunk-length 24 --output stream.wav
```

> 示例程序里的 `MODEL_PATH` 需指向 2.2 的导出目录；Windows 下设备应改为 `kCPU`（无 GPU 时）。

---

## 3. 为在 MinGW/GCC 下编译所做的补丁

上游工程面向 MSVC，MinGW + GCC 16 下需要 11 类改动（全部包含在
`patches/0001-mingw-gcc-compat.patch`）：

| # | 文件 | 改动 | 原因 |
| --- | --- | --- | --- |
| 1 | `cmake/boost-cmake.cmake` | 改为 header-only INTERFACE target | 上游在 Windows 下 `ENABLE_LANGUAGE(ASM_MASM)`，无 MSVC 必失败；工程实际只用 `boost/algorithm/string.hpp` |
| 2 | `third_party/tokenizers-cpp/CMakeLists.txt` | 非 MSVC 时 Rust 目标用 `x86_64-pc-windows-gnu` | 写死 msvc 目标，MSYS2 rustc 无对应 std |
| 3 | `.../sentencepiece_processor.h` | 补 `<cstdint>` | GCC 16 不再隐式包含 |
| 4 | `.../tokenizers_cpp.h` | 补 `<cstdint>` | 同上 |
| 5 | `backend_config.h` | `kTensorRT` 常驻枚举 | 未启用 TRT 时调用处也在引用 |
| 6 | `src/Core/ModelPool.cpp` | 8 处 TRT 分支加 `#ifdef WITH_TENSORRT` | 同上 |
| 7 | `src/InferencePipeline.cpp` | `use_trt` 与 BERT 后端分支加 `#ifdef` | 同上 |
| 8 | `src/model/backend/tensorrt_backend.cpp` | 删除依赖未声明类的 `!WITH_TENSORRT` 存根块 | 类本身被 `#ifdef WITH_CUDA` 包住 |
| 9 | `Precision.h` / `spectrogram.h` / `sovits.cpp` / `cld2 compact_lang_det.h` | 补 `<cmath>` / `exception.h` / `<algorithm>` / `<cstdio>` | 缺头文件 |
| 10 | `src/g2p/g2p_en.cpp`、`polyphonic.cpp`、`LangDetect.cpp` | `std::ifstream(path.wstring())` → `std::ifstream(path)` | `wstring` 构造函数是 MSVC 扩展 |
| 11 | `example/onnx/*.cpp` | 模型路径/设备改为本机 CPU；文本从 UTF-8 文件读取 | 示例写死作者机器路径；见下节 |

---

## 4. 已知坑

1. **DLL 遮盖**：系统目录的旧 `onnxruntime.dll` 会抢先加载，必须放 exe 同级。
2. **argv 编码**：Windows + MinGW 的窄字符 `argv` 按 ANSI(GBK) 解码，中文参数进入程序后不是合法 UTF-8
   （表现为 `Invalid UTF-8`）。中文文本请通过 UTF-8 文件传入，或改用宽字符入口。
3. **CMake FetchContent 证书**：cpptrace 会下载 zstd/libdwarf，MSYS2 的 CA 路径失效时用
   `-DCMAKE_TLS_CAINFO=<cacert.pem>`。
4. **嵌套子模块**：libsndfile 需要 `third_party/{ogg,flac,vorbis}`，tokenizers-cpp 需要
   `{msgpack,sentencepiece}`；tarball 方式拉取时不会自动带下来。
5. **并行构建偶发失败**：多个可执行目标并发 `copy_directory(res)` 会报路径不存在，`-j 1` 重跑即可。
6. **流式输出未做 RMS 归一化**：流式 wav 峰值约 0.12，非流式 0.9，部署时需自行增益。
7. **流式的 RTF 代价**：每块都重跑声码器（带历史上下文），CPU 上 chunk=8 时 RTF 7.5；
   GPU 场景建议 chunk 16–24。

---

## 5. 未纳入范围

- **v3/v4 的 BigVGAN 声码器**：本仓库没有导出路径，本次验证基于 v2ProPlus。
- **TensorRT（P4）**：需要 CUDA 13 运行时（`cublas64_13.dll` 等）+ TensorRT 10.x（约 1.55 GB）
  + cuDNN（约 400 MB），且 4 GB 显存无法承载全链路引擎；只对 `gpt_step` 单独启用才可能塞下。
- **训练 / ASR / UVR5**：仍为 Python 实现，C++ 化收益低，不建议迁移。
