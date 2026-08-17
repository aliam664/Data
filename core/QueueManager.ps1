Set-StrictMode -Version 2.0

function Get-UhmQueueRoot {
    $path = Join-Path $script:UhmProjectRoot 'data\settings\queue'
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    return $path
}

function Write-UhmJsonAtomic {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temporary = $Path + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    $json = $Value | ConvertTo-Json -Depth 20
    [IO.File]::WriteAllText($temporary, $json, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function New-UhmQueueItem {
    [CmdletBinding()]
    param($Mod, [string]$TargetId, [string]$TargetPath, [bool]$InstallAfterDownload, [string]$DownloadDirectory)
    $id = [Guid]::NewGuid().ToString('N')
    $extension = if ([string]$Mod.archiveType -eq 'tar.gz') { '.tar.gz' } else { '.' + ([string]$Mod.archiveType).ToLowerInvariant() }
    $safeFileName = ([string]$Mod.id -replace '[^a-zA-Z0-9._-]', '_') + '-' + ([string]$Mod.version -replace '[^a-zA-Z0-9._-]', '_') + $extension
    $downloadPath = Join-Path $DownloadDirectory $safeFileName
    $now = [DateTime]::UtcNow.ToString('o')
    $state = [ordered]@{
        id = $id; modId = [string]$Mod.id; name = [string]$Mod.name; nameFa = [string]$Mod.nameFa
        version = [string]$Mod.version; image = [string]$Mod.image; targetId = $TargetId; targetPath = $TargetPath
        downloadPath = $downloadPath; installAfterDownload = $InstallAfterDownload; status = 'queued'; progress = 0
        bytesReceived = 0; totalBytes = [long]$Mod.sizeBytes; speedBytes = 0; etaSeconds = $null
        error = $null; httpCode = $null; createdAt = $now; updatedAt = $now; order = [DateTime]::UtcNow.Ticks
    }
    $job = [ordered]@{ id = $id; mod = $Mod; targetId = $TargetId; targetPath = $TargetPath; downloadPath = $downloadPath; installAfterDownload = $InstallAfterDownload }
    $root = Get-UhmQueueRoot
    Write-UhmJsonAtomic -Path (Join-Path $root ($id + '.state.json')) -Value $state
    Write-UhmJsonAtomic -Path (Join-Path $root ($id + '.job.json')) -Value $job
    return [pscustomobject]$state
}

function Get-UhmQueueItems {
    [CmdletBinding()]
    param()
    $items = @()
    foreach ($file in @(Get-ChildItem -LiteralPath (Get-UhmQueueRoot) -Filter '*.state.json' -File -ErrorAction SilentlyContinue)) {
        try { $items += ,([IO.File]::ReadAllText($file.FullName) | ConvertFrom-Json) } catch {}
    }
    return @($items | Sort-Object order)
}

function Get-UhmQueueItem {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Id)
    if ($Id -notmatch '^[a-f0-9]{32}$') { return $null }
    $path = Join-Path (Get-UhmQueueRoot) ($Id + '.state.json')
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return [IO.File]::ReadAllText($path) | ConvertFrom-Json } catch { return $null }
}

function Set-UhmQueueState {
    [CmdletBinding()]
    param([string]$Id, [hashtable]$Changes)
    $item = Get-UhmQueueItem $Id
    if ($null -eq $item) { throw 'آیتم صف پیدا نشد.' }
    foreach ($key in $Changes.Keys) {
        if ($item.PSObject.Properties[$key]) { $item.$key = $Changes[$key] }
        else { $item | Add-Member -NotePropertyName $key -NotePropertyValue $Changes[$key] }
    }
    $item.updatedAt = [DateTime]::UtcNow.ToString('o')
    Write-UhmJsonAtomic -Path (Join-Path (Get-UhmQueueRoot) ($Id + '.state.json')) -Value $item
    return $item
}

function Set-UhmQueueSignal {
    [CmdletBinding()]
    param([string]$Id, [ValidateSet('pause','cancel')][string]$Signal, [bool]$Enabled)
    if ($Id -notmatch '^[a-f0-9]{32}$') { throw 'شناسه صف معتبر نیست.' }
    $path = Join-Path (Get-UhmQueueRoot) ($Id + '.' + $Signal)
    if ($Enabled) { [IO.File]::WriteAllText($path, [DateTime]::UtcNow.ToString('o')) }
    elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Reset-UhmQueueItem {
    [CmdletBinding()]
    param([string]$Id)
    Set-UhmQueueSignal -Id $Id -Signal cancel -Enabled $false
    Set-UhmQueueSignal -Id $Id -Signal pause -Enabled $false
    return Set-UhmQueueState -Id $Id -Changes @{ status = 'queued'; error = $null; speedBytes = 0; etaSeconds = $null }
}

function Remove-UhmQueueItem {
    [CmdletBinding()]
    param([string]$Id, [bool]$Confirmed, [bool]$DeletePartial)
    if (-not $Confirmed) { throw 'حذف آیتم صف باید توسط کاربر تأیید شود.' }
    $item = Get-UhmQueueItem $Id
    if ($null -eq $item) { return }
    Set-UhmQueueSignal -Id $Id -Signal cancel -Enabled $true
    if ($DeletePartial) {
        foreach ($candidate in @([string]$item.downloadPath, ([string]$item.downloadPath + '.part'))) {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { Remove-Item -LiteralPath $candidate -Force }
        }
    }
    foreach ($suffix in @('.state.json','.job.json','.pause','.cancel')) {
        $path = Join-Path (Get-UhmQueueRoot) ($Id + $suffix)
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}
