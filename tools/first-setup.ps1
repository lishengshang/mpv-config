# Windows PowerShell 5.1 and later. Keep launcher and scripts in the release layout.
[CmdletBinding()]
param(
    [ValidateSet('Menu','Whisper','VapourSynth','Qwen','SenseVoice','Enable','Disable','Rollback','Migrate')][string]$Action = 'Menu',
    [ValidateSet('cpu','cuda')][string]$Device = 'cpu',
    [ValidateSet('huggingface','modelscope')][string]$ModelSource = 'huggingface',
    [string]$DownloadDirectory = '',
    [ValidateSet('whisper','rtx')][string]$Feature = 'whisper',
    [string]$From = ''
)

$ErrorActionPreference = 'Stop'
$config = Split-Path $PSScriptRoot -Parent
$player = Split-Path $config -Parent
$baseLayout = Test-Path -LiteralPath (Join-Path $player 'start-mpv.cmd') -PathType Leaf
if (!(Test-Path -LiteralPath (Join-Path $player 'mpv.exe') -PathType Leaf)) {
    throw 'Put portable_config next to mpv.exe before running setup.'
}
if ($Action -eq 'Menu') {
    Write-Host '1  Whisper subtitles (CPU, recommended for first setup)'
    Write-Host '2  Whisper subtitles (NVIDIA CUDA)'
    Write-Host '3  NVIDIA RTX (VapourSynth)'
    if ($baseLayout) {
        Write-Host '4  Change extension state'
        Write-Host '5  Migrate from an older player'
    } else {
        Write-Host '4  Qwen AI subtitles (NVIDIA CUDA)'
        Write-Host '5  SenseVoice AI subtitles (NVIDIA CUDA)'
    }
    Write-Host '0  Exit'
    $choice = Read-Host 'Choose a component'
    switch ($choice) {
        '1' { $Device = 'cpu' }
        '2' { $Device = 'cuda' }
        '3' { $Action = 'VapourSynth' }
        '4' {
            if (!$baseLayout) { $Action = 'Qwen'; break }
            $Feature = Read-Host 'Extension (whisper or rtx)'
            $Action = Read-Host 'Action (Enable, Disable, Rollback)'
        }
        '5' { $Action = $(if ($baseLayout) { 'Migrate' } else { 'SenseVoice' }) }
        '0' { return }
        default { throw 'Invalid selection.' }
    }
}

function Assert-LocalPath([string]$Path) {
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Setup paths cannot contain a junction or symbolic link: $cursor"
            }
        }
        $cursor = Split-Path $cursor -Parent
    }
}

if ($Action -notin @('Menu','Whisper','VapourSynth','Qwen','SenseVoice','Enable','Disable','Rollback','Migrate') -or
    $Feature -notin @('whisper','rtx')) { throw 'Invalid setup selection.' }

$baseStateScript = Join-Path $PSScriptRoot 'base-state.ps1'
if ($baseLayout) { . $baseStateScript }

function Get-Sha256([string]$Path) {
    $inputFile = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return [BitConverter]::ToString($sha.ComputeHash($inputFile)).Replace('-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
        $inputFile.Dispose()
    }
}

function Test-Asset([string]$Path, $Asset) {
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and
        ((Get-Item -LiteralPath $Path).Length -eq $Asset.bytes) -and
        ((Get-Sha256 $Path) -ieq $Asset.sha256)
}

