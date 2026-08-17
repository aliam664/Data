Set-StrictMode -Version 2.0

function Get-UhmDefaultSettings {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        appVersion          = '0.2.0'
        catalogUrl          = 'https://raw.githubusercontent.com/aliam664/Data/main/catalog/catalog.json'
        gamePaths           = @()
        ignoredGamePaths    = @()
        defaultGamePathId   = $null
        downloadDirectory   = (Join-Path $script:UhmProjectRoot 'data\downloads')
        maxConcurrentDownloads = 2
        cacheEnabled        = $true
        lastCatalogRefresh  = $null
        catalogVersion      = $null
    }
}

function Save-UhmSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Settings)
    $settingsDirectory = Join-Path $script:UhmProjectRoot 'data\settings'
    if (-not (Test-Path -LiteralPath $settingsDirectory -PathType Container)) { New-Item -ItemType Directory -Path $settingsDirectory -Force | Out-Null }
    $path = Join-Path $settingsDirectory 'settings.json'
    $temporary = $path + '.tmp'
    $json = $Settings | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Get-UhmSettings {
    [CmdletBinding()]
    param([switch]$DetectSteam)
    $defaults = Get-UhmDefaultSettings
    $path = Join-Path $script:UhmProjectRoot 'data\settings\settings.json'
    $settings = $defaults
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $saved = [IO.File]::ReadAllText($path) | ConvertFrom-Json
            foreach ($property in $defaults.PSObject.Properties) {
                if ($saved.PSObject.Properties[$property.Name]) { $settings.$($property.Name) = $saved.$($property.Name) }
            }
        } catch {
            Write-UhmLog -Level WARN -Event 'settings.invalid' -Data @{ error = $_.Exception.Message }
        }
    }
    # The application version is owned by the code, not by a stale persisted setting.
    $settings.appVersion = $defaults.appVersion
    $validPaths = New-Object System.Collections.Generic.List[object]
    foreach ($gamePath in @($settings.gamePaths)) {
        if ($gamePath.PSObject.Properties['path']) {
            $validPaths.Add([pscustomobject]@{
                id      = [string]$gamePath.id
                name    = [string]$gamePath.name
                path    = [string]$gamePath.path
                source  = if ($gamePath.PSObject.Properties['source']) { [string]$gamePath.source } else { 'manual' }
                isValid = Test-UhmGamePath ([string]$gamePath.path)
            })
        }
    }
    if ($DetectSteam) {
        foreach ($detected in @(Find-UhmAssettoCorsaInstallations)) {
            $exists = @($validPaths | Where-Object { [string]::Equals($_.path, $detected.path, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            $ignored = @($settings.ignoredGamePaths | Where-Object { [string]::Equals([string]$_, $detected.path, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            if (-not $exists -and -not $ignored) { $validPaths.Add($detected) }
        }
    }
    # Windows PowerShell 5.1 can throw "Argument types do not match" when @()
    # materializes a generic List[object]. ToArray() avoids that DLR bug.
    $settings.gamePaths = $validPaths.ToArray()
    if ([string]::IsNullOrWhiteSpace([string]$settings.defaultGamePathId) -or
        @($validPaths | Where-Object { $_.id -eq $settings.defaultGamePathId -and $_.isValid }).Count -eq 0) {
        $first = $validPaths | Where-Object { $_.isValid } | Select-Object -First 1
        $settings.defaultGamePathId = if ($null -ne $first) { $first.id } else { $null }
    }
    if ([int]$settings.maxConcurrentDownloads -lt 1) { $settings.maxConcurrentDownloads = 1 }
    if ([int]$settings.maxConcurrentDownloads -gt 4) { $settings.maxConcurrentDownloads = 4 }
    if ([string]::IsNullOrWhiteSpace([string]$settings.downloadDirectory)) { $settings.downloadDirectory = $defaults.downloadDirectory }
    if (-not (Test-Path -LiteralPath $settings.downloadDirectory -PathType Container)) { New-Item -ItemType Directory -Path $settings.downloadDirectory -Force | Out-Null }
    Save-UhmSettings $settings
    return $settings
}

function Add-UhmGamePath {
    [CmdletBinding()]
    param($Settings, [string]$Path, [string]$Name)
    if (-not (Test-UhmGamePath $Path)) { throw 'مسیر Assetto Corsa معتبر نیست.' }
    $full = [IO.Path]::GetFullPath($Path)
    if (@($Settings.gamePaths | Where-Object { [string]::Equals($_.path, $full, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { return $Settings }
    $id = 'manual-' + ([Guid]::NewGuid().ToString('N').Substring(0, 10))
    if ([string]::IsNullOrWhiteSpace($Name)) { $Name = 'مسیر دستی' }
    $Settings.ignoredGamePaths = @($Settings.ignoredGamePaths | Where-Object { -not [string]::Equals([string]$_, $full, [StringComparison]::OrdinalIgnoreCase) })
    $Settings.gamePaths = @($Settings.gamePaths) + [pscustomobject]@{ id = $id; name = $Name; path = $full; source = 'manual'; isValid = $true }
    if ([string]::IsNullOrWhiteSpace([string]$Settings.defaultGamePathId)) { $Settings.defaultGamePathId = $id }
    Save-UhmSettings $Settings
    return $Settings
}

function Remove-UhmGamePath {
    [CmdletBinding()]
    param($Settings, [string]$Id)
    $removed = $Settings.gamePaths | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if ($null -ne $removed) { $Settings.ignoredGamePaths = @((@($Settings.ignoredGamePaths) + [string]$removed.path) | Select-Object -Unique) }
    $Settings.gamePaths = @($Settings.gamePaths | Where-Object { $_.id -ne $Id })
    if ($Settings.defaultGamePathId -eq $Id) {
        $first = $Settings.gamePaths | Where-Object { $_.isValid } | Select-Object -First 1
        $Settings.defaultGamePathId = if ($null -ne $first) { $first.id } else { $null }
    }
    Save-UhmSettings $Settings
    return $Settings
}
