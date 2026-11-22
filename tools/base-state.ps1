# Loaded by first-setup.ps1. Only the installer writes these native mpv includes.
$featureScripts = @{}
$registry = Join-Path $config 'release/base/extensions.json'
foreach ($item in (Get-Content -LiteralPath $registry -Raw -Encoding UTF8 | ConvertFrom-Json)) {
    $featureScripts[$item.id] = '~~/' + $item.script
}

function Feature-Config([string]$Id) {
    if (!$featureScripts.ContainsKey($Id)) { throw 'Unknown extension.' }
    return (Join-Path $config "state\$Id.conf")
}

function Write-FeatureConfig([string]$Id, [string]$Text) {
    $path = Feature-Config $Id
    Assert-LocalPath $path
    if ((Test-Path -LiteralPath $path -PathType Leaf) -and
        (Get-FeatureConfig $Id).TrimEnd() -ceq $Text.TrimEnd()) { return }
    Save-SetupConfig $path $Text "$path.previous"
}

function Get-FeatureConfig([string]$Id) {
    $path = Feature-Config $Id
    Assert-LocalPath $path
    return [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
}

function Set-FeatureConfig([string]$Id, [Collections.IDictionary]$Settings) {
    $lines = @('# Installed', "script-opts-append=extensions-$Id=yes", "scripts-append=$($featureScripts[$Id])")
    foreach ($key in $Settings.Keys) { $lines += "script-opts-append=$key=$($Settings[$key])" }
    Write-FeatureConfig $Id ($lines -join [string][char]10)
}

function Change-FeatureState([string]$Id, [string]$Operation) {
    $path = Feature-Config $Id
    if ($Operation -eq 'Rollback') {
        Assert-LocalPath "$path.previous"
        if (!(Test-Path -LiteralPath "$path.previous" -PathType Leaf)) { throw 'No previous configuration is available.' }
        $previous = [IO.File]::ReadAllText("$path.previous", [Text.Encoding]::UTF8)
        Write-FeatureConfig $Id $previous
        return
    }
    $text = Get-FeatureConfig $Id
    if ($text -notmatch '(?m)^# Installed\r?$') { throw 'Install this extension first.' }
    $lines = @('# Installed')
    if ($Operation -eq 'Enable') {
        $lines += @("script-opts-append=extensions-$Id=yes", "scripts-append=$($featureScripts[$Id])")
    }
    $lines += @(($text -split '\r?\n') | Where-Object {
        $_ -like 'script-opts-append=*' -and $_ -notlike "script-opts-append=extensions-$Id=*"
    })
    Write-FeatureConfig $Id ($lines -join [string][char]10)
}
