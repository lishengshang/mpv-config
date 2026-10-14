# Build a portable_config ZIP from tracked and non-ignored project files.
[CmdletBinding(SupportsShouldProcess=$true)]
param([string]$Output = '')
$ErrorActionPreference = 'Stop'
$configPath = Split-Path $PSScriptRoot -Parent
if ((Split-Path $configPath -Leaf) -ne 'portable_config') { throw 'Source directory must be named portable_config.' }
if (!$Output) { $Output = Join-Path $configPath 'cache/packages/mpv-portable-config.zip' }
$archivePath = [System.IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $archivePath) { throw 'Output exists; choose a new -Output filename.' }
$runtimePath = Split-Path $configPath -Parent
$sevenZip = Join-Path $runtimePath '7z.exe'
if (!(Test-Path -LiteralPath $sevenZip)) { $sevenZip = (Get-Command 7z.exe -ErrorAction Stop).Source }
Push-Location $configPath
try {
    $files = @(git -c core.quotepath=false ls-files --cached --others --exclude-standard)
    if ($LASTEXITCODE -ne 0) { throw 'Run this exporter from a Git checkout.' }
} finally { Pop-Location }
# Defense in depth: never package private machine configuration or runtime history.
$files = @($files | Where-Object {
    $_ -notmatch '^(local\.conf$|\.git/|\.zcode/|cache/|files/|state/|playlists/)' -and
    (Test-Path -LiteralPath (Join-Path $configPath $_) -PathType Leaf)
})
if (!$files.Count) { throw 'No project files selected.' }
if ($PSCmdlet.ShouldProcess($archivePath, 'Export portable_config without private settings or cache')) {
    $outputDir = Split-Path $archivePath -Parent
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    $listPath = Join-Path $outputDir ('config-files-' + [guid]::NewGuid().ToString('N') + '.lst')
    [System.IO.File]::WriteAllLines($listPath, @($files | ForEach-Object { 'portable_config/' + $_ }), [System.Text.UTF8Encoding]::new($false))
    Push-Location $runtimePath
    try {
        & $sevenZip a -tzip -mx=1 -scsUTF-8 -bsp0 -bso0 $archivePath ('@' + $listPath)
        if ($LASTEXITCODE -ne 0) { throw 'Configuration export failed.' }
        & $sevenZip t -bsp0 -bso0 $archivePath
        if ($LASTEXITCODE -ne 0) { throw 'Configuration archive integrity check failed.' }
    } finally { Pop-Location }
    $hash = Get-FileHash -LiteralPath $archivePath -Algorithm SHA256
    [System.IO.File]::WriteAllText(($archivePath + '.sha256'), ($hash.Hash + '  ' + [System.IO.Path]::GetFileName($archivePath) + "`n"), [System.Text.UTF8Encoding]::new($false))
    # Keep the diagnostic list on failure; remove it after a verified export.
    Remove-Item -LiteralPath $listPath -Force -ErrorAction Stop
    Write-Host ('Created: ' + $archivePath)
}
