# Import an upstream, already-extracted runtime into a fresh mpv directory.
# Does not download, install drivers, replace mpv or touch portable_config.
[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$Source = '', [string]$MpvRoot = '')
$ErrorActionPreference = 'Stop'
if (!$Source) { $Source = Read-Host 'Path to extracted upstream vsNV package (no quotes)' }
if (!$MpvRoot) { $MpvRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent }
$sourcePath = (Resolve-Path -LiteralPath $Source).Path.TrimEnd('\')
$targetPath = (Resolve-Path -LiteralPath $MpvRoot).Path.TrimEnd('\')
if (!(Test-Path -LiteralPath (Join-Path $targetPath 'mpv.exe'))) {
    throw 'Destination must contain mpv.exe. See docs/gpu-setup.md.'
}
if ($sourcePath.Equals($targetPath, [StringComparison]::OrdinalIgnoreCase) -or
    $sourcePath.StartsWith($targetPath + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $targetPath.StartsWith($sourcePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Extract the upstream package into a separate temporary directory first.'
}
$candidates = @(Get-ChildItem -LiteralPath $sourcePath -Filter VSScript.dll -File -Recurse |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.DirectoryName 'python.exe') })
if ($candidates.Count -ne 1) {
    throw ('Expected exactly one Python/VS runtime; found ' + $candidates.Count + '. Select a more specific source folder.')
}
$runtimePath = $candidates[0].DirectoryName
foreach ($name in @('portable.vs','Lib','vs-plugins','vs-coreplugins')) {
    if (!(Test-Path -LiteralPath (Join-Path $runtimePath $name))) {
        throw ('Incomplete runtime: missing ' + $name + '. Use a complete upstream vsNV package.')
    }
}
foreach ($name in @('python.exe','VSScript.dll','Lib','vs-plugins','vs-coreplugins')) {
    if (Test-Path -LiteralPath (Join-Path $targetPath $name)) {
        throw ('Destination already contains ' + $name + '. Use a fresh mpv directory to avoid mixed versions.')
    }
}
# Root DLLs/PYDs are deliberately kept together for dependency consistency.
$items = @(Get-ChildItem -LiteralPath $runtimePath -File | Where-Object {
    $_.Extension -in @('.dll','.pyd') -or
    $_.Name -match '^python.*\.(exe|zip|_pth)$' -or
    $_.Name -eq 'portable.vs' -or $_.Name -match '^LICENSE.*'
})
foreach ($name in @('Lib','vs-coreplugins','vs-plugins','vs-scripts')) {
    $path = Join-Path $runtimePath $name
    if (Test-Path -LiteralPath $path) { $items += Get-Item -LiteralPath $path }
}
foreach ($item in $items) {
    $destination = Join-Path $targetPath $item.Name
    if ($PSCmdlet.ShouldProcess($destination, 'Copy upstream VS runtime component')) {
        Copy-Item -LiteralPath $item.FullName -Destination $destination -Recurse -Force
    }
}
if (!$WhatIfPreference) {
    Write-Host 'Runtime imported. Checking Python/VS/k7sfunc...'
    & (Join-Path $targetPath 'python.exe') -c 'import vapoursynth as vs; import k7sfunc; print(str(vs.core))'
    if ($LASTEXITCODE -ne 0) { throw 'Runtime import check failed. Keep the output; do not mark installation as verified.' }
    Write-Host 'Import check passed. Run tools/verify-gpu.ps1 -Run for actual GPU frames.'
    Write-Host 'Custom ONNX models may still need to be added. See docs/gpu-setup.md.'
}
