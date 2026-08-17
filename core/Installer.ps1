Set-StrictMode -Version 2.0

function Get-UhmInstalledMods {
    [CmdletBinding()]
    param()
    $path = Join-Path $script:UhmProjectRoot 'data\settings\installed-mods.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return @() }
    try { return @([IO.File]::ReadAllText($path) | ConvertFrom-Json) } catch { return @() }
}

function Save-UhmInstalledMods {
    [CmdletBinding()]
    param([object[]]$Items)
    $path = Join-Path $script:UhmProjectRoot 'data\settings\installed-mods.json'
    Write-UhmJsonAtomic -Path $path -Value @($Items)
}

function ConvertTo-UhmInstallRelativePath {
    [CmdletBinding()]
    param([string]$ExtractedRelative, [string]$InstallRoot, [string]$InstallType)
    $path = $ExtractedRelative.Replace('/', '\').TrimStart('\')
    $parts = @($path.Split('\') | Where-Object { $_ -ne '' })
    if ($parts.Count -eq 0) { throw 'ساختار آرشیو قابل تشخیص نیست.' }
    $knownRoots = @('content','cars','tracks','apps','extension','system','cfg')
    if ($parts[0].ToLowerInvariant() -eq 'assettocorsa' -and $parts.Count -gt 1) { $parts = @($parts[1..($parts.Count - 1)]) }
    if ($parts.Count -gt 1 -and $knownRoots -notcontains $parts[0].ToLowerInvariant() -and $knownRoots -contains $parts[1].ToLowerInvariant()) {
        $parts = @($parts[1..($parts.Count - 1)])
    }
    $path = $parts -join '\'
    $first = $parts[0].ToLowerInvariant()
    $safeInstallRoot = $InstallRoot.Replace('/', '\').Trim('\')
    if (-not (Test-UhmSafeArchivePath $safeInstallRoot)) { throw 'مسیر نصب تعریف‌شده در کاتالوگ امن نیست.' }
    $rootParts = @($safeInstallRoot.Split('\'))
    if ($first -eq 'content') { return $path }
    if ($rootParts.Count -ge 2 -and $rootParts[0].ToLowerInvariant() -eq 'content' -and $first -eq $rootParts[1].ToLowerInvariant()) {
        return ('content\' + $path)
    }
    if ($first -eq $rootParts[0].ToLowerInvariant()) { return $path }
    if ($InstallType -in @('graphics','pack','root') -and $first -in @('extension','system','cfg','apps')) { return $path }
    return ($safeInstallRoot + '\' + $path)
}

function New-UhmInstallationPreview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Mod,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$GamePath,
        [bool]$ConfirmReinstall = $false,
        [AllowNull()][string]$QueueId
    )
    if (-not (Test-UhmGamePath $GamePath)) { throw 'مسیر Assetto Corsa پیدا نشد یا معتبر نیست.' }
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { throw 'فایل دانلودشده پیدا نشد.' }
    $installed = @(Get-UhmInstalledMods | Where-Object { $_.modId -eq [string]$Mod.id -and [string]::Equals($_.gamePath, $GamePath, [StringComparison]::OrdinalIgnoreCase) })
    if ($installed.Count -gt 0 -and -not $ConfirmReinstall) { throw 'این مود قبلاً نصب شده است؛ نصب دوباره به تأیید کاربر نیاز دارد.' }
    if (-not [string]::IsNullOrWhiteSpace([string]$Mod.sha256)) {
        $actualHash = Get-UhmFileSha256 $ArchivePath
        if ($actualHash -ne ([string]$Mod.sha256).ToLowerInvariant()) { throw 'هش SHA-256 فایل با کاتالوگ مطابقت ندارد.' }
    }
    $csp = Test-UhmCspCompatibility -Mod $Mod -GamePath $GamePath
    if ($csp.blocked) { throw $csp.message }
    $previewId = [Guid]::NewGuid().ToString('N')
    $stagingRoot = Join-Path $script:UhmProjectRoot ('data\cache\staging\' + $previewId)
    Expand-UhmArchiveSafely -ArchivePath $ArchivePath -ArchiveType ([string]$Mod.archiveType) -Destination $stagingRoot -PasswordRequired ([bool]$Mod.passwordRequired) -Password ([string]$Mod.password) | Out-Null
    try {
        $files = @(Get-ChildItem -LiteralPath $stagingRoot -File -Recurse -Force)
        if ($files.Count -eq 0) { throw 'آرشیو هیچ فایل قابل نصبی ندارد.' }
        $plan = New-Object System.Collections.Generic.List[object]
        $destinations = @{}
        $overwrites = New-Object System.Collections.Generic.List[string]
        $executables = New-Object System.Collections.Generic.List[string]
        $scriptExtensions = @('.exe','.com','.bat','.cmd','.ps1','.vbs','.vbe','.js','.jse','.wsf','.msi','.msp','.scr')
        foreach ($file in $files) {
            $relative = $file.FullName.Substring($stagingRoot.TrimEnd('\').Length).TrimStart('\')
            if (-not (Test-UhmSafeArchivePath $relative)) { throw 'مسیر آرشیو امن نیست.' }
            $installRelative = ConvertTo-UhmInstallRelativePath -ExtractedRelative $relative -InstallRoot ([string]$Mod.installRoot) -InstallType ([string]$Mod.installType)
            $destination = Get-UhmSafeChildPath -Root $GamePath -RelativePath $installRelative
            if ($destinations.ContainsKey($destination)) { throw 'دو فایل آرشیو به یک مسیر مقصد نگاشت می‌شوند؛ نصب امن نیست.' }
            $destinations[$destination] = $true
            if (Test-Path -LiteralPath $destination -PathType Container) { throw 'یک فایل آرشیو با پوشه موجود در مقصد تداخل دارد.' }
            $exists = Test-Path -LiteralPath $destination -PathType Leaf
            if ($exists) { $overwrites.Add($installRelative) }
            if ($scriptExtensions -contains $file.Extension.ToLowerInvariant()) { $executables.Add($installRelative) }
            $plan.Add([pscustomobject]@{ source = $file.FullName; destination = $destination; relative = $installRelative; exists = $exists; size = $file.Length })
        }
        $preview = [ordered]@{
            id = $previewId; queueId = $QueueId; modId = [string]$Mod.id; modName = [string]$Mod.nameFa; version = [string]$Mod.version
            gamePath = [IO.Path]::GetFullPath($GamePath); archivePath = [IO.Path]::GetFullPath($ArchivePath); stagingRoot = $stagingRoot
            createdAt = [DateTime]::UtcNow.ToString('o'); csp = $csp; fileCount = $plan.Count; totalBytes = [long](($plan | Measure-Object -Property size -Sum).Sum)
            overwrites = @($overwrites); executableFiles = @($executables); plan = @($plan)
        }
        Write-UhmJsonAtomic -Path (Join-Path $stagingRoot 'uhm-preview.json') -Value $preview
        Write-UhmLog -Event 'install.preview' -Data @{ mod = $Mod.id; destination = $GamePath; overwriteCount = $overwrites.Count; fileCount = $plan.Count; executableCount = $executables.Count; cspCompatible = $csp.compatible }
        return [pscustomobject]$preview
    } catch {
        if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Complete-UhmInstallation {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PreviewId, [bool]$OverwriteApproved)
    if ($PreviewId -notmatch '^[a-f0-9]{32}$') { throw 'شناسه پیش‌نمایش نصب معتبر نیست.' }
    $stagingRoot = Join-Path $script:UhmProjectRoot ('data\cache\staging\' + $PreviewId)
    $previewPath = Join-Path $stagingRoot 'uhm-preview.json'
    if (-not (Test-Path -LiteralPath $previewPath -PathType Leaf)) { throw 'پیش‌نمایش نصب منقضی یا پیدا نشد.' }
    $preview = [IO.File]::ReadAllText($previewPath) | ConvertFrom-Json
    if (-not [string]::Equals([IO.Path]::GetFullPath($preview.stagingRoot), [IO.Path]::GetFullPath($stagingRoot), [StringComparison]::OrdinalIgnoreCase)) { throw 'اطلاعات پیش‌نمایش نصب معتبر نیست.' }
    if (-not (Test-UhmGamePath ([string]$preview.gamePath))) { throw 'مسیر Assetto Corsa معتبر نیست.' }
    $currentOverwrites = New-Object System.Collections.Generic.List[string]
    foreach ($file in @($preview.plan)) {
        $sourceFull = [IO.Path]::GetFullPath([string]$file.source)
        $stagingPrefix = [IO.Path]::GetFullPath($stagingRoot).TrimEnd('\') + '\'
        if (-not $sourceFull.StartsWith($stagingPrefix, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $sourceFull -PathType Leaf)) { throw 'فایل موقت نصب معتبر نیست.' }
        $expectedDestination = Get-UhmSafeChildPath -Root ([string]$preview.gamePath) -RelativePath ([string]$file.relative)
        if (-not [string]::Equals($expectedDestination, [IO.Path]::GetFullPath([string]$file.destination), [StringComparison]::OrdinalIgnoreCase)) { throw 'مسیر مقصد نصب معتبر نیست.' }
        if (Test-Path -LiteralPath $expectedDestination -PathType Leaf) { $currentOverwrites.Add([string]$file.relative) }
    }
    if ($currentOverwrites.Count -gt 0 -and -not $OverwriteApproved) { throw 'فایل‌های زیر جایگزین خواهند شد؛ ادامه نصب به تأیید کاربر نیاز دارد.' }
    $mutex = New-Object Threading.Mutex($false, 'Local\UHM-Launcher-Install')
    if (-not $mutex.WaitOne(0)) { $mutex.Dispose(); throw 'یک نصب دیگر در حال تغییر فایل‌های بازی است.' }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        foreach ($file in @($preview.plan)) {
            $parent = Split-Path -Parent ([string]$file.destination)
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item -LiteralPath ([string]$file.source) -Destination ([string]$file.destination) -Force:$OverwriteApproved
        }
        $records = @(Get-UhmInstalledMods | Where-Object { -not ($_.modId -eq $preview.modId -and [string]::Equals($_.gamePath, $preview.gamePath, [StringComparison]::OrdinalIgnoreCase)) })
        $records += [pscustomobject]@{
            modId = [string]$preview.modId; nameFa = [string]$preview.modName; installedVersion = [string]$preview.version
            installedAt = [DateTime]::UtcNow.ToString('o'); gamePath = [string]$preview.gamePath; fileCount = [int]$preview.fileCount
            files = @($preview.plan | ForEach-Object { $_.relative }); removalSupported = $false; csp = $preview.csp
        }
        Save-UhmInstalledMods -Items $records
        $stopwatch.Stop()
        Write-UhmLog -Event 'install.success' -Data @{ mod = $preview.modId; destination = $preview.gamePath; status = 'installed'; fileCount = $preview.fileCount; overwriteCount = $currentOverwrites.Count; durationMs = $stopwatch.ElapsedMilliseconds }
        if (Test-Path -LiteralPath $stagingRoot) { Remove-Item -LiteralPath $stagingRoot -Recurse -Force }
        return [pscustomobject]@{ success = $true; message = 'نصب با موفقیت پایان یافت.'; modId = $preview.modId; fileCount = $preview.fileCount }
    } catch {
        $stopwatch.Stop()
        Write-UhmLog -Level ERROR -Event 'install.failed' -Data @{ mod = $preview.modId; destination = $preview.gamePath; status = 'failed'; error = $_.Exception.Message; durationMs = $stopwatch.ElapsedMilliseconds }
        throw
    } finally {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
}

function Invoke-UhmInstallWorkflow {
    [CmdletBinding()]
    param($Mod, [string]$ArchivePath, [string]$GamePath, [string]$QueueId)
    $statePath = Join-Path (Get-UhmQueueRoot) ($QueueId + '.state.json')
    try {
        Update-UhmDownloadProgress $statePath @{ status = 'preparingInstall'; error = $null }
        $preview = New-UhmInstallationPreview -Mod $Mod -ArchivePath $ArchivePath -GamePath $GamePath -QueueId $QueueId
        if (@($preview.overwrites).Count -gt 0 -or @($preview.executableFiles).Count -gt 0 -or -not $preview.csp.compatible) {
            Update-UhmDownloadProgress $statePath @{ status = 'awaitingConfirmation'; previewId = $preview.id; fileCount = $preview.fileCount; installBytes = $preview.totalBytes; overwrites = @($preview.overwrites); executableFiles = @($preview.executableFiles); csp = $preview.csp }
            return
        }
        $result = Complete-UhmInstallation -PreviewId $preview.id -OverwriteApproved $false
        Update-UhmDownloadProgress $statePath @{ status = 'installed'; installResult = $result }
    } catch {
        Update-UhmDownloadProgress $statePath @{ status = 'installFailed'; error = $_.Exception.Message }
        throw
    }
}
