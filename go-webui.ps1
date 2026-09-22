# 启动 GPT-SoVITS WebUI：优先使用仓库内 .venv（手动安装），否则回退到官方整合包的 runtime。
# 用法：pwsh -File .\go-webui.ps1
$ErrorActionPreference = "Stop"
try { chcp 65001 | Out-Null } catch { }
Set-Location $PSScriptRoot

$venvPython    = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
$runtimeDir    = Join-Path $PSScriptRoot "runtime"
$runtimePython = Join-Path $runtimeDir "python.exe"
$webui         = Join-Path $PSScriptRoot "webui.py"

if (Test-Path $venvPython) {
    Write-Host "使用 .venv：$venvPython" -ForegroundColor Cyan
    & $venvPython $webui zh_CN
}
elseif (Test-Path $runtimePython) {
    Write-Host "使用整合包 runtime：$runtimePython" -ForegroundColor Cyan
    $env:PATH = "$runtimeDir;$env:PATH"
    & $runtimePython -I $webui zh_CN
}
else {
    Write-Host "未找到可用的 Python 解释器。" -ForegroundColor Red
    Write-Host "  A. 手动安装：先运行 pwsh -File .\install.ps1（环境会装进 .venv）" -ForegroundColor Yellow
    Write-Host "  B. 整合包：把官方压缩包里的 runtime 目录放到仓库根目录" -ForegroundColor Yellow
    exit 1
}

$code = $LASTEXITCODE
if ($code -ne 0) { Write-Host "WebUI 退出码：$code" -ForegroundColor Red }
if (-not [Console]::IsInputRedirected) { [void](Read-Host "按回车键退出") }
exit $code
