# Unified, private AI component root. Compatible with Windows PowerShell 5.1.
param(
    [string]$Root = "$env:USERPROFILE/.cache/mpv-ai",
    [ValidateSet('huggingface', 'modelscope')][string]$ModelSource = 'huggingface',
    [switch]$ConfigureLocal
)
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root)
$configRoot = Split-Path $PSScriptRoot -Parent
$localFile = Join-Path $configRoot 'local.conf'
$localText = if (Test-Path -LiteralPath $localFile) { [IO.File]::ReadAllText($localFile) } else { '' }
$qwenMatches = [regex]::Matches($localText, '(?m)^\s*script-opts-append=sub_fastwhisper-qwen_python=([^\r\n]+)')
if (!$qwenMatches.Count -or !(Test-Path -LiteralPath $qwenMatches[$qwenMatches.Count - 1].Groups[1].Value.Trim())) {
    throw 'Configure the existing Qwen runtime first (tools/setup-qwen-asr.ps1). See docs/ai-subtitles.md.'
}
$sourcePython = $qwenMatches[$qwenMatches.Count - 1].Groups[1].Value.Trim()
New-Item -ItemType Directory -Path (Join-Path $Root 'state') -Force | Out-Null
$lockPath = Join-Path $Root 'state/install.lock'
$lock = [IO.File]::Open($lockPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
$lockInfo = [Text.Encoding]::UTF8.GetBytes("pid=$PID`n")
$lock.Write($lockInfo, 0, $lockInfo.Length)
$lock.Flush()
function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Program" }
}
try {
    Invoke-Checked $sourcePython @((Join-Path $PSScriptRoot 'maintenance/ai_runtime.py'), 'prepare', '--root', $Root)
    $uvRoot = Join-Path $Root 'downloads/bootstrap'
    New-Item -ItemType Directory -Path $uvRoot -Force | Out-Null
    $uv = Join-Path $uvRoot 'uv.exe'
    if (!(Test-Path -LiteralPath $uv)) {
        $zip = Join-Path $uvRoot 'uv.zip'
        Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/astral-sh/uv/releases/download/0.13.1/uv-x86_64-pc-windows-msvc.zip' -OutFile $zip
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne '3b2661a463a5baea7f5076ea2b25ab71d77f36a6c0d809e5350651792f80a672') { throw 'uv checksum mismatch' }
        Expand-Archive -LiteralPath $zip -DestinationPath $uvRoot -Force
    }
    $qwenPython = Join-Path $Root 'runtimes/qwen/python/python.exe'
    $sensePython = Join-Path $Root 'runtimes/sensevoice/python/python.exe'
    $cacheDir = Join-Path $Root 'downloads/uv-cache'
    # The copied standalone Python inherits uv's managed marker. Verify its prefix
    # before permitting package installation into this dedicated copy only.
    Invoke-Checked $sensePython @('-c', 'import pathlib,sys; assert pathlib.Path(sys.prefix).resolve()==pathlib.Path(sys.argv[1]).resolve()', (Split-Path $sensePython -Parent))
    Invoke-Checked $uv @('pip', 'install', '--python', $sensePython, '--break-system-packages', 'torchaudio==2.8.0', '--index-url', 'https://download.pytorch.org/whl/cu128', '--cache-dir', $cacheDir)
    Invoke-Checked $uv @('pip', 'install', '--python', $sensePython, '--break-system-packages', 'funasr==1.4.16', 'numpy==1.26.4', '--cache-dir', $cacheDir)
    Invoke-Checked $qwenPython @((Join-Path $PSScriptRoot 'maintenance/download_ai_models.py'), (Join-Path $Root 'models'), '--source', $ModelSource)
    Invoke-Checked $qwenPython @('-c', 'import torch,qwen_asr; assert torch.cuda.is_available(); print("Qwen runtime ready:",torch.cuda.get_device_name())')
    Invoke-Checked $sensePython @('-c', 'import torch,torchaudio,funasr; assert torch.cuda.is_available(); print("SenseVoice runtime ready:",torch.cuda.get_device_name())')
    if ($ConfigureLocal) {
        Invoke-Checked $qwenPython @((Join-Path $PSScriptRoot 'maintenance/ai_runtime.py'), 'configure', '--root', $Root)
    }
    Write-Output "AI subtitle components prepared: $Root"
} finally {
    $lock.Dispose()
    Remove-Item -LiteralPath $lockPath
}
