# This entry only reads the old player. Each group requires an explicit yes.
if (!$From) { $From = (Read-Host 'Folder of the old player containing mpv.exe').Trim('"') }
$old = (Resolve-Path -LiteralPath $From).Path.TrimEnd('\')
if ($old -ieq $player -or $old.StartsWith($player + '\', [StringComparison]::OrdinalIgnoreCase) -or
    $player.StartsWith($old + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Use two separate player directories.'
}
Assert-LocalPath $old
$oldConfig = Join-Path $old 'portable_config'
Assert-LocalPath $oldConfig
if (!(Test-Path -LiteralPath (Join-Path $old 'mpv.exe') -PathType Leaf) -or
    !(Test-Path -LiteralPath $oldConfig -PathType Container)) {
    throw 'The old directory needs mpv.exe and portable_config.'
}

function Confirm-Migration([string]$Prompt) {
    return (Read-Host "$Prompt [y/N]") -ieq 'y'
}

function Copy-UserFiles([string]$Source, [string]$Target, [switch]$Subtitles) {
    if (!(Test-Path -LiteralPath $Source -PathType Container)) { return }
    Assert-LocalPath $Source
    Assert-LocalPath $Target
    foreach ($file in Get-ChildItem -LiteralPath $Source -File -Force -Recurse) {
        if ($file.Name -eq 'mpv.log') { continue }
        $relative = $file.FullName.Substring($Source.Length + 1)
        if ($Subtitles -and ($relative -match '(^|\\)work-[^\\]+\\' -or
            ($file.Extension -notin '.srt','.ass','.vtt' -and $file.Name -ne 'complete.json'))) {
            continue
        }
        Assert-LocalPath $file.FullName
        $destination = Join-Path $Target $relative
        Assert-LocalPath $destination
        if (Test-Path -LiteralPath $destination) { continue }
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        [IO.File]::Copy($file.FullName, $destination)
    }
}

$catalog = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'first-setup-sources.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$runtimePath = Join-Path $old "components\$($catalog.whisper.directory)\faster-whisper-xxl.exe"
$foundWhisper = Test-Path -LiteralPath $runtimePath -PathType Leaf
$foundRtx = (Test-Path -LiteralPath (Join-Path $old 'VSScript.dll') -PathType Leaf) -or
    (Test-Path -LiteralPath (Join-Path $oldConfig 'state\components\vs.json') -PathType Leaf)
$foundQwen = @(Get-ChildItem -LiteralPath (Join-Path $old 'components') -Directory -Filter 'qwen*' -ErrorAction SilentlyContinue).Count -gt 0
$foundSenseVoice = @(Get-ChildItem -LiteralPath (Join-Path $old 'components') -Directory -Filter 'sensevoice*' -ErrorAction SilentlyContinue).Count -gt 0
$oldLocal = Join-Path $oldConfig 'local.conf'
$foundLocal = Test-Path -LiteralPath $oldLocal -PathType Leaf
$progress = @('state\watch_later', 'cache\watch_later') | ForEach-Object { Join-Path $oldConfig $_ }
$oldFiles = Join-Path $oldConfig 'files'
$oldSubtitles = Join-Path $oldConfig 'cache\ai-subtitles'
$foundProgress = @(Get-ChildItem -LiteralPath $progress -File -ErrorAction SilentlyContinue).Count -gt 0
$foundSubtitles = @(Get-ChildItem -LiteralPath $oldSubtitles -ErrorAction SilentlyContinue | Select-Object -First 1).Count -gt 0
$foundFiles = @(Get-ChildItem -LiteralPath $oldFiles -Force -ErrorAction SilentlyContinue | Select-Object -First 1).Count -gt 0
Write-Host "Detected in $old"
Write-Host "  Whisper: $foundWhisper; RTX: $foundRtx"
Write-Host "  Qwen: $foundQwen; SenseVoice: $foundSenseVoice (available in the old player)"
Write-Host "  Playback progress: $foundProgress; Subtitle cache: $foundSubtitles; Personal files: $foundFiles"
Write-Host "  Private config: $foundLocal"
$copyData = ($foundProgress -or $foundSubtitles -or $foundFiles) -and
    (Confirm-Migration 'Copy playback progress, subtitles and personal files')
$copyLocal = $foundLocal -and (Confirm-Migration 'Save a private copy of old local.conf for review')
$keepWhisper = $foundWhisper -and (Confirm-Migration 'Restore and enable Whisper')
$keepRtx = $foundRtx -and (Confirm-Migration 'Restore and enable RTX VapourSynth')
if ($copyData) {
    foreach ($directory in $progress) { Copy-UserFiles $directory (Join-Path $config 'state\watch_later') }
    Copy-UserFiles $oldFiles (Join-Path $config 'files')
    Copy-UserFiles $oldSubtitles (Join-Path $config 'files\subtitles') -Subtitles
}
if ($copyLocal) {
    Assert-LocalPath $oldLocal
    $saved = Join-Path $config 'state\local-before-migration.conf'
    Assert-LocalPath $saved
    if (!(Test-Path -LiteralPath $saved)) { [IO.File]::Copy($oldLocal, $saved) }
    Write-Host 'Private settings saved for review in state\local-before-migration.conf.'
}
if ($keepWhisper) {
    $previousDevice = 'cpu'
    if ($foundLocal) {
        Assert-LocalPath $oldLocal
        if (Select-String -LiteralPath $oldLocal -Pattern '^\s*script-opts-append\s*=\s*sub_fastwhisper-device=cuda\s*$' -Quiet) {
            $previousDevice = 'cuda'
        }
    }
    & (Join-Path $PSScriptRoot 'first-setup.ps1') -Action Whisper -Device $previousDevice -From $old
}
if ($keepRtx) {
    & (Join-Path $PSScriptRoot 'first-setup.ps1') -Action VapourSynth -From $old
}
Write-Host 'Migration finished. Start the new player with start-mpv.cmd.'
