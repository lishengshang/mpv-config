# Run from any directory. Python comes from the upstream portable VS package.
param(
    [switch]$Run,
    [ValidateSet('vs', 'shader', 'all')][string]$Kind = 'all',
    [string]$Preset = '',
    [int]$Timeout = 300,
    [ValidateSet(640, 1280)][int]$SourceWidth = 1280,
    [string]$MpvRoot = ''
)
$ErrorActionPreference = 'Stop'
if (!$MpvRoot) { $MpvRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$python = Join-Path $MpvRoot 'python.exe'
if (!(Test-Path -LiteralPath $python)) {
    Write-Host 'Missing portable Python. See docs/gpu-setup.md (upstream deployment package).'
    Write-Host ('Expected: ' + $python)
    exit 2
}
$taskArgs = @((Join-Path $PSScriptRoot 'verify_gpu.py'), '--mpv-root', $MpvRoot,
              '--kind', $Kind, '--timeout', $Timeout, '--source-width', $SourceWidth)
if ($Run) { $taskArgs += '--run' }
if ($Preset) { $taskArgs += @('--preset', $Preset) }
& $python @taskArgs
exit $LASTEXITCODE
