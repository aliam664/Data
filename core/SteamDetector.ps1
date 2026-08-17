Set-StrictMode -Version 2.0

function Get-UhmSteamRoots {
    [CmdletBinding()]
    param()
    $roots = New-Object System.Collections.Generic.List[string]
    $registryKeys = @(
        'HKCU:\Software\Valve\Steam',
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )
    foreach ($key in $registryKeys) {
        try {
            $properties = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
            foreach ($name in @('SteamPath', 'InstallPath')) {
                if ($properties.PSObject.Properties[$name] -and -not [string]::IsNullOrWhiteSpace([string]$properties.$name)) {
                    $roots.Add(([IO.Path]::GetFullPath([string]$properties.$name)))
                }
            }
        } catch {}
    }
    $fallbacks = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) { $fallbacks.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam')) }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) { $fallbacks.Add((Join-Path $env:ProgramFiles 'Steam')) }
    foreach ($fallback in $fallbacks) {
        if (Test-Path -LiteralPath $fallback -PathType Container) { $roots.Add($fallback) }
    }
    return @($roots | Select-Object -Unique)
}

function Get-UhmSteamLibraries {
    [CmdletBinding()]
    param([string[]]$SteamRoots = (Get-UhmSteamRoots))
    $libraries = New-Object System.Collections.Generic.List[string]
    foreach ($root in $SteamRoots) {
        if (Test-Path -LiteralPath $root -PathType Container) { $libraries.Add(([IO.Path]::GetFullPath($root))) }
        $vdfPath = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdfPath -PathType Leaf)) { continue }
        try {
            $content = [IO.File]::ReadAllText($vdfPath)
            foreach ($match in [regex]::Matches($content, '(?im)"path"\s+"([^"]+)"')) {
                $value = $match.Groups[1].Value.Replace('\\', '\')
                if (-not [string]::IsNullOrWhiteSpace($value)) { $libraries.Add(([IO.Path]::GetFullPath($value))) }
            }
            # Legacy VDF uses numeric keys directly for library paths.
            foreach ($match in [regex]::Matches($content, '(?im)^\s*"\d+"\s+"([A-Za-z]:\\[^"]+)"')) {
                $value = $match.Groups[1].Value.Replace('\\', '\')
                $libraries.Add(([IO.Path]::GetFullPath($value)))
            }
        } catch {
            Write-UhmLog -Level WARN -Event 'steam.vdf.read_failed' -Data @{ path = $vdfPath; error = $_.Exception.Message }
        }
    }
    return @($libraries | Select-Object -Unique)
}

function Find-UhmAssettoCorsaInstallations {
    [CmdletBinding()]
    param()
    $results = New-Object System.Collections.Generic.List[object]
    $index = 1
    foreach ($library in (Get-UhmSteamLibraries)) {
        $gamePath = Join-Path $library 'steamapps\common\assettocorsa'
        if (Test-UhmGamePath $gamePath) {
            $results.Add([pscustomobject]@{
                id       = ('steam-{0}' -f $index)
                name     = ('Assetto Corsa {0}' -f $index)
                path     = [IO.Path]::GetFullPath($gamePath)
                source   = 'steam'
                isValid  = $true
            })
            $index++
        }
    }
    return $results.ToArray()
}

function Get-UhmSteamStatus {
    [CmdletBinding()]
    param()
    $roots = @(Get-UhmSteamRoots)
    $libraries = @(Get-UhmSteamLibraries -SteamRoots $roots)
    $installs = @(Find-UhmAssettoCorsaInstallations)
    return [pscustomobject]@{
        steamFound = ($roots.Count -gt 0)
        roots      = $roots
        libraries  = $libraries
        gamePaths  = $installs
    }
}
