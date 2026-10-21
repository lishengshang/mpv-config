[CmdletBinding()]
param([string]$ConfigRoot = '', [switch]$Json, [switch]$Mpv, [string]$MpvRoot = '')
$ErrorActionPreference = 'Stop'
if (!$ConfigRoot) { $ConfigRoot = Split-Path $PSScriptRoot -Parent }
$taskArgs = @((Join-Path $PSScriptRoot 'maintenance/check_config.py'), '--config-root', $ConfigRoot)
if ($Json) { $taskArgs += '--json' }
if ($Mpv) { $taskArgs += '--mpv' }
if ($MpvRoot) { $taskArgs += @('--mpv-root', $MpvRoot) }
if ($PSBoundParameters.ContainsKey('Verbose')) { $taskArgs += '--verbose' }
$portablePython = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'python.exe'
if (Test-Path -LiteralPath $portablePython) {
    & $portablePython @taskArgs
} else {
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    $pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($launcher) { & $launcher.Source -3 @taskArgs }
    elseif ($pythonCommand -and $pythonCommand.Source -notlike '*\WindowsApps\*') { & $pythonCommand.Source @taskArgs }
    else { Write-Host 'Python 3.10+ is required. VS is optional; system Python is supported.'; exit 2 }
}
exit $LASTEXITCODE
