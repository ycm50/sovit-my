#Requires -Version 5.1
<#
.SYNOPSIS
    GPT-SoVITS Windows 一键安装脚本（本机适配版）

.DESCRIPTION
    与官方 install.ps1 的区别（针对「无 conda、无 MSVC、国内网络」的环境）：

      1. 不依赖 conda。官方脚本第一步就是 `conda install ffmpeg cmake`，没装 conda 直接报错；
         这里改为「检测优先」：ffmpeg / cmake / 编译器 有就直接用，缺了才给提示或尝试 conda。
      2. 没有 MSVC 时自动改用 MSYS2 的 g++(MinGW-w64/UCRT64) 编译两个没有 Windows 轮子的包：
           - jieba_fast  (PyPI 全版本只有 sdist，且代码里是硬依赖)
           - pyopenjtalk (PyPI 全版本只有 sdist，官方要求 MSVC + CMake)
         关键点两个：CFLAGS 环境变量对 mingw32 编译器不生效，必须用 distutils.cfg 指定编译器；
         并且必须定义 MS_WIN64，否则 Python 官方 pyconfig.h 会把指针宽度当成 32 位而编译失败。
      3. 模型权重默认从 ModelScope 下载（实测 5.4 MB/s，比 HF-Mirror 快约 25 倍），
         -Source Auto 会先给各源测速再挑最快的。
      4. 固定几个会被 pip 拉到高版本后互相冲突的依赖（详见 Install 第 8 步注释）。
      5. 全程幂等：已完成的步骤自动跳过，可以反复运行。

.PARAMETER Device
    目标设备：CU126 / CU128 / CPU，默认 CU128。
.PARAMETER Source
    模型下载源：Auto(默认) / ModelScope / HF-Mirror / HF。
.PARAMETER DownloadUVR5
    额外下载 UVR5 人声/伴奏分离权重（约 500 MB）。
.PARAMETER VenvPath
    虚拟环境目录，默认仓库下的 .venv。
.PARAMETER PipIndex
    PyPI 镜像，默认 USTC（本网络实测 6–20 MB/s）。
.PARAMETER TorchIndex
    PyTorch 轮子索引。留空则按 Device 自动选择（默认走 SJTU 镜像，失败自动回退官方源）。
.PARAMETER SkipTorch / SkipDeps / SkipBuild / SkipModels
    分别跳过 torch / 依赖 / 编译扩展 / 模型下载 四段，便于分步执行或只补下模型。

.EXAMPLE
    pwsh -File install.ps1
    pwsh -File install.ps1 -Device CU128 -Source ModelScope -DownloadUVR5
    pwsh -File install.ps1 -SkipModels                              # 只装环境，不下模型
    pwsh -File install.ps1 -SkipTorch -SkipDeps -SkipBuild          # 只补下模型

.NOTES
    本机实测环境：Windows + Python 3.11 + 无 conda + 无 MSVC
                  + msys64/UCRT64 的 gcc/g++/cmake + 系统 ffmpeg