function Get-Asset($Asset, [string]$Destination) {
    Assert-LocalPath $Destination
    if (Test-Asset $Destination $Asset) {
        return
    }
    $partial = "$Destination.part"
    Assert-LocalPath $partial
    if (Test-Asset $partial $Asset) {
        Move-Item -LiteralPath $partial -Destination $Destination -Force
        return
    }
    if ((Test-Path -LiteralPath $partial -PathType Leaf) -and
        ((Get-Item -LiteralPath $partial).Length -ge $Asset.bytes)) {
        [IO.File]::Delete($partial)
    }
    if ($DownloadDirectory) {
        $original = Join-Path $DownloadDirectory $Asset.name
        if (!(Test-Path -LiteralPath $original -PathType Leaf)) {
            throw "Missing offline file: $($Asset.name)"
        }
        Copy-Item -LiteralPath $original -Destination $partial -Force
    } elseif ($From -and (Test-Asset (Join-Path $From ('portable_config/cache/first-setup/downloads/' + $Asset.name)) $Asset)) {
        $original = Join-Path $From ('portable_config/cache/first-setup/downloads/' + $Asset.name)
        Assert-LocalPath $original
        Copy-Item -LiteralPath $original -Destination $partial -Force
    } else {
        Write-Host "Downloading $($Asset.name) ..."
        & "$env:SystemRoot\System32\curl.exe" --fail --location --retry 2 --continue-at - --connect-timeout 20 --speed-time 90 --speed-limit 4096 --proto '=https' --proto-redir '=https' --output $partial $Asset.url
        if ($LASTEXITCODE) {
            throw "Download failed: $($Asset.name). Run setup again to retry."
        }
    }
    if (!(Test-Asset $partial $Asset)) {
        throw "SHA256 or size mismatch: $($Asset.name)"
    }
    Move-Item -LiteralPath $partial -Destination $Destination -Force
}


