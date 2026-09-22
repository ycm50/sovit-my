# 用仓库内的 .venv 启动 GPT-SoVITS WebUI（手动安装场景）
# 用法：pwsh -File .\go-webui-venv.ps1
# 说明：需要先跑过 install.ps1（默认把环境装在 .venv）；整合包场景请用 go-webui.ps1。
#       端口在 config.py 的 webui_port_main 里改（默认 9874）。
$ErrorActionPreference = "Stop"
try { chcp 65001 | Out-Null } catch { }
Set-Location $PSScriptRoot

$python = Join-Path $PSScriptRoot ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) {
    Write-Host "未找到虚拟环境：$python" -ForegroundColor Red
    Write-Host "请先安装环境：" -ForegroundColor Yellow
    Write-Host "    pwsh -File .\install.ps1                  # 默认装到 .venv" -ForegroundColor White
    Write-Host "    pwsh -File .\install.ps1 -VenvPath <目录>  # 装到别处时，请直接用该目录的 python 启动 webui.py" -ForegroundColor White
    exit 1
}

Write-Host "使用 .venv：$python" -ForegroundColor Cyan
& $python (Join-Path $PSScriptRoot "webui.py") zh_CN
exit $LASTEXITCODE
