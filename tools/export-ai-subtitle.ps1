# Explicit export only. Automatic recognition continues to write exclusively to cache.
param(
    [Parameter(Mandatory=$true)][string]$Source,
    [string]$SuggestedName = 'subtitles.srt',
    [string]$Destination = ''
)
$ErrorActionPreference = 'Stop'
try {
    if (!(Test-Path -LiteralPath $Source -PathType Leaf)) { throw 'Completed subtitle missing.' }
    $overwriteApproved = $false
    if (!$Destination) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = [System.Windows.Forms.SaveFileDialog]::new()
        try {
            $dialog.Filter = 'SubRip subtitles (*.srt)|*.srt'
            $dialog.DefaultExt = 'srt'
            $dialog.AddExtension = $true
            $dialog.OverwritePrompt = $true
            $dialog.FileName = [IO.Path]::GetFileName($SuggestedName)
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { exit 2 }
            $Destination = $dialog.FileName
            $overwriteApproved = $true
        } finally { $dialog.Dispose() }
    }
    $sourcePath = [IO.Path]::GetFullPath($Source)
    $targetPath = [IO.Path]::GetFullPath($Destination)
    if ($sourcePath -eq $targetPath) { throw 'Source and destination must differ.' }
    if ([IO.Path]::GetExtension($targetPath) -ne '.srt') { throw 'Choose an .srt destination.' }
    [IO.File]::Copy($sourcePath, $targetPath, $overwriteApproved)
    Write-Output $targetPath
    exit 0
} catch { Write-Error $_; exit 1 }
