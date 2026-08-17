Set-StrictMode -Version 2.0

function Find-Uhm7Zip {
    [CmdletBinding()]
    param()
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles '7-Zip\7z.exe')) }
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} '7-Zip\7z.exe')) }
    try {
        $command = Get-Command '7z.exe' -ErrorAction Stop
        $candidates.Add($command.Source)
    } catch {}
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    return $null
}

function Assert-UhmExtractedTreeSafe {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Root)
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force)) {
        $full = [IO.Path]::GetFullPath($item.FullName)
        if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { throw 'مسیر آرشیو امن نیست.' }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'پیوند یا Reparse Point داخل آرشیو مجاز نیست.' }
    }
}

function Get-Uhm7ZipEntries {
    param([string]$SevenZip, [string]$ArchivePath, [AllowEmptyString()][string]$Password)
    $arguments = @('l', '-slt', '-bd', '--', $ArchivePath)
    if (-not [string]::IsNullOrEmpty($Password)) { $arguments = @('l', '-slt', '-bd', ('-p' + $Password), '--', $ArchivePath) }
    $output = @(& $SevenZip @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'رمز آرشیو صحیح نیست یا آرشیو آسیب دیده است.' }
    $separatorFound = $false
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($lineValue in $output) {
        $line = [string]$lineValue
        if ($line -match '^-{10,}$') { $separatorFound = $true; continue }
        if ($separatorFound -and $line.StartsWith('Path = ')) { $entries.Add($line.Substring(7)) }
    }
    return $entries.ToArray()
}

function Expand-UhmZipSafely {
    param([string]$ArchivePath, [string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            if (-not (Test-UhmSafeArchivePath $entry.FullName)) { throw 'مسیر آرشیو امن نیست.' }
            $target = Get-UhmSafeChildPath -Root $Destination -RelativePath $entry.FullName
            if ([string]::IsNullOrEmpty($entry.Name)) {
                if (-not (Test-Path -LiteralPath $target -PathType Container)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
                continue
            }
            $parent = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            if (Test-Path -LiteralPath $target) { throw 'آرشیو شامل مسیر تکراری است.' }
            $sourceStream = $entry.Open()
            $targetStream = New-Object IO.FileStream($target, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $sourceStream.CopyTo($targetStream) } finally { $sourceStream.Dispose(); $targetStream.Dispose() }
        }
    } finally { $archive.Dispose() }
}

function Expand-UhmArchiveSafely {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$ArchiveType,
        [Parameter(Mandatory = $true)][string]$Destination,
        [bool]$PasswordRequired = $false,
        [AllowEmptyString()][string]$Password = ''
    )
    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) { throw 'فایل دانلودشده پیدا نشد.' }
    if ($PasswordRequired -and [string]::IsNullOrEmpty($Password)) { throw 'فایل آرشیو رمزدار است اما رمز در کاتالوگ ثبت نشده است.' }
    if (Test-Path -LiteralPath $Destination) { throw 'پوشه موقت از قبل وجود دارد؛ عملیات برای جلوگیری از حذف ناخواسته متوقف شد.' }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $type = $ArchiveType.ToLowerInvariant()
    try {
        if ($type -eq 'zip' -and -not $PasswordRequired) {
            Expand-UhmZipSafely -ArchivePath $ArchivePath -Destination $Destination
        } elseif (@('rar','7z','zip') -contains $type) {
            $sevenZip = Find-Uhm7Zip
            if ([string]::IsNullOrWhiteSpace($sevenZip)) { throw 'برای این فرمت، 7-Zip نصب نیست.' }
            $entries = @(Get-Uhm7ZipEntries -SevenZip $sevenZip -ArchivePath $ArchivePath -Password $Password)
            foreach ($entry in $entries) { if (-not (Test-UhmSafeArchivePath $entry)) { throw 'مسیر آرشیو امن نیست.' } }
            $arguments = @('x', '-y', '-bd', ('-o' + $Destination), '--', $ArchivePath)
            if ($PasswordRequired) { $arguments = @('x', '-y', '-bd', ('-p' + $Password), ('-o' + $Destination), '--', $ArchivePath) }
            $output = @(& $sevenZip @arguments 2>&1)
            if ($LASTEXITCODE -ne 0) { throw 'رمز آرشیو صحیح نیست یا استخراج آرشیو با خطا مواجه شد.' }
        } elseif (@('tar','tar.gz') -contains $type) {
            $tar = Get-Command 'tar.exe' -ErrorAction SilentlyContinue
            if ($null -eq $tar) { throw 'ابزار داخلی TAR در این نسخه Windows پیدا نشد.' }
            $entries = @(& $tar.Source -tf $ArchivePath 2>&1)
            if ($LASTEXITCODE -ne 0) { throw 'فهرست آرشیو TAR قابل خواندن نیست.' }
            foreach ($entry in $entries) { if (-not (Test-UhmSafeArchivePath ([string]$entry))) { throw 'مسیر آرشیو امن نیست.' } }
            $details = @(& $tar.Source -tvf $ArchivePath 2>&1)
            foreach ($line in $details) { if ([string]$line -match '^l| -> | link to ') { throw 'پیوند داخل آرشیو TAR مجاز نیست.' } }
            $output = @(& $tar.Source -xf $ArchivePath -C $Destination 2>&1)
            if ($LASTEXITCODE -ne 0) { throw 'استخراج آرشیو TAR با خطا مواجه شد.' }
        } else {
            throw 'فرمت آرشیو پشتیبانی نمی‌شود.'
        }
        Assert-UhmExtractedTreeSafe -Root $Destination
        Write-UhmLog -Event 'extract.success' -Data @{ archive = $ArchivePath; destination = $Destination; archiveType = $type }
        return $Destination
    } catch {
        Write-UhmLog -Level ERROR -Event 'extract.failed' -Data @{ archive = $ArchivePath; destination = $Destination; archiveType = $type; error = $_.Exception.Message }
        # Staging is application-owned and explicitly disposable after extraction failure.
        if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}