function Remove-Stage([string]$Path) {
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    Assert-LocalPath $resolved
    if (!(Split-Path $resolved -Parent).Equals($cache, [StringComparison]::OrdinalIgnoreCase) -or
        (Get-ChildItem -LiteralPath $resolved -Recurse -Force -Attributes ReparsePoint | Select-Object -First 1)) {
        throw 'Unexpected staging cleanup location.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

function Install-VapourSynth($Sources) {
    $modelsReady = $true
    foreach ($asset in $Sources.artcnn_chroma) {
        $installed = Join-Path $player ('vs-plugins\models\ArtCNN\' + $asset.name)
        Assert-LocalPath $installed
        if (!(Test-Asset $installed $asset)) { $modelsReady = $false }
    }
    $receiptPath = Join-Path $config 'state\components\vs.json'
    Assert-LocalPath $receiptPath
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        $receipt = Get-Content -LiteralPath $receiptPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($baseLayout -and ($receipt.version -ne $Sources.vapoursynth_version -or
                $receipt.archive_sha256 -ne $Sources.vapoursynth_archive_sha256)) {
            throw 'A different VS version is installed. Install the version from this package in a new Base folder.'
        }
    }
    if ($modelsReady -and $receipt) {
        $python = Join-Path $player 'python.exe'
        Assert-LocalPath $python
        & $python -B (Join-Path $PSScriptRoot 'maintenance/components.py') configure --mpv-root $player
        if ($LASTEXITCODE) { throw 'VapourSynth path repair failed.' }
        Write-Host 'VapourSynth is already installed.'
        return
    }
    foreach ($asset in $Sources.vapoursynth) {
        Get-Asset $asset (Join-Path $download $asset.name)
    }
    $stage = Join-Path $cache ('vs-' + [guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($stage) | Out-Null
    $archive = Join-Path $stage 'upstream.7z'
    $sink = [IO.File]::Open($archive, [IO.FileMode]::CreateNew)
    try {
        foreach ($asset in $Sources.vapoursynth) {
            $source = [IO.File]::OpenRead((Join-Path $download $asset.name))
            try { $source.CopyTo($sink) } finally { $source.Dispose() }
        }
    } finally { $sink.Dispose() }
    $archiveHash = (Get-Sha256 $archive)
    if ($archiveHash -ne $Sources.vapoursynth_archive_sha256) {
        throw 'VapourSynth combined archive checksum does not match the pinned source.'
    }
    $payload = Join-Path $stage 'payload'
    [IO.Directory]::CreateDirectory($payload) | Out-Null
    Write-Host 'Extracting the upstream VapourSynth package ...'
    & "$env:SystemRoot\System32\tar.exe" -xf $archive -C $payload
    if ($LASTEXITCODE) { throw 'Could not extract VapourSynth.' }
    [IO.File]::Delete($archive)
    $candidates = @(Get-ChildItem -LiteralPath $payload -Filter 'portable.vs' -File -Recurse | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.DirectoryName 'VSScript.dll') -PathType Leaf
    })
    if ($candidates.Count -ne 1) { throw 'Expected exactly one portable VS runtime.' }
    $runtime = $candidates[0].DirectoryName
    $artcnn = Join-Path $runtime 'vs-plugins\models\ArtCNN'
    Assert-LocalPath $artcnn
    [IO.Directory]::CreateDirectory($artcnn) | Out-Null
    foreach ($asset in $Sources.artcnn_chroma) {
        $destination = Join-Path $artcnn $asset.name
        Assert-LocalPath $destination
        Get-Asset $asset (Join-Path $download $asset.name)
        if (!(Test-Asset $destination $asset)) {
            [IO.File]::Copy((Join-Path $download $asset.name), $destination)
        }
    }
    $python = Join-Path $runtime 'python.exe'
    Assert-LocalPath $python
    & $python -B (Join-Path $PSScriptRoot 'maintenance/install_upstream_vs.py') $player $runtime $archiveHash $Sources.vapoursynth_version
    if ($LASTEXITCODE) { throw 'VapourSynth installation or its native frame probe failed.' }
    Remove-Stage $stage
    Write-Host 'VapourSynth installed.'
}


function Invoke-Checked([string]$Program, [string[]]$Arguments, [string]$Failure) {
    & $Program @Arguments
    if ($LASTEXITCODE) { throw $Failure }
}

function Install-ExtraAsr([string]$Backend, $UvArchive) {
    $ffmpeg = Join-Path $player 'ffmpeg.exe'
    Assert-LocalPath $ffmpeg
    if (!(Test-Path -LiteralPath $ffmpeg -PathType Leaf)) {
        throw 'This component needs the FFmpeg bundled in the Windows player release.'
    }
    $archive = Join-Path $download $UvArchive.name
    Get-Asset $UvArchive $archive
    $bootstrap = Join-Path $cache 'uv-0.13.1'
    $uv = Join-Path $bootstrap 'uv.exe'
    Assert-LocalPath $uv
    if (!(Test-Path -LiteralPath $uv -PathType Leaf)) {
        [IO.Directory]::CreateDirectory($bootstrap) | Out-Null
        & "$env:SystemRoot\System32\tar.exe" -xf $archive -C $bootstrap
        if ($LASTEXITCODE) { throw 'Could not extract uv.' }
    }
    $directory = "$($Backend.ToLowerInvariant())-cuda128"
    $root = Join-Path $components $directory
    $pythonRoot = Join-Path $root 'python'
    $pythonRelative = 'python/cpython-3.12.12-windows-x86_64-none/python.exe'
    $python = Join-Path $root $pythonRelative
    Assert-LocalPath $python
    $uvCache = Join-Path $cache 'uv-cache'
    Assert-LocalPath $uvCache
    Invoke-Checked $uv @('python','install','3.12.12','--install-dir',$pythonRoot,'--no-bin','--no-registry','--cache-dir',$uvCache) 'Python download failed.'
    $pip = @('pip','install','--python',$python,'--break-system-packages','--link-mode','copy','--cache-dir',$uvCache)
    $torch = @('torch==2.8.0')
    if ($Backend -eq 'SenseVoice') { $torch += 'torchaudio==2.8.0' }
    Invoke-Checked $uv ($pip + $torch + @('--index-url','https://download.pytorch.org/whl/cu128')) 'CUDA runtime download or installation failed.'
    $requirements = @('huggingface-hub==0.36.2','hf-xet==1.2.0','numpy==1.26.4')
    if ($Backend -eq 'Qwen') {
        $requirements += @('qwen-asr==0.0.6','librosa==0.11.0')
        $probe = 'import torch,qwen_asr; assert torch.cuda.is_available(); print(torch.cuda.get_device_name())'
    } else {
        $requirements += 'funasr==1.4.16'
        $probe = 'import torch,torchaudio,funasr; assert torch.cuda.is_available(); print(torch.cuda.get_device_name())'
    }
    Invoke-Checked $uv ($pip + $requirements) "$Backend package installation failed."
    Invoke-Checked $python @('-B','-c',$probe) "$Backend needs a working NVIDIA CUDA device and compatible driver."
    $models = Join-Path $root 'models'
    $prefix = "~~/../components/$directory"
    $settings = [ordered]@{}
    $settings['sub_fastwhisper-ffmpeg_path'] = '~~/../ffmpeg.exe'
    if ($Backend -eq 'Qwen') {
        Invoke-Checked $python @('-B',(Join-Path $PSScriptRoot 'maintenance/download_qwen_models.py'),(Join-Path $models 'qwen'),'--source',$ModelSource) 'Qwen model download failed.'
        $settings['sub_fastwhisper-qwen_python'] = "$prefix/$pythonRelative"
        $settings['sub_fastwhisper-qwen_model'] = "$prefix/models/qwen/Qwen3-ASR-1.7B"
        $settings['sub_fastwhisper-qwen_small_model'] = "$prefix/models/qwen/Qwen3-ASR-0.6B"
        $settings['sub_fastwhisper-qwen_aligner'] = "$prefix/models/qwen/Qwen3-ForcedAligner-0.6B"
    } else {
        $settings['sub_fastwhisper-sensevoice_python'] = "$prefix/$pythonRelative"
        $settings['sub_fastwhisper-sensevoice_model'] = "$prefix/models/sensevoice/SenseVoiceSmall"
    }
    Invoke-Checked $python @('-B',(Join-Path $PSScriptRoot 'maintenance/download_ai_models.py'),$models,'--only',$Backend.ToLowerInvariant(),'--source',$ModelSource) "$Backend model download failed."
    Update-PrivateSettings $settings
    Write-Host "$Backend installed. Select it under Subtitles > AI subtitles in mpv."
}

function Update-PrivateSettings([Collections.IDictionary]$Settings) {
    $localPath = Join-Path $config 'local.conf'
    Assert-LocalPath $localPath
    $text = if (Test-Path -LiteralPath $localPath) {
        [IO.File]::ReadAllText($localPath, [Text.Encoding]::UTF8)
    } else { '' }
    foreach ($key in $settings.Keys) {
        $pattern = '(?m)^[ \t]*script-opts-append[ \t]*=[ \t]*' + [regex]::Escape($key) + '=[^\r\n]*(?:\r?\n|$)'
        $text = [regex]::Replace($text, $pattern, '')
    }
    $text = $text.TrimEnd([char[]]@([char]13,[char]10))
    foreach ($key in $settings.Keys) {
        if ($text) { $text += [Environment]::NewLine }
        $text += "script-opts-append=$key=$($settings[$key])"
    }
    $backup = Join-Path $cache ('local.conf.' + [guid]::NewGuid().ToString('N') + '.bak')
    Save-SetupConfig $localPath $text $backup
}

function Save-SetupConfig([string]$Path, [string]$Text, [string]$Backup) {
    Assert-LocalPath $Path
    Assert-LocalPath $Backup
    $pending = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    $payload = [Text.UTF8Encoding]::new($false).GetBytes(($Text.Replace([Environment]::NewLine, [string][char]10).TrimEnd([char]10) + [char]10))
    $stream = [IO.File]::Open($pending, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stream.Write($payload, 0, $payload.Length)
    } finally {
        $stream.Dispose()
    }
    try {
        if (Test-Path -LiteralPath $Path) {
            [IO.File]::Replace($pending, $Path, $Backup)
        } else {
            [IO.File]::Move($pending, $Path)
        }
    } finally {
        if (Test-Path -LiteralPath $pending) {
            [IO.File]::Delete($pending)
        }
    }
}

$cache = Join-Path $config 'cache\first-setup'
$download = Join-Path $cache 'downloads'
$components = Join-Path $player 'components'
if ($Action -eq 'Migrate') {
    if (!$baseLayout) { throw 'This action requires a Base player package.' }
    . (Join-Path $PSScriptRoot 'migrate-base.ps1')
    return
}
foreach ($path in $cache,$download,$components) {
    Assert-LocalPath $path
    [IO.Directory]::CreateDirectory($path) | Out-Null
}
$lockFile = Join-Path $cache 'setup.lock'
Assert-LocalPath $lockFile
$lock = [IO.File]::Open($lockFile, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    $catalog = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'first-setup-sources.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Action -in @('Enable','Disable','Rollback')) {
        if (!$baseLayout) { throw 'This action requires a Base player package.' }
        Change-FeatureState $Feature $Action
        Write-Host 'Saved. Reopen the player to apply changes.'
        return
    }
    if ($Action -eq 'VapourSynth') {
        Install-VapourSynth $catalog
        if ($baseLayout) {
            Set-FeatureConfig 'rtx' ([ordered]@{'gpu-effects-runtime_path' = '~~/../'})
            Write-Host 'Reopen with start-mpv.cmd.'
        } else {
            Write-Host 'Start with mpv-components.cmd.'
        }
        return
    }
    if ($Action -in @('Qwen','SenseVoice')) {
        if ($baseLayout) { throw 'Use an older full config for these backends until their Base integration is available.' }
        Install-ExtraAsr $Action $catalog.uv
        return
    }
    $whisper = $catalog.whisper
    $destination = Join-Path $components $whisper.directory
    Assert-LocalPath $destination
    $modelFolder = 'faster-whisper-large-v3-turbo'
    $stage = Join-Path $cache ('whisper-' + [guid]::NewGuid().ToString('N'))
    $newInstall = !(Test-Path -LiteralPath $destination)
    if ($newInstall) {
        $archive = Join-Path $download $whisper.archive.name
        Get-Asset $whisper.archive $archive
        [IO.Directory]::CreateDirectory($stage) | Out-Null
        Write-Host 'Extracting Faster-Whisper-XXL ...'
        & "$env:SystemRoot\System32\tar.exe" -xf $archive -C $stage
        if ($LASTEXITCODE) { throw 'Could not extract Faster-Whisper-XXL.' }
        $runtime = Join-Path $stage 'Faster-Whisper-XXL'
        $model = Join-Path $runtime "_models\$modelFolder"
        [IO.Directory]::CreateDirectory($model) | Out-Null
        foreach ($asset in $whisper.model) {
            Get-Asset $asset (Join-Path $download $asset.name)
            Copy-Item -LiteralPath (Join-Path $download $asset.name) -Destination (Join-Path $model $asset.name)
        }
    } else {
        $runtime = $destination
        $model = Join-Path $runtime "_models\$modelFolder"
        foreach ($asset in $whisper.model) {
            $file = Join-Path $model $asset.name
            Assert-LocalPath $file
            if (!(Test-Asset $file $asset)) {
                throw "Existing model does not match this release: $file"
            }
        }
    }
    $binary = Join-Path $runtime 'faster-whisper-xxl.exe'
    $ffmpeg = Join-Path $runtime 'ffmpeg.exe'
    foreach ($path in $binary,$ffmpeg) {
        Assert-LocalPath $path
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing runtime file: $path" }
    }
    & $binary --version
    if ($LASTEXITCODE) { throw 'Whisper runtime check failed.' }
    $ffmpegVersion = & $ffmpeg -hide_banner -version
    if ($LASTEXITCODE) { throw 'FFmpeg runtime check failed.' }
    Write-Host ($ffmpegVersion | Select-Object -First 1)
    if ($newInstall) {
        [IO.Directory]::Move($runtime, $destination)
    }
    $prefix = "~~/../components/$($whisper.directory)"
    $settings = [ordered]@{
        'sub_fastwhisper-fast_whisper_path' = "$prefix/faster-whisper-xxl.exe"
        'sub_fastwhisper-ffmpeg_path' = "$prefix/ffmpeg.exe"
        'sub_fastwhisper-whisper_model_dir' = "$prefix/_models"
        'sub_fastwhisper-model' = 'large-v3-turbo'
        'sub_fastwhisper-device' = $Device
        'sub_fastwhisper-compute_type' = $(if ($Device -eq 'cuda') { 'float16' } else { 'int8' })
    }
    if ($baseLayout) {
        $settings['sub_fastwhisper-output_path'] = '~~/files/subtitles'
        Set-FeatureConfig 'whisper' $settings
    } else {
        Update-PrivateSettings $settings
    }
    if ($newInstall) { Remove-Stage $stage }
    Write-Host 'Whisper installed. Open a video in mpv and press Alt+F.'
} finally {
    $lock.Dispose()
}
