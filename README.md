<div align="center">

<h1>GPT-SoVITS-WebUI</h1>
少样本语音转换与文本转语音 WebUI（Windows 本机适配版）<br><br>

[![madewithlove](https://img.shields.io/badge/made_with-%E2%9D%A4-red?style=for-the-badge&labelColor=orange)](https://github.com/RVC-Boss/GPT-SoVITS)

<a href="https://trendshift.io/repositories/7033" target="_blank"><img src="https://trendshift.io/api/badge/repositories/7033" alt="RVC-Boss%2FGPT-SoVITS | Trendshift" style="width: 250px; height: 55px;" width="250" height="55"/></a>

[![Python](https://img.shields.io/badge/python-3.10--3.12-blue?style=for-the-badge&logo=python)](https://www.python.org)
[![GitHub release](https://img.shields.io/github/v/release/RVC-Boss/gpt-sovits?style=for-the-badge&logo=github)](https://github.com/RVC-Boss/gpt-sovits/releases)

[![Train In Colab](https://img.shields.io/badge/Colab-Training-F9AB00?style=for-the-badge&logo=googlecolab)](https://colab.research.google.com/github/RVC-Boss/GPT-SoVITS/blob/main/Colab-WebUI.ipynb)
[![Huggingface](https://img.shields.io/badge/免费在线体验-free_online_demo-yellow.svg?style=for-the-badge&logo=huggingface)](https://lj1995-gpt-sovits-proplus.hf.space/)
[![Image Size](https://img.shields.io/badge/docker-image_size-blue?style=for-the-badge&logo=docker)](https://hub.docker.com/r/xxxxrt666/gpt-sovits)

[![简体中文](https://img.shields.io/badge/简体中文-阅读文档-blue?style=for-the-badge&logo=googledocs&logoColor=white)](https://www.yuque.com/baicaigongchang1145haoyuangong/ib3g1e)
[![English](https://img.shields.io/badge/English-Read%20Docs-blue?style=for-the-badge&logo=googledocs&logoColor=white)](https://rentry.co/GPT-SoVITS-guide#/)
[![Change Log](https://img.shields.io/badge/Change%20Log-View%20Updates-blue?style=for-the-badge&logo=googledocs&logoColor=white)](https://github.com/RVC-Boss/GPT-SoVITS/blob/main/docs/en/Changelog_EN.md)
[![License](https://img.shields.io/badge/LICENSE-MIT-green.svg?style=for-the-badge&logo=opensourceinitiative)](https://github.com/RVC-Boss/GPT-SoVITS/blob/main/LICENSE)

**中文简体（本页）** | [**English**](https://github.com/RVC-Boss/GPT-SoVITS/blob/main/README.md) | [**日本語**](https://github.com/RVC-Boss/GPT-SoVITS/blob/main/docs/ja/README.md) | [**한국어**](https://github.com/RVC-Boss/GPT-SoVITS/blob/main/docs/ko/README.md) | [**Türkçe**](https://github.com/RVC-Boss/GPT-SoVITS/blob/main/docs/tr/README.md)

</div>

---

## 关于本仓库

**上游项目**：[RVC-Boss/GPT-SoVITS](https://github.com/RVC-Boss/GPT-SoVITS) —— 少样本语音转换与文本转语音 WebUI，支持中/英/日/韩/粤跨语种推理，集成人声/伴奏分离、多语种 ASR 打标、数据集制作、微调训练与推理全流程（MIT 协议）。

本仓库是它的本地克隆，基线为 `48b1a01`（2026-08-18，*Fix Fun-ASR-Nano Transformers requirement (#2824)*），并针对「**无 conda + 无 MSVC + 国内网络**」的机器做了安装适配。

> 本仓库只保留中文文档：上游的英/日/韩/土 README 已移除，需要时见 [上游仓库](https://github.com/RVC-Boss/GPT-SoVITS)。
> 完整中文文档（预训练模型、数据集格式、微调与推理、各版本 Release Notes、第三方项目致谢等）见 **[docs/cn/README.md](./docs/cn/README.md)**。

### 本仓库的改动

| 文件 | 说明 |
| --- | --- |
| `install.ps1` | **重写**。上游脚本第一步强制 `conda install ffmpeg cmake`、且只支持 MSVC 编译，在没有 conda / MSVC 的机器上直接失败。现在改为：免 conda（工具检测优先，有就直接用）、没有 MSVC 时自动用 MSYS2 的 `g++` 编译 `jieba_fast` 与 `pyopenjtalk`（这两个包 PyPI 上没有 Windows 轮子）、模型权重默认从 ModelScope 下载并自动测速选源、自动固定会被 pip 拉高而冲突的依赖版本。全程幂等，可反复运行。 |
| `.gitignore` | 新增本机安装产物与运行期生成物的忽略规则。 |
| `go-webui.ps1` / `go-webui.bat` | **改写**。优先用仓库内的 `.venv`，找不到再回退官方整合包的 `runtime\python.exe`，两者都不存在时给出可操作提示。 |
| `go-webui-venv.ps1` | **新增**。显式用 `.venv` 启动 WebUI（等价于 `go-webui.ps1` 的 venv 分支），排错时可跳过回退逻辑。 |
| `README.md` | 改写为中文，只保留项目介绍、本仓库改动与安装说明；上游英文内容不再内嵌，改为链接到上游与本仓库中文文档。 |

除以上文件外，代码与上游 `48b1a01` 一致；仅有 7 份非代码 README 文档未纳入：上游 `docs/ja|ko|tr/README.md`、`GPT_SoVITS/BigVGAN/README.md`、`GPT_SoVITS/f5_tts/model/backbones/README.md`、`GPT_SoVITS/text/zh_normalization/README.md`、`tools/AP_BWE_main/README.md`。

---

## 功能概览

1. **零样本 TTS**：输入 5 秒人声样本即可直接合成目标音色。
2. **少样本微调**：仅需 1 分钟训练数据即可微调，显著提升音色相似度与自然度。
3. **跨语种推理**：可用与训练集不同的语言推理，支持中、英、日、韩、粤。
4. **WebUI 工具链**：人声/伴奏分离、自动切分训练集、多语种 ASR 打标（Fun-ASR-Nano / SenseVoice / FunASR）、文本标注等，覆盖从数据制作到训练推理的全流程。

更多细节（演示、速度数据、各版本 Release Notes）见 [docs/cn/README.md](./docs/cn/README.md)。

---

## 安装

### 前置条件

- Windows + Python 3.10–3.12
- `ffmpeg` 已加入 PATH（也可把 `ffmpeg.exe` / `ffprobe.exe` 直接放到仓库根目录）
- 编译器：有 MSVC 则直接用；**没有 MSVC 时需要 MSYS2 的 `gcc` / `g++` / `cmake`**
  （`jieba_fast`、`pyopenjtalk` 在 PyPI 上没有 Windows 预编译轮子，必须本地编译）

### 一键安装

```powershell
git clone https://github.com/ycm50/sovit-my.git
cd sovit-my
pwsh -File install.ps1                 # 默认 CU128 + 自动选源 + 下载全部模型（约 6 GB）
```

常用参数：

| 参数 | 说明 |
| --- | --- |
| `-Device CU126\|CU128\|CPU` | 目标设备，默认 `CU128` |
| `-Source Auto\|ModelScope\|HF-Mirror\|HF` | 模型下载源，默认 `Auto`（先测速再选最快的） |
| `-DownloadUVR5` | 额外下载 UVR5 人声/伴奏分离权重 |
| `-SkipModels` / `-SkipTorch` / `-SkipDeps` / `-SkipBuild` | 分步执行，便于排错或只补下模型 |
| `-VenvPath <目录>` | 安装到指定虚拟环境（默认 `.venv`），可用于隔离验证 |

脚本依次完成：

1. 创建 / 复用 `.venv`，升级 pip 与 setuptools（setuptools 需满足 torch 的 `<82` 约束）
2. 从国内镜像安装 CUDA 版 PyTorch（默认上海交大镜像，失败自动回退官方源）
3. 编译 `jieba_fast`（无 Windows 轮子）与 `pyopenjtalk`（需 CMake；默认走 MinGW，并补齐运行时 DLL 与 open_jtalk 词典）
4. 预装 `opencc` 二进制轮子，绕开 `requirements.txt` 里的 `--no-binary=opencc` 源码编译
5. 安装 `requirements.txt` 与 `extra-req.txt`
6. 固定 `fastapi==0.115.2`（携带 `starlette<0.41`，兼容 gradio 4.44）与匹配 torch CUDA 大版本的 `onnxruntime-gpu`
7. 下载模型权重（主模型 / G2PW / nltk 数据，可选 UVR5），支持断点续传与大小校验

每一步的判断依据与踩坑原因都写在 `install.ps1` 的头部注释里。

### 启动

```powershell
pwsh -File .\go-webui-venv.ps1          # 等价于 .\.venv\Scripts\python.exe webui.py
# 或者：自动优先 .venv，找不到再用整合包 runtime
pwsh -File .\go-webui.ps1
```

浏览器打开终端提示的地址（默认 `http://127.0.0.1:9874`，改端口见 `config.py` 的 `webui_port_main`）。

> **显存提示**：≤4 GB 时推理可用但建议控制单次文本长度；微调训练会很吃力，建议改用 CPU 或云端。

---

## 文档索引

| 内容 | 位置 |
| --- | --- |
| 完整中文文档：安装、预训练模型、数据集格式、微调与推理、各版本说明、第三方致谢 | [docs/cn/README.md](./docs/cn/README.md) |
| 命令行推理 | [docs/cn/README.md](./docs/cn/README.md) 的「(附加) 命令行运行方式」 |
| 上游英文文档 | [GitHub](https://github.com/RVC-Boss/GPT-SoVITS/blob/main/README.md) |
| 更新日志 | [docs/en/Changelog_EN.md](./docs/en/Changelog_EN.md) |
| 安装脚本每一步的判断依据与踩坑记录 | `install.ps1` 头部注释（本机安装日志不入库） |

## 许可

本项目遵循上游的 MIT 协议，详见 [LICENSE](./LICENSE)。第三方项目致谢见 [docs/cn/README.md](./docs/cn/README.md) 的致谢章节。
