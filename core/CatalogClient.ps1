Set-StrictMode -Version 2.0

function Test-UhmCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Catalog)
    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($field in @('schemaVersion','catalogVersion','generatedAt','mods')) { if ($null -eq $Catalog.PSObject.Properties[$field]) { $errors.Add(('فیلد سطح کاتالوگ وجود ندارد: {0}' -f $field)) } }
    foreach ($field in $Catalog.PSObject.Properties.Name) { if (@('schemaVersion','catalogVersion','generatedAt','noticeFa','mods') -notcontains $field) { $errors.Add(('فیلد ناشناخته سطح کاتالوگ: {0}' -f $field)) } }
    if ($Catalog.PSObject.Properties['schemaVersion'] -and [string]$Catalog.schemaVersion -notmatch '^\d+\.\d+\.\d+$') { $errors.Add('نسخه Schema کاتالوگ معتبر نیست.') }
    if ($null -eq $Catalog.PSObject.Properties['catalogVersion'] -or [string]::IsNullOrWhiteSpace([string]$Catalog.catalogVersion)) { $errors.Add('نسخه کاتالوگ مشخص نشده است.') }
    if ($Catalog.PSObject.Properties['generatedAt']) { try { [void][DateTime]::Parse([string]$Catalog.generatedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) } catch { $errors.Add('زمان تولید کاتالوگ معتبر نیست.') } }
    if ($null -eq $Catalog.PSObject.Properties['mods']) { $errors.Add('فهرست مودها وجود ندارد.'); return $errors.ToArray() }
    if ($Catalog.mods -is [string]) { $errors.Add('mods باید آرایه باشد.'); return $errors.ToArray() }
    $ids = @{}
    foreach ($mod in @($Catalog.mods)) {
        foreach ($errorText in @(Test-UhmModRecord $mod)) { $errors.Add(('{0}: {1}' -f [string]$mod.id, $errorText)) }
        if ($ids.ContainsKey([string]$mod.id)) { $errors.Add(('شناسه تکراری: {0}' -f [string]$mod.id)) }
        else { $ids[[string]$mod.id] = $true }
    }
    return $errors.ToArray()
}

function Read-UhmCatalogFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $catalog = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $errors = @(Test-UhmCatalog $catalog)
    if ($errors.Count -gt 0) { throw ($errors -join [Environment]::NewLine) }
    return $catalog
}

function Get-UhmCatalog {
    [CmdletBinding()]
    param()
    $cachePath = Join-Path $script:UhmProjectRoot 'data\cache\catalog.json'
    $bundledPath = Join-Path $script:UhmProjectRoot 'catalog\catalog.json'
    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        try { return [pscustomobject]@{ catalog = (Read-UhmCatalogFile $cachePath); source = 'cache'; offline = $false } }
        catch { Write-UhmLog -Level WARN -Event 'catalog.cache.invalid' -Data @{ error = $_.Exception.Message } }
    }
    return [pscustomobject]@{ catalog = (Read-UhmCatalogFile $bundledPath); source = 'bundled'; offline = $true }
}

function Sync-UhmCatalogImages {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Catalog)
    $imageRoot = Join-Path $script:UhmProjectRoot 'data\cache\images'
    if (-not (Test-Path -LiteralPath $imageRoot -PathType Container)) { New-Item -ItemType Directory -Path $imageRoot -Force | Out-Null }
    foreach ($mod in @($Catalog.mods | Where-Object { $_.enabled })) {
        $urls = @([string]$mod.image) + @($mod.gallery | ForEach-Object { [string]$_ })
        for ($index = 0; $index -lt $urls.Count; $index++) {
            if (-not (Test-UhmHttpsUrl $urls[$index])) { continue }
            $uri = [Uri]$urls[$index]
            if ($uri.DnsSafeHost -eq 'example.com') { continue }
            $extension = [IO.Path]::GetExtension($uri.AbsolutePath).ToLowerInvariant()
            if (@('.jpg', '.jpeg', '.png', '.webp') -notcontains $extension) { $extension = '.img' }
            $destination = Join-Path $imageRoot (('{0}-{1}{2}' -f [string]$mod.id, $index, $extension))
            try {
                $imageResponse = Invoke-WebRequest -UseBasicParsing -Uri $uri -OutFile $destination -PassThru -MaximumRedirection 5 -TimeoutSec 20 -ErrorAction Stop
                if ($imageResponse.BaseResponse.ResponseUri.Scheme -ne 'https' -or [string]$imageResponse.Headers['Content-Type'] -notmatch '^image/' -or (Get-Item -LiteralPath $destination).Length -gt 20971520) {
                    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force }
                    throw 'پاسخ تصویر HTTPS/تصویری معتبر نیست یا از سقف ۲۰ مگابایت بزرگ‌تر است.'
                }
            } catch {
                if (Test-Path -LiteralPath $destination -PathType Leaf) { Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue }
                Write-UhmLog -Level WARN -Event 'catalog.image.failed' -Data @{ mod = $mod.id; url = $uri; error = $_.Exception.Message }
            }
        }
    }
}

function Update-UhmCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [bool]$CacheEnabled = $true
    )
    if (-not (Test-UhmHttpsUrl $Url)) { throw 'آدرس کاتالوگ باید یک نشانی معتبر HTTPS باشد.' }
    $cacheDirectory = Join-Path $script:UhmProjectRoot 'data\cache'
    if (-not (Test-Path -LiteralPath $cacheDirectory -PathType Container)) { New-Item -ItemType Directory -Path $cacheDirectory -Force | Out-Null }
    $temporary = Join-Path $cacheDirectory ('catalog-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $previousVersion = $null
    try { $previousVersion = [string](Get-UhmCatalog).catalog.catalogVersion } catch {}
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $temporary -PassThru -MaximumRedirection 5 -TimeoutSec 30 -ErrorAction Stop
        if ($response.BaseResponse.ResponseUri.Scheme -ne 'https') { throw 'تغییر مسیر دانلود به نشانی غیرامن مسدود شد.' }
        if ((Get-Item -LiteralPath $temporary).Length -gt 5242880) { throw 'حجم فایل کاتالوگ بیش از سقف ۵ مگابایت است.' }
        $catalog = Read-UhmCatalogFile $temporary
        if ($CacheEnabled) {
            Move-Item -LiteralPath $temporary -Destination (Join-Path $cacheDirectory 'catalog.json') -Force
            Sync-UhmCatalogImages -Catalog $catalog
        } else {
            Remove-Item -LiteralPath $temporary -Force
        }
        $stopwatch.Stop()
        Write-UhmLog -Event 'catalog.refresh.success' -Data @{ url = $Url; version = $catalog.catalogVersion; durationMs = $stopwatch.ElapsedMilliseconds; httpCode = 200 }
        return [pscustomobject]@{ catalog = $catalog; source = 'github'; offline = $false; refreshedAt = [DateTime]::UtcNow.ToString('o'); previousVersion = $previousVersion; versionChanged = ($previousVersion -ne [string]$catalog.catalogVersion) }
    } catch {
        $stopwatch.Stop()
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        Write-UhmLog -Level ERROR -Event 'catalog.refresh.failed' -Data @{ url = $Url; error = $_.Exception.Message; durationMs = $stopwatch.ElapsedMilliseconds }
        $fallback = Get-UhmCatalog
        $fallback.offline = $true
        return $fallback
    }
}