#>
Param(
    [ValidateSet("CU126", "CU128", "CPU")]
    [string]$Device = "CU128",

    [ValidateSet("Auto", "ModelScope", "HF-Mirror", "HF")]
    [string]$Source = "Auto",

    [Alias("WithUVR5")]
    [switch]$DownloadUVR5,

    [string]$VenvPath = ".venv",
    [string]$PipIndex = "https://mirrors.ustc.edu.cn/pypi/simple/",
    [string]$TorchIndex = "",

    [switch]$SkipTorch,
    [switch]$SkipDeps,
    [switch]$SkipBuild,
    [switch]$SkipModels,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------- 基础工具函数

$script:StepNo = 0

function Write-Step([string]$Msg) {
    $script:StepNo++
    Write-Host ""
    Write-Host ("[{0}] {1}" -f $script:StepNo, $Msg) -ForegroundColor Cyan
}
function Write-Ok([string]$Msg) { Write-Host "    [OK] $Msg" -ForegroundColor Green }
function Write-Info([string]$Msg) { Write-Host "    $Msg" -ForegroundColor Gray }
function Write-Note([string]$Msg) { Write-Host "    [跳过] $Msg" -ForegroundColor DarkCyan }
function Write-Warn([string]$Msg) { Write-Host "    [警告] $Msg" -ForegroundColor Yellow }

# 注意：这里刻意用简单函数 + 自动变量 $args，而不是
# [Parameter(ValueFromRemainingArguments=$true)]。后者会让函数变成「高级函数」而带上
# -Debug/-Verbose 等通用参数，于是 pip 的短选项会被当成参数名吃掉：
# 例如 `-d` 会被绑定到 -Debug，导致 `pip download -d <目录>` 里的 -d 静默消失。
function Invoke-Pip {
    $PipArgs = $args
    Write-Info ("pip " + ($PipArgs -join " "))
    & $script:Python -m pip @PipArgs --disable-pip-version-check
    if ($LASTEXITCODE -ne 0) {
        throw ("pip 失败（退出码 {0}）：pip {1}" -f $LASTEXITCODE, ($PipArgs -join " "))
    }
}

# 在解释器里跑一段代码并把 print 的结果带回来，异常静默。
# 用途：探测版本、判断某个包能否导入。
# 刻意不用 PowerShell 的 stderr 重定向：不同终端下重定向行为不一致，容易踩坑。
function Invoke-PyProbe {
    param([string]$Body)
    if (-not (Test-Path $script:Python)) { return "" }
    $indented = ($Body -split "`n" | ForEach-Object { "    $_" }) -join "`n"
    $code = "try:`n$indented`nexcept Exception:`n    pass"
    $out = & $script:Python -W ignore -c $code
    if ($null -eq $out) { return "" }
    return ("$out").Trim()
}

function Test-Tool([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# 用 0-0 范围 GET 探测远端文件大小。
# 注意：ModelScope 的 HEAD 不返回 Content-Length，但范围请求会返回
#       Content-Range: bytes 0-0/<总字节数>，所以统一用范围请求。
function Get-RemoteSize {
    param([string]$Url)
    $hdr = [System.IO.Path]::GetTempFileName()
    & curl.exe -s -L -r 0-0 -o NUL -D $hdr --max-time 60 $Url
    $lines = Get-Content $hdr -ErrorAction SilentlyContinue
    Remove-Item $hdr -Force -ErrorAction SilentlyContinue

    $cr = $lines | Where-Object { $_ -match '(?i)^content-range:\s*bytes\s+\d+-\d+/(\d+)' } | Select-Object -Last 1
    if ($cr -and $cr -match '/(\d+)\s*$') { return [int64]$Matches[1] }

    $cl = $lines | Where-Object { $_ -match '(?i)^content-length:\s*(\d+)' } | Select-Object -Last 1
    if ($cl -and $cl -match '(\d+)') { return [int64]$Matches[1] }

    return -1
}

# 下载并校验大小，带断点续传与重试
function Get-RemoteFile {
    param([string]$Url, [string]$OutFile)

    $expected = Get-RemoteSize $Url
    if ($expected -le 0) { throw "无法获取文件大小：$Url" }

    Write-Info ("下载 {0}（{1:N1} MB）" -f (Split-Path $OutFile -Leaf), ($expected / 1MB))
    for ($a = 1; $a -le 10; $a++) {
        $cur = if (Test-Path $OutFile) { (Get-Item $OutFile).Length } else { 0 }
        if ($cur -eq $expected) { Write-Ok "下载完成"; return }
        if ($cur -gt $expected) { Remove-Item $OutFile -Force; $cur = 0 }
        & curl.exe -s -L -C - -o $OutFile --speed-limit 51200 --speed-time 20 `
            --connect-timeout 20 --max-time 7200 $Url
        $cur = if (Test-Path $OutFile) { (Get-Item $OutFile).Length } else { 0 }
        Write-Info ("  第 {0} 次尝试：{1:N1}/{2:N1} MB" -f $a, ($cur / 1MB), ($expected / 1MB))
    }
    if ((Get-Item $OutFile).Length -ne $expected) { throw "下载不完整：$OutFile" }
    Write-Ok "下载完成"
}

function Expand-Pkg {
    param([string]$Zip, [string]$Dest, [string]$Check)
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Write-Info ("解压 {0} -> {1}" -f (Split-Path $Zip -Leaf), $Dest)
    & tar -xf $Zip -C $Dest
    if ($LASTEXITCODE -ne 0) {
        Write-Info "tar 解压失败，回退到 Expand-Archive"
        Expand-Archive -Path $Zip -DestinationPath $Dest -Force
    }
    if ($Check -and -not (Test-Path $Check)) { Write-Warn "解压后未找到预期路径：$Check" }
}

# ---------------------------------------------------------------- 路径与前置检查

try { chcp 65001 | Out-Null } catch { }
Set-Location $PSScriptRoot

$root     = $PSScriptRoot
$venvDir  = if ([System.IO.Path]::IsPathRooted($VenvPath)) { $VenvPath } else { Join-Path $root $VenvPath }
$python   = Join-Path $venvDir "Scripts\python.exe"
$buildDir = Join-Path $root "_build"
$dlDir    = Join-Path $root "_downloads"
$script:Python = $python

New-Item -ItemType Directory -Force -Path $buildDir, $dlDir | Out-Null

try {

    # ------------------------------------------------------------ 1. 环境体检

    Write-Step "检测构建环境"

    $ffmpeg = Test-Tool "ffmpeg"
    $cmake = Test-Tool "cmake"
    $gpp = Test-Tool "g++"
    $conda = Test-Tool "conda"

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    $msvc = ""
    if (Test-Path $vswhere) {
        $msvc = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
    }
    $hasMsvc = [bool]$msvc
    $gppPath = if ($gpp) { (Get-Command g++).Source } else { "" }
    $useMingw = (-not $hasMsvc) -and $gpp

    Write-Info ("ffmpeg    : {0}" -f $(if ($ffmpeg) { "已安装" } else { "未找到" }))
    Write-Info ("cmake     : {0}" -f $(if ($cmake) { "已安装" } else { "未找到" }))
    Write-Info ("g++       : {0}" -f $(if ($gpp) { $gppPath } else { "未找到" }))
    Write-Info ("MSVC      : {0}" -f $(if ($hasMsvc) { $msvc } else { "未安装" }))
    Write-Info ("conda     : {0}" -f $(if ($conda) { "已安装" } else { "未安装" }))
    Write-Info ("编译策略  : {0}" -f $(if ($hasMsvc) { "MSVC" } elseif ($gpp) { "MinGW g++（无 MSVC）" } else { "无可用编译器" }))

    if (-not $ffmpeg) {
        Write-Warn "未找到 ffmpeg：请把 ffmpeg.exe / ffprobe.exe 放到仓库根目录，或安装 ffmpeg 并加入 PATH。"
    }
    if (-not $cmake) {
        if ($conda) {
            Write-Info "用 conda 安装 cmake"
            & conda install -y -q -c conda-forge cmake
            if ($LASTEXITCODE -ne 0) { Write-Warn "conda 安装 cmake 失败，pyopenjtalk 可能编译不过。" }
        } else {
            Write-Warn "未找到 cmake：pyopenjtalk 需要 CMake 才能编译，请先安装（例如 msys2 的 mingw-w64-ucrt-x86_64-cmake）。"
        }
    }

    if (-not $hasMsvc -and -not $gpp -and -not $SkipBuild) {
        throw @"
本机既没有 MSVC 也没有 g++，无法编译 jieba_fast / pyopenjtalk（这两个包在 PyPI 上没有 Windows 轮子）。
请任选其一后重新运行：
  A. 安装 MSYS2 并装工具链：pacman -S mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-cmake
  B. 安装 Microsoft C++ Build Tools：winget install Microsoft.VisualStudio.2022.BuildTools
"@
    }

    # ------------------------------------------------------------ 2. 虚拟环境

    Write-Step "准备虚拟环境"
    if (Test-Path $python) {
        Write-Note "已存在：$python"
    } else {
        Write-Info "创建 $venvDir"
        $created = $false
        foreach ($launcher in @("py -3.11", "py -3", "python")) {
            $parts = $launcher.Split(" ", 2)
            $exe = $parts[0]
            if (-not (Test-Tool $exe)) { continue }
            if ($parts.Count -gt 1) { & $exe $parts[1] -m venv $venvDir } else { & $exe -m venv $venvDir }
            if ($LASTEXITCODE -eq 0 -and (Test-Path $python)) { $created = $true; break }
        }
        if (-not $created) { throw "创建虚拟环境失败，请确认已安装 Python 3.10–3.12。" }
        Write-Ok "虚拟环境已创建"
    }

    Write-Info ("Python {0}" -f (Invoke-PyProbe "import sys; print('%d.%d.%d' % sys.version_info[:3])"))

    Write-Info "升级 pip / setuptools / wheel"
    Invoke-Pip install -U pip wheel --index-url $PipIndex
    # 注意 setuptools 不能无脑升到最新：torch 的元数据要求 setuptools<82，
    # 升到 84 会让 pip check 报冲突（重跑本脚本时尤其容易踩到）。
    Invoke-Pip install -U "setuptools<82" --index-url $PipIndex
    Write-Ok "包管理器就绪"

    # ------------------------------------------------------------ 3. PyTorch

    Write-Step "安装 PyTorch（$Device）"

    if ($SkipTorch) {
        Write-Note "已指定 -SkipTorch"
    } else {
        $cuda = Invoke-PyProbe "import torch; print(torch.version.cuda or '')"
        $wantMajor = switch ($Device) { "CU126" { "12" } "CU128" { "12" } default { "" } }
        if ($cuda -and ($wantMajor -eq "" -or $cuda -like "$wantMajor.*")) {
            Write-Note ("已安装 torch {0}（CUDA {1}）" -f (Invoke-PyProbe "import torch; print(torch.__version__)"), $cuda)
        } else {
            if (-not $TorchIndex) {
                $TorchIndex = switch ($Device) {
                    "CU126" { "https://mirror.sjtu.edu.cn/pytorch-wheels/cu126/" }
                    "CU128" { "https://mirror.sjtu.edu.cn/pytorch-wheels/cu128/" }
                    default { "https://download.pytorch.org/whl/cpu" }
                }
            }
            Write-Info "索引：$TorchIndex"
            try {
                Invoke-Pip install torch torchaudio --index-url $TorchIndex
            } catch {
                # 镜像不可用时回退官方源（国内会很慢，但至少可用）
                $official = switch ($Device) {
                    "CU126" { "https://download.pytorch.org/whl/cu126" }
                    "CU128" { "https://download.pytorch.org/whl/cu128" }
                    default { "https://download.pytorch.org/whl/cpu" }
                }
                Write-Warn "镜像安装失败，回退官方源 $official（速度可能很慢）"
                Invoke-Pip install torch torchaudio --index-url $official
            }
            $cuda = Invoke-PyProbe "import torch; print(torch.version.cuda or '')"
            Write-Ok ("torch {0}（CUDA {1}）" -f (Invoke-PyProbe "import torch; print(torch.__version__)"), $cuda)
        }
    }

    # ------------------------------------------------------------ 4. MinGW 编译环境

    if ($gpp) {
        $cfg = Join-Path $buildDir "distutils-mingw.cfg"
        @(
            "[build]"
            "compiler=mingw32"
            ""
            "[build_ext]"
            "define=MS_WIN64"
        ) | Set-Content -Path $cfg -Encoding ASCII

        $env:DIST_EXTRA_CONFIG = $cfg
        $env:CMAKE_GENERATOR = "MinGW Makefiles"
        $env:CMAKE_C_COMPILER = "gcc"
        $env:CMAKE_CXX_COMPILER = "g++"
    }

    # ------------------------------------------------------------ 5. 编译 jieba_fast

    if (-not $SkipBuild) {

        Write-Step "编译 jieba_fast（PyPI 无 Windows 轮子）"

        if ((Invoke-PyProbe "import jieba_fast; print('ok')") -eq "ok" -and -not $Force) {
            Write-Note "已安装，跳过"
        } else {
            $srcRoot = Join-Path $buildDir "jieba_fast_src"
            $pkgSrc = Get-ChildItem $srcRoot -Directory -Filter "jieba_fast-*" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $pkgSrc) {
                New-Item -ItemType Directory -Force -Path $srcRoot | Out-Null
                Invoke-Pip download jieba_fast --no-deps --no-binary ":all:" -d $srcRoot --index-url $PipIndex
                $tar = Get-ChildItem $srcRoot -Filter "jieba_fast-*.tar.gz" | Select-Object -First 1
                if (-not $tar) { throw "下载 jieba_fast 源码包失败" }
                & tar -xzf $tar.FullName -C $srcRoot
                if ($LASTEXITCODE -ne 0) { throw "解压 jieba_fast 源码包失败" }
                $pkgSrc = Get-ChildItem $srcRoot -Directory -Filter "jieba_fast-*" | Select-Object -First 1
            }

            Push-Location $pkgSrc.FullName
            try {
                if ($useMingw) {
                    Write-Info "用 mingw32 编译器构建（g++）"
                    & $python setup.py build_ext --compiler=mingw32
                } else {
                    Write-Info "用 MSVC 构建"
                    & $python setup.py build_ext
                }
                if ($LASTEXITCODE -ne 0) { throw "jieba_fast 编译失败" }

                & $python setup.py bdist_wheel
                if ($LASTEXITCODE -ne 0) { throw "jieba_fast 打包失败" }
            } finally {
                Pop-Location
            }

            $whl = Get-ChildItem (Join-Path $pkgSrc.FullName "dist") -Filter "*.whl" | Select-Object -First 1
            if (-not $whl) { throw "找不到 jieba_fast 轮子" }
            Invoke-Pip install $whl.FullName --no-deps --no-index
            Copy-Item $whl.FullName (Join-Path $buildDir $whl.Name) -Force -ErrorAction SilentlyContinue

            if ((Invoke-PyProbe "import jieba_fast; print('ok')") -eq "ok") {
                Write-Ok "jieba_fast 已安装并可用"
            } else {
                Write-Warn "jieba_fast 安装了但导入失败，请检查上方编译输出"
            }
        }

        # -------------------------------------------------------- 6. 编译 pyopenjtalk

        Write-Step "编译 pyopenjtalk（需要 CMake + 编译器）"

        if ((Invoke-PyProbe "import pyopenjtalk; print('ok')") -eq "ok" -and -not $Force) {
            Write-Note "已安装，跳过编译"
        } else {
            if ($useMingw) {
                Write-Info "MinGW 策略：CMAKE_GENERATOR=MinGW Makefiles + define=MS_WIN64（否则 SIZEOF_VOID_P 会算成 4）"
            }
            Invoke-Pip install "pyopenjtalk>=0.4.1" --index-url $PipIndex
            Write-Ok "pyopenjtalk 已编译安装"
        }

        # pyopenjtalk 的扩展依赖 MinGW 运行时 DLL；Python 3.8+ 不再从 PATH 解析扩展模块的
        # 依赖 DLL，必须放到 .pyd 同级目录。每次重装 pyopenjtalk 后都要补一次。
        $ojDir = Join-Path $venvDir "Lib\site-packages\pyopenjtalk"
        if ((Test-Path $ojDir) -and $gpp) {
            $mingwBin = Split-Path $gppPath
            $copied = 0
            foreach ($dll in @("libstdc++-6.dll", "libgcc_s_seh-1.dll", "libwinpthread-1.dll")) {
                $src = Join-Path $mingwBin $dll
                if (Test-Path $src) { Copy-Item $src $ojDir -Force; $copied++ }
            }
            if ($copied -gt 0) { Write-Ok "已补齐 MinGW 运行时 DLL（$copied 个）" }
        }

        # open_jtalk 词典：pyopenjtalk 首次使用会自动从 GitHub 下载，国内常被截断，这里预先放好
        if (Test-Path $ojDir) {
            $dictDir = Join-Path $ojDir "open_jtalk_dic_utf_8-1.11"
            if (Test-Path $dictDir) {
                Write-Note "open_jtalk 词典已存在"
            } else {
                Write-Info "下载 open_jtalk 词典"
                $tgz = Join-Path $dlDir "open_jtalk_dic_utf_8-1.11.tar.gz"
                # ModelScope 在多数网络下更快，失败再回退 HF-Mirror
                $dictUrls = @(
                    "https://www.modelscope.cn/models/XXXXRT/GPT-SoVITS-Pretrained/resolve/master/open_jtalk_dic_utf_8-1.11.tar.gz",
                    "https://hf-mirror.com/XXXXRT/GPT-SoVITS-Pretrained/resolve/main/open_jtalk_dic_utf_8-1.11.tar.gz"
                )
                $got = $false
                foreach ($u in $dictUrls) {
                    try { Get-RemoteFile $u $tgz; $got = $true; break }
                    catch { Write-Warn "该源下载失败：$u" }
                }
                if ($got) {
                    & tar -xzf $tgz -C $ojDir
                    if (Test-Path $dictDir) { Write-Ok "open_jtalk 词典就绪" } else { Write-Warn "词典解压异常" }
                }
            }
        }
    }

    # ------------------------------------------------------------ 7. 项目依赖

    if (-not $SkipDeps) {
        Write-Step "安装项目依赖"

        # requirements.txt 第一行是 --no-binary=opencc，会强制源码编译（需要 MSVC）。
        # 先装二进制轮子，之后 pip 见到已满足的需求就会直接跳过它。
        if ((Invoke-PyProbe "import opencc; print('ok')") -ne "ok") {
            Write-Info "预装 opencc 二进制轮子（绕开 --no-binary=opencc 的源码编译）"
            Invoke-Pip install opencc --only-binary ":all:" --index-url $PipIndex
        } else {
            Write-Note "opencc 已安装"
        }

        Write-Info "安装 extra-req.txt（--no-deps）"
        Invoke-Pip install -r extra-req.txt --no-deps --index-url $PipIndex

        Write-Info "安装 requirements.txt（已满足的包会被跳过）"
        Invoke-Pip install -r requirements.txt --index-url $PipIndex

        Write-Ok "依赖安装完成"
    }

    # ------------------------------------------------------------ 8. 版本固定

    Write-Step "固定已知兼容版本"

    # (a) onnxruntime-gpu 必须与 torch 的 CUDA 大版本一致，否则启动时会刷屏
    #     “Failed to load cublasLt64_13.dll ...” 且 CUDA provider 全部加载失败。
    #     torch cu128 -> ORT 1.20.2（其 provider 链接 cudart64_12/cublas64_12/cudnn64_9，
    #     这些 DLL 由 torch/lib 提供）；torch cu13x -> ORT 1.30.x。
    $cuda = Invoke-PyProbe "import torch; print(torch.version.cuda or '')"
    $ortWant = ""
    if ($cuda -like "12.*") { $ortWant = "1.20.2" }
    elseif ($cuda -like "13.*") { $ortWant = "1.30.0" }
    if ($ortWant) {
        $ortNow = Invoke-PyProbe "import onnxruntime; print(onnxruntime.__version__)"
        if ($ortNow -ne $ortWant) {
            if ($ortNow) { Write-Info "onnxruntime-gpu：$ortNow -> $ortWant（匹配 CUDA $cuda）" }
            else { Write-Info "安装 onnxruntime-gpu==$ortWant（匹配 CUDA $cuda）" }
            Invoke-Pip install "onnxruntime-gpu==$ortWant" --index-url $PipIndex
        } else {
            Write-Note "onnxruntime-gpu $ortWant 已就位"
        }
    }

    # (b) gradio 4.44 用的是 starlette 旧版 TemplateResponse(name, context) 调用；
    #     requirements.txt 里 fastapi 的约束是 >=0.115.2（很松），会拉到 fastapi 0.14x +
    #     starlette 1.x，导致每次打开页面都报 TypeError: unhashable type: 'dict'（HTTP 500）。
    #     0.115.2 会带上 starlette<0.41，兼容 gradio 4.44。
    $fastapiNow = Invoke-PyProbe "import fastapi; print(fastapi.__version__)"
    if ($fastapiNow -ne "0.115.2") {
        Write-Info "fastapi：$fastapiNow -> 0.115.2（携带 starlette<0.41，兼容 gradio 4.44）"
        Invoke-Pip install "fastapi[standard]==0.115.2" --index-url $PipIndex
    } else {
        Write-Note "fastapi 0.115.2 已就位"
    }

    Write-Ok "版本固定完成"

    # ------------------------------------------------------------ 9. 模型权重

    if ($SkipModels) {
        Write-Step "模型权重"
        Write-Note "已指定 -SkipModels"
    } else {
        Write-Step "下载模型权重"

        $bases = [ordered]@{
            "ModelScope" = "https://www.modelscope.cn/models/XXXXRT/GPT-SoVITS-Pretrained/resolve/master"
            "HF-Mirror" = "https://hf-mirror.com/XXXXRT/GPT-SoVITS-Pretrained/resolve/main"
            "HF" = "https://huggingface.co/XXXXRT/GPT-SoVITS-Pretrained/resolve/main"
        }

        $modelBase = $bases[$Source]
        if ($Source -eq "Auto") {
            $needBench = -not (Test-Path (Join-Path $root "GPT_SoVITS\pretrained_models\sv"))
            if ($needBench) {
                Write-Info "给各下载源测速（各拉 8 MB）..."
                $bestSpeed = 0.0
                $modelBase = $bases["ModelScope"]
                foreach ($k in $bases.Keys) {
                    $raw = & curl.exe -s -L -o NUL --max-time 15 -r 0-8000000 -w "%{speed_download}" "$($bases[$k])/pretrained_models.zip"
                    $spd = 0.0
                    [void][double]::TryParse("$raw".Trim(), [ref]$spd)
                    Write-Info ("  {0,-11} {1,8:N0} KB/s" -f $k, ($spd / 1KB))
                    if ($spd -gt $bestSpeed) { $bestSpeed = $spd; $modelBase = $bases[$k] }
                }
                if ($bestSpeed -le 0) { throw "所有模型源都不可用，请检查网络。" }
            } else {
                $modelBase = $bases["ModelScope"]
            }
        }
        Write-Info "使用源：$modelBase"

        # 1) 主模型
        $check = Join-Path $root "GPT_SoVITS\pretrained_models\sv"
        if ((Test-Path $check) -and -not $Force) {
            Write-Note "主模型已存在"
        } else {
            $zip = Join-Path $dlDir "pretrained_models.zip"
            Get-RemoteFile "$modelBase/pretrained_models.zip" $zip
            Expand-Pkg $zip (Join-Path $root "GPT_SoVITS") $check
        }

        # 2) G2PW 中文多音字模型（缺了会在启动时卡在联网下载）
        $check = Join-Path $root "GPT_SoVITS\text\G2PWModel"
        if ((Test-Path $check) -and -not $Force) {
            Write-Note "G2PWModel 已存在"
        } else {
            $zip = Join-Path $dlDir "G2PWModel.zip"
            Get-RemoteFile "$modelBase/G2PWModel.zip" $zip
            Expand-Pkg $zip (Join-Path $root "GPT_SoVITS\text") $check
        }

        # 3) nltk 数据（英文 G2P）→ 装到虚拟环境前缀下
        $prefix = Invoke-PyProbe "import sys; print(sys.prefix)"
        if (-not $prefix) { $prefix = $venvDir }
        $check = Join-Path $prefix "nltk_data"
        if ((Test-Path $check) -and -not $Force) {
            Write-Note "nltk_data 已存在（$check）"
        } else {
            $zip = Join-Path $dlDir "nltk_data.zip"
            Get-RemoteFile "$modelBase/nltk_data.zip" $zip
            Expand-Pkg $zip $prefix $check
        }

        # 4) 可选：UVR5 人声分离权重
        if ($DownloadUVR5) {
            $uvrDir = Join-Path $root "tools\uvr5\uvr5_weights"
            # 注意：该目录里本来就有 .gitignore，不能用“目录非空”来判断
            $hasUvr5 = @(Get-ChildItem $uvrDir -File -Filter "*.pth" -ErrorAction SilentlyContinue).Count -gt 0
            if ($hasUvr5 -and -not $Force) {
                Write-Note "uvr5_weights 已存在"
            } else {
                $zip = Join-Path $dlDir "uvr5_weights.zip"
                Get-RemoteFile "$modelBase/uvr5_weights.zip" $zip
                Expand-Pkg $zip (Join-Path $root "tools\uvr5") $uvrDir
            }
        }
    }

    # ------------------------------------------------------------ 10. 结果汇总

    Write-Step "安装结果"

    $rows = [ordered]@{
        "torch" = "import torch; print(torch.__version__ + ' | CUDA ' + str(torch.version.cuda) + ' | ' + ('可用' if torch.cuda.is_available() else '不可用'))"
        "onnxruntime" = "import onnxruntime; print(onnxruntime.__version__ + ' | ' + ','.join(onnxruntime.get_available_providers()))"
        "gradio" = "import gradio; print(gradio.__version__)"
        "jieba_fast" = "import jieba_fast; print('/'.join(jieba_fast.lcut('今天天气不错')))"
        "pyopenjtalk" = "import pyopenjtalk; print(pyopenjtalk.g2p('こんにちは'))"
    }
    foreach ($k in $rows.Keys) {
        $v = Invoke-PyProbe $rows[$k]
        if ($v) { Write-Host ("    {0,-12} {1}" -f $k, $v) -ForegroundColor Green }
        else { Write-Host ("    {0,-12} 不可用" -f $k) -ForegroundColor Red }
    }

    Write-Host ""
    Write-Host "安装完成。启动 WebUI：" -ForegroundColor Cyan
    Write-Host ("    .\{0}\Scripts\python.exe webui.py" -f (Split-Path $venvDir -Leaf)) -ForegroundColor White
    Write-Host ""
    Write-Host "小提示：" -ForegroundColor DarkGray
    Write-Host "  * 仓库自带的 go-webui.ps1 是给官方整合包用的（它调用 runtime\python.exe），本机不适用。" -ForegroundColor DarkGray
    Write-Host "  * 显存 <=4GB 时推理请控制文本长度，训练建议用 CPU 或云端。" -ForegroundColor DarkGray
    Write-Host "  * _downloads\ 里的压缩包解压后可以删除，能腾出约 5 GB。" -ForegroundColor DarkGray
}
catch {
    Write-Host ""
    Write-Host "[错误] 安装中断" -ForegroundColor Red
    Write-Host ("  {0}" -f $_.Exception.Message) -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host "  调用栈：" -ForegroundColor DarkRed
        ($_.ScriptStackTrace -split "`n") | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkRed }
    }
    exit 1
}
