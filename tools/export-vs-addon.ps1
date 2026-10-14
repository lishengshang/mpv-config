# Export a local optional addon using upstream 7-Zip; no downloader or custom archive format.
[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$MpvRoot = '', [string]$Output = '')
$ErrorActionPreference = 'Stop'
$configPath = Split-Path $PSScriptRoot -Parent
if (!$MpvRoot) { $MpvRoot = Split-Path $configPath -Parent }
$runtimePath = (Resolve-Path -LiteralPath $MpvRoot).Path.TrimEnd('\')
if (!$Output) { $Output = Join-Path $configPath 'cache/packages/mpv-VS-RTX-addon.7z' }
$archivePath = [System.IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $archivePath) { throw 'Output archive already exists; choose a new -Output filename.' }
$sevenZip = Join-Path $runtimePath '7z.exe'
if (!(Test-Path -LiteralPath $sevenZip)) {
    $sevenZip = (Get-Command 7z.exe -ErrorAction Stop).Source
}
foreach ($name in @('python.exe','VSScript.dll','portable.vs','Lib','vs-coreplugins','vs-plugins')) {
    if (!(Test-Path -LiteralPath (Join-Path $runtimePath $name))) { throw ('Missing runtime component: ' + $name) }
}
$files = @(Get-ChildItem -LiteralPath $runtimePath -File | Where-Object {
    $_.Extension -in @('.dll','.pyd') -or $_.Name -match '^python.*\.(exe|zip|_pth)$' -or
    $_.Name -eq 'portable.vs' -or $_.Name -match '^LICENSE.*'
})
foreach ($name in @('Lib','vs-coreplugins','vs-plugins','vs-scripts')) {
    $path = Join-Path $runtimePath $name
    if (Test-Path -LiteralPath $path) {
        $files += Get-ChildItem -LiteralPath $path -Recurse -File | Where-Object {
            $_.FullName -notmatch '[\\/]__pycache__[\\/]' -and
            $_.Name -notlike '*.engine*' -and $_.Name -notlike '*.cache*'
        }
    }
}
Write-Host ('Selected files: ' + $files.Count + ', uncompressed GiB: ' +
    [math]::Round(($files | Measure-Object Length -Sum).Sum / 1GB, 2))
if ($PSCmdlet.ShouldProcess($archivePath, 'Create optional VS addon (runtime/plugins/models, no config or engine caches)')) {
    $outputDir = Split-Path $archivePath -Parent
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    $listPath = Join-Path $outputDir ('vs-files-' + [guid]::NewGuid().ToString('N') + '.lst')
    $relativeFiles = @($files | ForEach-Object { $_.FullName.Substring($runtimePath.Length + 1) })
    [System.IO.File]::WriteAllLines($listPath, $relativeFiles, [System.Text.UTF8Encoding]::new($false))
    Push-Location $runtimePath
    try {
        & $sevenZip a -t7z -mx=1 -mmt=2 -scsUTF-8 -bsp0 -bso0 $archivePath ('@' + $listPath)
        if ($LASTEXITCODE -ne 0) { throw '7-Zip export failed; do not distribute the partial archive.' }
        & $sevenZip t -bsp0 -bso0 $archivePath
        if ($LASTEXITCODE -ne 0) { throw '7-Zip integrity test failed.' }
    } finally { Pop-Location }
    $hash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
    [System.IO.File]::WriteAllText(($archivePath + '.sha256'), ($hash.Hash + '  ' + [System.IO.Path]::GetFileName($archivePath) + "`n"), [System.Text.UTF8Encoding]::new($false))
    # Keep the diagnostic list on failure; remove it after a verified export.
    Remove-Item -LiteralPath $listPath -Force -ErrorAction Stop
    Write-Host ('Created: ' + $archivePath)
    Write-Host ('SHA256: ' + $hash.Hash)
    Write-Host 'Extract into the new mpv.exe directory. Preserve portable_config. Rebuild TRT engines on the new GPU.'
}
