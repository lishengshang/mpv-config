# ASCII source for Windows PowerShell 5.1; component data and paths use Unicode APIs.
[CmdletBinding()]
param(
    [ValidateSet('Menu','Status','Install','Configure')][string]$Action = 'Menu',
    [string]$MpvRoot = '',
    [string]$Catalog = '',
    [string[]]$Components = @('vs','media','whisper','qwen')
)
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path $PSScriptRoot -Parent
if (!$MpvRoot) {
    if (Test-Path -LiteralPath (Join-Path $sourceRoot 'mpv.conf')) { $MpvRoot = Split-Path $sourceRoot -Parent }
    else { $MpvRoot = (Read-Host 'Destination folder containing mpv.exe').Trim('"') }
}
$rootPath = (Resolve-Path -LiteralPath $MpvRoot).Path.TrimEnd('\')
if (!(Test-Path -LiteralPath (Join-Path $rootPath 'mpv.exe'))) { throw 'mpv.exe missing at destination' }
if ($Action -eq 'Menu') {
    Write-Host '1 Check components  2 Install from catalog  3 Repair paths after moving player'
    $choice = Read-Host 'Choose 1, 2 or 3'
    $Action = switch ($choice) { '1' {'Status'} '2' {'Install'} '3' {'Configure'} default { throw 'Invalid selection' } }
}
if (!$Catalog -and (Test-Path -LiteralPath (Join-Path $sourceRoot 'catalog.json'))) { $Catalog = Join-Path $sourceRoot 'catalog.json' }
$python = Join-Path $rootPath 'python.exe'
if (Test-Path -LiteralPath $python) {
    & $python -c 'import sys; sys.exit(0 if sys.version_info >= (3,12) else 1)'
    if ($LASTEXITCODE -ne 0) { $python = '' }
} else { $python = '' }
if ((!$python -or $Action -eq 'Install') -and !$Catalog) {
    $Catalog = (Read-Host 'Path or HTTPS URL to component catalog.json').Trim('"')
}
$bootstrapRuntime = ''
$cacheRoot = [IO.Path]::GetFullPath((Join-Path $rootPath 'portable_config/cache/component-bootstrap'))
if (!$cacheRoot.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe bootstrap directory' }
$cursor = $cacheRoot
while ($cursor -and $cursor -ne $rootPath) {
    if ((Test-Path -LiteralPath $cursor) -and ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Bootstrap cache cannot contain a junction/symbolic link'
    }
    $cursor = Split-Path $cursor -Parent
}
try {
    if (!$python) {
        [IO.Directory]::CreateDirectory($cacheRoot) | Out-Null
        if ($Catalog -match '^https://') {
            $catalogPath = Join-Path $cacheRoot ('catalog-' + [guid]::NewGuid().ToString('N') + '.json')
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Catalog -OutFile $catalogPath -PassThru
            if ($response.BaseResponse.ResponseUri.Scheme -ne 'https') { throw 'Catalog redirected outside HTTPS' }
        } else { $catalogPath = (Resolve-Path -LiteralPath $Catalog).Path }
        if ((Get-Item -LiteralPath $catalogPath).Length -gt 2MB) { throw 'Catalog too large' }
        $data = [IO.File]::ReadAllText($catalogPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $boot = $data.bootstrap
        if ($data.schema -ne 1 -or $boot.sha256 -notmatch '^[a-f0-9]{64}$' -or
            $boot.archive -notmatch '^bootstrap-[a-f0-9]{16}\.zip$' -or $boot.bytes -le 0 -or $boot.bytes -gt 128MB) {
            throw 'Invalid pinned bootstrap metadata'
        }
        $zip = Join-Path $cacheRoot $boot.archive
        if (!(Test-Path -LiteralPath $zip) -or (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $boot.sha256) {
            if ($Catalog -match '^https://') {
                $uri = [Uri]::new([Uri]$Catalog, $boot.archive)
                $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile ($zip + '.part') -PassThru
                if ($response.BaseResponse.ResponseUri.Scheme -ne 'https') { throw 'Bootstrap redirected outside HTTPS' }
            } else {
                Copy-Item -LiteralPath (Join-Path (Split-Path $catalogPath -Parent) $boot.archive) -Destination ($zip + '.part')
            }
            if ((Get-Item -LiteralPath ($zip + '.part')).Length -ne $boot.bytes -or
                (Get-FileHash -LiteralPath ($zip + '.part') -Algorithm SHA256).Hash -ne $boot.sha256) { throw 'Bootstrap hash/size mismatch' }
            Move-Item -LiteralPath ($zip + '.part') -Destination $zip -Force
        }
        $bootstrapRuntime = Join-Path $cacheRoot ('runtime-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($bootstrapRuntime) | Out-Null
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $archive.Entries) {
                if ($entry.FullName -notmatch '^(python[\w.]*\.(exe|dll|zip|_pth|cat)|[\w-]+\.(dll|pyd)|LICENSE[\w.]*\.txt)$' -or
                    !$seen.Add($entry.FullName) -or $entry.Length -gt 64MB -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000) {
                    throw 'Unexpected bootstrap archive entry'
                }
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $bootstrapRuntime $entry.FullName), $false)
            }
        } finally { $archive.Dispose() }
        $python = Join-Path $bootstrapRuntime 'python.exe'
    }
    $taskArguments = @((Join-Path $PSScriptRoot 'components.py'), $Action.ToLowerInvariant(), '--mpv-root', $rootPath)
    if ($Action -eq 'Install') { $taskArguments += @('--catalog', $Catalog) }
    if ($Action -ne 'Configure') { $taskArguments += @('--components') + $Components }
    & $python @taskArguments
    $resultCode = $LASTEXITCODE
} finally {
    if ($bootstrapRuntime) {
        $resolved = [IO.Path]::GetFullPath($bootstrapRuntime)
        if (!$resolved.StartsWith($cacheRoot + '\runtime-', [StringComparison]::OrdinalIgnoreCase) -or
            ((Get-Item -LiteralPath $resolved -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Unsafe bootstrap cleanup target' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
exit $resultCode
