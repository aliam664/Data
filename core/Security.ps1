Set-StrictMode -Version 2.0

function New-UhmSecureToken {
    [CmdletBinding()]
    param([int]$ByteLength = 32)
    $bytes = New-Object byte[] $ByteLength
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Test-UhmFixedTimeEquals {
    [CmdletBinding()]
    param([AllowNull()][string]$Left, [AllowNull()][string]$Right)
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    $leftBytes = [Text.Encoding]::UTF8.GetBytes($Left)
    $rightBytes = [Text.Encoding]::UTF8.GetBytes($Right)
    $difference = $leftBytes.Length -bxor $rightBytes.Length
    $length = [Math]::Max($leftBytes.Length, $rightBytes.Length)
    for ($index = 0; $index -lt $length; $index++) {
        $a = if ($index -lt $leftBytes.Length) { $leftBytes[$index] } else { 0 }
        $b = if ($index -lt $rightBytes.Length) { $rightBytes[$index] } else { 0 }
        $difference = $difference -bor ($a -bxor $b)
    }
    return ($difference -eq 0)
}

function Test-UhmHttpsUrl {
    [CmdletBinding()]
    param([AllowNull()][string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    try {
        $uri = New-Object Uri($Url, [UriKind]::Absolute)
        if ($uri.Scheme -ne 'https' -or [string]::IsNullOrWhiteSpace($uri.DnsSafeHost)) { return $false }
        if (-not [string]::IsNullOrEmpty($uri.UserInfo)) { return $false }
        return $true
    } catch { return $false }
}

function Test-UhmSafeArchivePath {
    [CmdletBinding()]
    param([AllowNull()][string]$EntryPath)
    if ([string]::IsNullOrWhiteSpace($EntryPath) -or $EntryPath.IndexOf([char]0) -ge 0) { return $false }
    $normalized = $EntryPath.Replace('/', '\')
    if ([IO.Path]::IsPathRooted($normalized) -or $normalized.StartsWith('\') -or $normalized -match '^[A-Za-z]:') { return $false }
    $normalized = $normalized.TrimEnd('\')
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $false }
    $reservedNames = @('CON','PRN','AUX','NUL','COM1','COM2','COM3','COM4','COM5','COM6','COM7','COM8','COM9','LPT1','LPT2','LPT3','LPT4','LPT5','LPT6','LPT7','LPT8','LPT9')
    foreach ($part in $normalized.Split('\')) {
        if ($part -eq '.') { continue }
        if ([string]::IsNullOrEmpty($part) -or $part -eq '..' -or $part.EndsWith('.') -or $part.EndsWith(' ')) { return $false }
        if ($part.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $part.Contains(':')) { return $false }
        if ($reservedNames -contains $part.Split('.')[0].ToUpperInvariant()) { return $false }
    }
    return $true
}

function Get-UhmSafeChildPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )
    if (-not (Test-UhmSafeArchivePath $RelativePath)) { throw 'مسیر آرشیو امن نیست.' }
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $candidate = [IO.Path]::GetFullPath((Join-Path $rootFull $RelativePath))
    if (-not $candidate.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'مسیر آرشیو امن نیست.'
    }
    return $candidate
}

function Test-UhmGamePath {
    [CmdletBinding()]
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        return ((Test-Path -LiteralPath (Join-Path $full 'AssettoCorsa.exe') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $full 'content') -PathType Container) -and
                (Test-Path -LiteralPath (Join-Path $full 'content\cars') -PathType Container) -and
                (Test-Path -LiteralPath (Join-Path $full 'content\tracks') -PathType Container))
    } catch { return $false }
}

function Test-UhmModRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Mod)
    $errors = New-Object System.Collections.Generic.List[string]
    $required = @('id','name','nameFa','category','description','shortDescription','author','version','releaseDate','updatedAt','image','gallery','pageUrl','downloadUrl','archiveType','sizeBytes','sizeText','sha256','passwordRequired','password','requiresCsp','minCspVersion','cspPreviewRequired','compatibility','dependencies','installType','installRoot','installInstructions','featured','verified','enabled')
    $nonEmpty = @('id','name','nameFa','category','author','version','releaseDate','updatedAt','image','pageUrl','downloadUrl','archiveType','sizeText','installType','installRoot')
    foreach ($field in $required) {
        if ($null -eq $Mod.PSObject.Properties[$field]) { $errors.Add(('فیلد الزامی {0} وجود ندارد.' -f $field)) }
    }
    foreach ($field in $nonEmpty) {
        if ($Mod.PSObject.Properties[$field] -and [string]::IsNullOrWhiteSpace([string]$Mod.$field)) { $errors.Add(('فیلد {0} نباید خالی باشد.' -f $field)) }
    }
    $allowedFields = $required + @('blockInstall','activationSteps','popularity')
    foreach ($field in $Mod.PSObject.Properties.Name) { if ($allowedFields -notcontains $field) { $errors.Add(('فیلد ناشناخته در مود: {0}' -f $field)) } }
    if ($Mod.PSObject.Properties['id'] -and ([string]$Mod.id -notmatch '^[a-z0-9][a-z0-9._-]{2,79}$')) { $errors.Add('شناسه مود معتبر نیست.') }
    $allowedCategories = @('cars','tracks','skins','graphics','packs','apps','sounds','weather','ppfilters','miscellaneous')
    if ($Mod.PSObject.Properties['category'] -and $allowedCategories -notcontains [string]$Mod.category) { $errors.Add('دسته‌بندی مود معتبر نیست.') }
    $urlMessages = @{ downloadUrl = 'لینک دانلود معتبر نیست.'; pageUrl = 'لینک صفحه رسمی معتبر نیست.'; image = 'لینک تصویر اصلی معتبر نیست.' }
    foreach ($urlField in @('downloadUrl','pageUrl','image')) {
        if ($Mod.PSObject.Properties[$urlField] -and -not (Test-UhmHttpsUrl ([string]$Mod.$urlField))) { $errors.Add($urlMessages[$urlField]) }
    }
    if ($Mod.PSObject.Properties['gallery']) {
        if ($Mod.gallery -is [string]) { $errors.Add('gallery باید آرایه باشد.') }
        else { foreach ($galleryUrl in @($Mod.gallery)) { if (-not (Test-UhmHttpsUrl ([string]$galleryUrl))) { $errors.Add('یکی از لینک‌های گالری معتبر نیست.') } } }
    }
    foreach ($arrayField in @('dependencies','installInstructions')) { if ($Mod.PSObject.Properties[$arrayField] -and $Mod.$arrayField -is [string]) { $errors.Add(('{0} باید آرایه باشد.' -f $arrayField)) } }
    if ($Mod.PSObject.Properties['installRoot'] -and -not (Test-UhmSafeArchivePath ([string]$Mod.installRoot))) { $errors.Add('مسیر نصب تعریف‌شده امن نیست.') }
    if ($Mod.PSObject.Properties['archiveType'] -and @('zip','rar','7z','tar','tar.gz') -notcontains ([string]$Mod.archiveType).ToLowerInvariant()) { $errors.Add('فرمت آرشیو پشتیبانی نمی‌شود.') }
    foreach ($booleanField in @('passwordRequired','requiresCsp','cspPreviewRequired','featured','verified','enabled')) {
        if ($Mod.PSObject.Properties[$booleanField] -and $Mod.$booleanField -isnot [bool]) { $errors.Add(('فیلد {0} باید boolean باشد.' -f $booleanField)) }
    }
    if ($Mod.PSObject.Properties['sizeBytes']) { try { if ([long]$Mod.sizeBytes -lt 0) { throw 'negative' } } catch { $errors.Add('sizeBytes باید عدد صحیح نامنفی باشد.') } }
    foreach ($dateField in @('releaseDate','updatedAt')) {
        if ($Mod.PSObject.Properties[$dateField]) {
            $parsedDate = [DateTime]::MinValue
            if (-not [DateTime]::TryParseExact([string]$Mod.$dateField, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$parsedDate)) { $errors.Add(('تاریخ {0} معتبر نیست.' -f $dateField)) }
        }
    }
    if ($Mod.PSObject.Properties['compatibility']) {
        $allowedCompatibility = @('compatible','incompatible','required','recommended','unknown')
        foreach ($name in @('pure','sol','contentManager')) {
            if (-not $Mod.compatibility.PSObject.Properties[$name] -or $allowedCompatibility -notcontains [string]$Mod.compatibility.$name) { $errors.Add(('compatibility.{0} معتبر نیست.' -f $name)) }
        }
    }
    if ($Mod.PSObject.Properties['passwordRequired'] -and [bool]$Mod.passwordRequired -and
        ($null -eq $Mod.PSObject.Properties['password'] -or [string]::IsNullOrEmpty([string]$Mod.password))) { $errors.Add('رمز آرشیو در کاتالوگ ثبت نشده است.') }
    if ($Mod.PSObject.Properties['sha256'] -and -not [string]::IsNullOrWhiteSpace([string]$Mod.sha256) -and [string]$Mod.sha256 -notmatch '^[A-Fa-f0-9]{64}$') { $errors.Add('هش SHA-256 معتبر نیست.') }
    return $errors.ToArray()
}

function Test-UhmLocalRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory = $true)][string]$ExpectedHost,
        [Parameter(Mandatory = $true)][string]$ExpectedOrigin,
        [switch]$RequireBrowserOrigin
    )
    $address = $Context.Request.RemoteEndPoint.Address
    if (-not [Net.IPAddress]::IsLoopback($address)) { return $false }
    if (-not [string]::Equals($Context.Request.UserHostName, $ExpectedHost, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($RequireBrowserOrigin) {
        $origin = $Context.Request.Headers['Origin']
        $referer = $Context.Request.UrlReferrer
        $fetchSite = $Context.Request.Headers['Sec-Fetch-Site']
        if (-not [string]::IsNullOrWhiteSpace($origin)) {
            if (-not [string]::Equals($origin.TrimEnd('/'), $ExpectedOrigin.TrimEnd('/'), [StringComparison]::OrdinalIgnoreCase)) { return $false }
        } elseif ($null -ne $referer) {
            if (-not $referer.AbsoluteUri.StartsWith($ExpectedOrigin + '/', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        } elseif ($fetchSite -ne 'same-origin') {
            return $false
        }
    }
    return $true
}

function Get-UhmFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}
