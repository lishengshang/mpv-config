param(
    [string]$Root = "$env:USERPROFILE/.cache/mpv-ai/qwen-asr",
    [ValidateSet('huggingface', 'modelscope')][string]$ModelSource = 'huggingface',
    [switch]$ConfigureLocal
)
$ErrorActionPreference = 'Stop'
$Root = [IO.Path]::GetFullPath($Root)
$configRoot = Split-Path $PSScriptRoot -Parent
$uvVersion = '0.13.1'
$uvSha256 = '3b2661a463a5baea7f5076ea2b25ab71d77f36a6c0d809e5350651792f80a672'
$bootstrap = Join-Path $Root 'bootstrap'
$uv = Join-Path $bootstrap 'uv.exe'
New-Item -ItemType Directory -Path $bootstrap -Force | Out-Null
if (-not (Test-Path -LiteralPath $uv)) {
    $zip = Join-Path $bootstrap 'uv.zip'
    Invoke-WebRequest -Uri "https://github.com/astral-sh/uv/releases/download/$uvVersion/uv-x86_64-pc-windows-msvc.zip" -OutFile $zip
    if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $uvSha256) { throw 'uv checksum mismatch' }
    Expand-Archive -LiteralPath $zip -DestinationPath $bootstrap -Force
}
function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Command failed ($LASTEXITCODE): $Program" }
}
$pythonRoot = Join-Path $Root 'python'
$cacheDir = Join-Path $Root 'uv-cache'
Invoke-Checked $uv @('python', 'install', '3.12.12', '--install-dir', $pythonRoot, '--no-bin', '--no-registry', '--cache-dir', $cacheDir)
$basePython = Join-Path $pythonRoot 'cpython-3.12.12-windows-x86_64-none/python.exe'
$venv = Join-Path $Root '.venv'
$python = Join-Path $venv 'Scripts/python.exe'
if (-not (Test-Path -LiteralPath $python)) { Invoke-Checked $basePython @('-m', 'venv', $venv) }
Invoke-Checked $uv @('pip', 'install', '--python', $python, 'torch==2.8.0', '--index-url', 'https://download.pytorch.org/whl/cu128', '--cache-dir', $cacheDir)
Invoke-Checked $uv @('pip', 'install', '--python', $python, 'qwen-asr==0.0.6', 'huggingface-hub==0.36.2', 'hf-xet==1.2.0', 'numpy==1.26.4', 'librosa==0.11.0', '--cache-dir', $cacheDir)
$models = Join-Path $Root 'models'
Invoke-Checked $python @((Join-Path $PSScriptRoot 'download_qwen_models.py'), $models, '--source', $ModelSource)
Invoke-Checked $python @('-c', 'import torch,qwen_asr; assert torch.cuda.is_available(); print(torch.__version__, torch.cuda.get_device_name())')
if ($ConfigureLocal) {
    $localFile = Join-Path $configRoot 'local.conf'
    $text = if (Test-Path -LiteralPath $localFile) { [IO.File]::ReadAllText($localFile) } else { '' }
    $settings = [ordered]@{
        qwen_python = $python
        qwen_model = (Join-Path $models 'Qwen3-ASR-1.7B')
        qwen_aligner = (Join-Path $models 'Qwen3-ForcedAligner-0.6B')
    }
    foreach ($key in $settings.Keys) {
        $pattern = '(?m)^script-opts-append=sub_fastwhisper-' + $key + '=[^\r\n]*\r?\n?'
        $text = [regex]::Replace($text, $pattern, '')
        $text = $text.TrimEnd("`r", "`n") + "`nscript-opts-append=sub_fastwhisper-$key=" + $settings[$key].Replace('\', '/') + "`n"
    }
    [IO.File]::WriteAllText($localFile, $text.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    Write-Output 'Qwen paths configured in ignored local.conf. Whisper remains the default.'
}
Write-Output "Qwen environment and pinned models ready: $Root"
