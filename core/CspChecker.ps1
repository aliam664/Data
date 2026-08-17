Set-StrictMode -Version 2.0

function ConvertTo-UhmVersion {
    [CmdletBinding()]
    param([AllowNull()][string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return [Version]'0.0.0' }
    $match = [regex]::Match($Value, '\d+(?:\.\d+){1,3}')
    if (-not $match.Success) { return [Version]'0.0.0' }
    try { return [Version]$match.Value } catch { return [Version]'0.0.0' }
}

function Get-UhmCspStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$GamePath)
    $candidates = @(
        (Join-Path $GamePath 'extension\config\data_manifest.ini'),
        (Join-Path $GamePath 'extension\config\version.txt'),
        (Join-Path $GamePath 'extension\version.txt')
    )
    $versionText = $null
    $source = $null
    $isPreview = $false
    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $content = [IO.File]::ReadAllText($candidate)
            $match = [regex]::Match($content, '(?im)(?:version\s*=\s*)?v?(\d+\.\d+(?:\.\d+){0,2})')
            if ($match.Success) {
                $versionText = $match.Groups[1].Value
                $source = $candidate
                $isPreview = $content -match '(?i)preview'
                break
            }
        } catch {}
    }
    $installed = (Test-Path -LiteralPath (Join-Path $GamePath 'extension') -PathType Container)
    return [pscustomobject]@{
        installed = $installed
        version   = $versionText
        preview   = $isPreview
        source    = $source
    }
}

function Test-UhmCspCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Mod,
        [Parameter(Mandatory = $true)][string]$GamePath
    )
    $status = Get-UhmCspStatus -GamePath $GamePath
    if (-not [bool]$Mod.requiresCsp) {
        return [pscustomobject]@{ compatible = $true; blocked = $false; message = 'این مود به CSP نیاز ندارد.'; status = $status }
    }
    $minimum = ConvertTo-UhmVersion ([string]$Mod.minCspVersion)
    $current = ConvertTo-UhmVersion ([string]$status.version)
    $compatible = $status.installed -and ($current -ge $minimum)
    if ([bool]$Mod.cspPreviewRequired -and -not $status.preview) { $compatible = $false }
    $block = $false
    if ($Mod.PSObject.Properties['blockInstall']) { $block = [bool]$Mod.blockInstall -and -not $compatible }
    $message = if ($compatible) { 'نسخه CSP با این مود سازگار است.' } else { 'نسخه CSP شما با این مود سازگار نیست.' }
    return [pscustomobject]@{ compatible = $compatible; blocked = $block; message = $message; status = $status; minimum = [string]$Mod.minCspVersion }
}
