[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateRange(1024,65535)][int]$Port,
    [Parameter(Mandatory = $true)][string]$Token,
    [Parameter(Mandatory = $true)][string]$ProjectRoot
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:UhmProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)
foreach ($module in @('Logger.ps1','Security.ps1','SteamDetector.ps1','CspChecker.ps1','Settings.ps1','CatalogClient.ps1','QueueManager.ps1','Downloader.ps1','Extractor.ps1','Installer.ps1')) {
    . (Join-Path $PSScriptRoot $module)
}

# The literal localhost prefix is accepted by HTTP.sys for normal users; every request is still checked for a loopback remote address.
$baseUri = 'http://localhost:{0}' -f $Port
$expectedHost = 'localhost:{0}' -f $Port
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add($baseUri + '/')
$workers = @{}
$shutdownRequested = $false
$refreshing = $false
$startedAt = [DateTime]::UtcNow
$lastHeartbeat = [DateTime]::UtcNow
$requestTimes = New-Object System.Collections.Generic.Queue[datetime]
$catalogResult = Get-UhmCatalog
$settings = Get-UhmSettings -DetectSteam
$steamStatus = Get-UhmSteamStatus

function ConvertTo-UhmPublicCatalog {
    param($Catalog)
    $clone = ($Catalog | ConvertTo-Json -Depth 20) | ConvertFrom-Json
    $imageRoot = Join-Path $script:UhmProjectRoot 'data\cache\images'
    foreach ($mod in @($clone.mods)) {
        if ($mod.PSObject.Properties['password']) { $mod.password = '' }
        if (Test-Path -LiteralPath $imageRoot -PathType Container) {
            $mainImage = Get-ChildItem -LiteralPath $imageRoot -File -Filter (([string]$mod.id) + '-0.*') -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $mainImage) { $mod.image = '/media/' + $mainImage.Name }
            $gallery = @()
            for ($index = 0; $index -lt @($mod.gallery).Count; $index++) {
                $cached = Get-ChildItem -LiteralPath $imageRoot -File -Filter (('{0}-{1}.*' -f [string]$mod.id, ($index + 1))) -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($null -ne $cached) { $gallery += ('/media/' + $cached.Name) } else { $gallery += $mod.gallery[$index] }
            }
            $mod.gallery = $gallery
        }
    }
    return $clone
}

function Open-UhmInterface {
    param([Parameter(Mandatory = $true)][string]$Uri)
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')) }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) { $candidates.Add((Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')) }
    try { $edgeCommand = Get-Command 'msedge.exe' -ErrorAction Stop; $candidates.Add($edgeCommand.Source) } catch {}
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            # Edge app mode keeps the HTML UI in a clean application-like window without producing an EXE for UHM.
            Start-Process -FilePath $candidate -ArgumentList @('--app=' + $Uri, '--no-first-run') | Out-Null
            return
        } catch {}
    }
    # Fallback for systems whose default browser is not Edge.
    Start-Process $Uri | Out-Null
}

function Send-UhmBytes {
    param($Context, [byte[]]$Bytes, [string]$ContentType, [int]$StatusCode = 200)
    $response = $Context.Response
    $response.StatusCode = $StatusCode
    $response.ContentType = $ContentType
    $response.ContentLength64 = $Bytes.Length
    $response.Headers['Cache-Control'] = 'no-store'
    $response.Headers['X-Content-Type-Options'] = 'nosniff'
    $response.Headers['X-Frame-Options'] = 'DENY'
    $response.Headers['Referrer-Policy'] = 'no-referrer'
    $response.Headers['Permissions-Policy'] = 'camera=(), microphone=(), geolocation=()'
    $response.Headers['Content-Security-Policy'] = "default-src 'self'; img-src 'self' https: data:; connect-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
    if ($Bytes.Length -gt 0) { $response.OutputStream.Write($Bytes, 0, $Bytes.Length) }
    $response.OutputStream.Close()
}

function Send-UhmJson {
    param($Context, $Value, [int]$StatusCode = 200)
    $json = $Value | ConvertTo-Json -Depth 24 -Compress
    Send-UhmBytes -Context $Context -Bytes ([Text.Encoding]::UTF8.GetBytes($json)) -ContentType 'application/json; charset=utf-8' -StatusCode $StatusCode
}

function Send-UhmError {
    param($Context, [string]$Message, [int]$StatusCode = 400)
    Send-UhmJson -Context $Context -Value @{ success = $false; message = $Message } -StatusCode $StatusCode
}

function Read-UhmJsonBody {
    param($Request)
    if ($Request.ContentLength64 -lt 0) { throw 'درخواست JSON باید Content-Length معتبر داشته باشد.' }
    if ($Request.ContentLength64 -gt 1048576) { throw 'بدنه درخواست بیش از حد بزرگ است.' }
    $reader = New-Object IO.StreamReader($Request.InputStream, $Request.ContentEncoding, $true, 4096, $true)
    try {
        $text = $reader.ReadToEnd()
        if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
        return $text | ConvertFrom-Json
    } finally { $reader.Dispose() }
}

function Test-UhmRateLimit {
    $now = [DateTime]::UtcNow
    while ($requestTimes.Count -gt 0 -and ($now - $requestTimes.Peek()).TotalSeconds -gt 1) { [void]$requestTimes.Dequeue() }
    if ($requestTimes.Count -ge 30) { return $false }
    $requestTimes.Enqueue($now)
    return $true
}

function Test-UhmApiAuthorization {
    param($Context)
    if (-not (Test-UhmLocalRequest -Context $Context -ExpectedHost $expectedHost -ExpectedOrigin $baseUri -RequireBrowserOrigin)) { return $false }
    return Test-UhmFixedTimeEquals -Left $Context.Request.Headers['X-UHM-Token'] -Right $Token
}

function Get-UhmTargetPath {
    param([AllowNull()][string]$TargetId)
    if ([string]::IsNullOrWhiteSpace($TargetId)) { $TargetId = [string]$settings.defaultGamePathId }
    $target = $settings.gamePaths | Where-Object { $_.id -eq $TargetId } | Select-Object -First 1
    if ($null -eq $target -or -not (Test-UhmGamePath ([string]$target.path))) { return $null }
    return $target
}

function Start-UhmPendingWorkers {
    foreach ($id in @($workers.Keys)) {
        $process = $workers[$id]
        if ($process.HasExited) {
            $item = Get-UhmQueueItem $id
            if ($null -ne $item -and $item.status -in @('starting','connecting','downloading','preparingInstall','canceling')) {
                Set-UhmQueueState -Id $id -Changes @{ status = 'failed'; error = 'پردازش Worker بدون تکمیل عملیات متوقف شد؛ فایل ناقص نگه‌داری شده است.' } | Out-Null
            }
            $process.Dispose(); [void]$workers.Remove($id)
        }
    }
    $maximum = [Math]::Max(1, [Math]::Min(4, [int]$settings.maxConcurrentDownloads))
    $available = $maximum - $workers.Count
    if ($available -le 0) { return }
    $pending = @(Get-UhmQueueItems | Where-Object { $_.status -eq 'queued' } | Select-Object -First $available)
    foreach ($item in $pending) {
        $jobPath = Join-Path (Get-UhmQueueRoot) ([string]$item.id + '.job.json')
        if (-not (Test-Path -LiteralPath $jobPath -PathType Leaf)) {
            Set-UhmQueueState -Id ([string]$item.id) -Changes @{ status = 'failed'; error = 'فایل داخلی صف پیدا نشد.' } | Out-Null
            continue
        }
        Set-UhmQueueState -Id ([string]$item.id) -Changes @{ status = 'starting'; error = $null } | Out-Null
        $powerShellPath = Join-Path $PSHOME 'powershell.exe'
        $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + (Join-Path $PSScriptRoot 'UHM-Core.ps1') + '"'),'-Action','download-worker','-JobPath',('"' + $jobPath + '"'))
        $process = Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Hidden -PassThru
        $workers[[string]$item.id] = $process
    }
}

function Stop-UhmWorkers {
    foreach ($id in @($workers.Keys)) {
        $process = $workers[$id]
        try {
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                $item = Get-UhmQueueItem $id
                if ($null -ne $item -and $item.status -in @('starting','connecting','downloading','paused','preparingInstall')) {
                    Set-UhmQueueState -Id $id -Changes @{ status = 'failed'; error = 'Bridge بسته شد؛ دانلود ناقص نگه‌داری شد و قابل ادامه است.' } | Out-Null
                }
            }
        } catch {}
        $process.Dispose()
    }
    $workers.Clear()
}

function Get-UhmBootstrap {
    $installed = @(Get-UhmInstalledMods)
    $active = @(Get-UhmQueueItems | Where-Object { $_.status -in @('starting','connecting','downloading','paused') }).Count
    return [ordered]@{
        success = $true
        appVersion = '0.1.0'
        catalog = ConvertTo-UhmPublicCatalog $catalogResult.catalog
        catalogSource = $catalogResult.source
        offline = [bool]$catalogResult.offline
        settings = $settings
        steam = $steamStatus
        queue = @(Get-UhmQueueItems)
        installed = $installed
        stats = @{ totalMods = @($catalogResult.catalog.mods | Where-Object { $_.enabled }).Count; installedMods = $installed.Count; activeDownloads = $active; lastRefresh = $settings.lastCatalogRefresh }
    }
}

function Send-UhmStaticFile {
    param($Context, [string]$Path)
    if ($Path -match '^/media/([a-z0-9][a-z0-9._-]{2,95}\.(jpg|jpeg|png|webp|img))$') {
        $imageRoot = [IO.Path]::GetFullPath((Join-Path $script:UhmProjectRoot 'data\cache\images')).TrimEnd('\') + '\'
        $imagePath = [IO.Path]::GetFullPath((Join-Path $imageRoot $Matches[1]))
        if (-not $imagePath.StartsWith($imageRoot, [StringComparison]::OrdinalIgnoreCase) -or -not (Test-Path -LiteralPath $imagePath -PathType Leaf)) { Send-UhmError $Context 'تصویر Cache پیدا نشد.' 404; return }
        $mime = switch ([IO.Path]::GetExtension($imagePath).ToLowerInvariant()) {
            '.png'  { 'image/png' }
            '.webp' { 'image/webp' }
            '.jpg'  { 'image/jpeg' }
            '.jpeg' { 'image/jpeg' }
            default { 'application/octet-stream' }
        }
        Send-UhmBytes -Context $Context -Bytes ([IO.File]::ReadAllBytes($imagePath)) -ContentType $mime
        return
    }
    $map = @{
        '/' = @('ui\index.html','text/html; charset=utf-8')
        '/index.html' = @('ui\index.html','text/html; charset=utf-8')
        '/app.js' = @('ui\app.js','application/javascript; charset=utf-8')
        '/style.css' = @('ui\style.css','text/css; charset=utf-8')
        '/icons/favicon.svg' = @('ui\icons\favicon.svg','image/svg+xml')
    }
    if (-not $map.ContainsKey($Path)) { Send-UhmError $Context 'فایل پیدا نشد.' 404; return }
    $filePath = Join-Path $script:UhmProjectRoot $map[$Path][0]
    if (-not (Test-Path -LiteralPath $filePath -PathType Leaf)) { Send-UhmError $Context 'فایل رابط پیدا نشد.' 404; return }
    Send-UhmBytes -Context $Context -Bytes ([IO.File]::ReadAllBytes($filePath)) -ContentType $map[$Path][1]
}

function Invoke-UhmApiRequest {
    param($Context, [string]$Path, [string]$Method)
    if (-not (Test-UhmRateLimit)) { Send-UhmError $Context 'تعداد درخواست‌ها بیش از حد مجاز است.' 429; return }
    if (-not (Test-UhmApiAuthorization $Context)) { Send-UhmError $Context 'درخواست محلی مجاز نیست.' 403; return }
    $script:lastHeartbeat = [DateTime]::UtcNow
    $body = $null
    if ($Method -in @('POST','PUT','PATCH','DELETE')) { $body = Read-UhmJsonBody $Context.Request }

    if ($Method -eq 'GET' -and $Path -eq '/api/bootstrap') { Send-UhmJson $Context (Get-UhmBootstrap); return }
    if ($Method -eq 'POST' -and $Path -eq '/api/heartbeat') { Send-UhmJson $Context @{ success = $true }; return }
    if ($Method -eq 'GET' -and $Path -eq '/api/queue') { Send-UhmJson $Context @{ success = $true; queue = @(Get-UhmQueueItems) }; return }
    if ($Method -eq 'GET' -and $Path -eq '/api/installed') { Send-UhmJson $Context @{ success = $true; installed = @(Get-UhmInstalledMods) }; return }

    if ($Method -eq 'POST' -and $Path -eq '/api/catalog/refresh') {
        if ($script:refreshing) { Send-UhmError $Context 'به‌روزرسانی کاتالوگ هم‌اکنون در حال اجرا است.' 409; return }
        $script:refreshing = $true
        try {
            $script:catalogResult = Update-UhmCatalog -Url ([string]$settings.catalogUrl) -CacheEnabled ([bool]$settings.cacheEnabled)
            if (-not $catalogResult.offline) {
                $script:settings.lastCatalogRefresh = [DateTime]::UtcNow.ToString('o')
                $script:settings.catalogVersion = [string]$catalogResult.catalog.catalogVersion
                Save-UhmSettings $settings
            }
            $versionChanged = $false
            if ($catalogResult.PSObject.Properties['versionChanged']) { $versionChanged = [bool]$catalogResult.versionChanged }
            $refreshMessage = if ($catalogResult.offline) { 'ارتباط برقرار نشد؛ آخرین Cache نمایش داده می‌شود.' } elseif ($versionChanged) { 'نسخه جدید کاتالوگ با موفقیت دریافت شد.' } else { 'کاتالوگ بررسی شد؛ نسخه جدیدی منتشر نشده است.' }
            Send-UhmJson $Context @{ success = (-not $catalogResult.offline); message = $refreshMessage; catalog = ConvertTo-UhmPublicCatalog $catalogResult.catalog; source = $catalogResult.source; offline = $catalogResult.offline; refreshedAt = $settings.lastCatalogRefresh; versionChanged = $versionChanged }
        } finally { $script:refreshing = $false }
        return
    }

    if ($Method -eq 'POST' -and $Path -eq '/api/queue') {
        $mod = $catalogResult.catalog.mods | Where-Object { $_.id -eq [string]$body.modId -and $_.enabled } | Select-Object -First 1
        if ($null -eq $mod) { Send-UhmError $Context 'مود فعال در کاتالوگ پیدا نشد.' 404; return }
        $duplicate = Get-UhmQueueItems | Where-Object { $_.modId -eq [string]$mod.id -and $_.status -notin @('installed') } | Select-Object -First 1
        if ($null -ne $duplicate) { Send-UhmError $Context 'این مود از قبل در صف وجود دارد؛ همان آیتم را ادامه، Retry یا حذف کنید.' 409; return }
        $target = Get-UhmTargetPath ([string]$body.targetId)
        $targetId = if ($null -ne $target) { [string]$target.id } else { $null }
        $targetPath = if ($null -ne $target) { [string]$target.path } else { $null }
        if ([bool]$body.installAfterDownload -and $null -eq $target) { Send-UhmError $Context 'برای نصب خودکار، مسیر معتبر Assetto Corsa انتخاب کنید.' 400; return }
        $item = New-UhmQueueItem -Mod $mod -TargetId $targetId -TargetPath $targetPath -InstallAfterDownload ([bool]$body.installAfterDownload) -DownloadDirectory ([string]$settings.downloadDirectory)
        Send-UhmJson $Context @{ success = $true; message = 'مود به صف اضافه شد.'; item = $item } 201
        return
    }

    if ($Path -match '^/api/queue/([a-f0-9]{32})/(pause|resume|cancel|retry|remove)$' -and $Method -eq 'POST') {
        $id = $Matches[1]; $action = $Matches[2]
        $item = Get-UhmQueueItem $id
        if ($null -eq $item) { Send-UhmError $Context 'آیتم صف پیدا نشد.' 404; return }
        switch ($action) {
            'pause' { Set-UhmQueueSignal -Id $id -Signal pause -Enabled $true; Set-UhmQueueState -Id $id -Changes @{ status = 'paused' } | Out-Null }
            'resume' {
                Set-UhmQueueSignal -Id $id -Signal pause -Enabled $false
                if (-not $workers.ContainsKey($id)) { Reset-UhmQueueItem $id | Out-Null }
                else { Set-UhmQueueState -Id $id -Changes @{ status = 'downloading' } | Out-Null }
            }
            'cancel' {
                Set-UhmQueueSignal -Id $id -Signal cancel -Enabled $true
                $cancelStatus = if ($workers.ContainsKey($id) -and -not $workers[$id].HasExited) { 'canceling' } else { 'canceled' }
                Set-UhmQueueState -Id $id -Changes @{ status = $cancelStatus } | Out-Null
            }
            'retry' {
                if ($item.status -notin @('failed','canceled','manualRequired','installFailed')) { Send-UhmError $Context 'این آیتم در وضعیت قابل تلاش مجدد نیست.' 409; return }
                Reset-UhmQueueItem $id | Out-Null
            }
            'remove' {
                if ($workers.ContainsKey($id) -and -not $workers[$id].HasExited) { Send-UhmError $Context 'ابتدا دانلود را لغو و تا توقف آن صبر کنید.' 409; return }
                Remove-UhmQueueItem -Id $id -Confirmed ([bool]$body.confirmed) -DeletePartial ([bool]$body.deletePartial)
            }
        }
        Send-UhmJson $Context @{ success = $true; queue = @(Get-UhmQueueItems) }
        return
    }

    if ($Path -match '^/api/queue/([a-f0-9]{32})/install-preview$' -and $Method -eq 'POST') {
        $id = $Matches[1]
        $state = Get-UhmQueueItem $id
        $jobPath = Join-Path (Get-UhmQueueRoot) ($id + '.job.json')
        if ($null -eq $state -or -not (Test-Path -LiteralPath $jobPath -PathType Leaf)) { Send-UhmError $Context 'آیتم صف پیدا نشد.' 404; return }
        if (-not (Test-Path -LiteralPath ([string]$state.downloadPath) -PathType Leaf)) { Send-UhmError $Context 'دانلود این مود کامل نشده است.' 409; return }
        $job = [IO.File]::ReadAllText($jobPath) | ConvertFrom-Json
        $target = Get-UhmTargetPath ([string]$body.targetId)
        if ($null -eq $target) { Send-UhmError $Context 'مسیر Assetto Corsa معتبر نیست.' 400; return }
        $preview = New-UhmInstallationPreview -Mod $job.mod -ArchivePath ([string]$state.downloadPath) -GamePath ([string]$target.path) -ConfirmReinstall ([bool]$body.confirmReinstall) -QueueId $id
        Set-UhmQueueState -Id $id -Changes @{ status = 'awaitingConfirmation'; previewId = $preview.id; fileCount = $preview.fileCount; installBytes = $preview.totalBytes; overwrites = @($preview.overwrites); executableFiles = @($preview.executableFiles); csp = $preview.csp } | Out-Null
        $publicPreview = [ordered]@{ id = $preview.id; modId = $preview.modId; fileCount = $preview.fileCount; totalBytes = $preview.totalBytes; overwrites = @($preview.overwrites); executableFiles = @($preview.executableFiles); csp = $preview.csp }
        Send-UhmJson $Context @{ success = $true; preview = $publicPreview }
        return
    }

    if ($Path -match '^/api/queue/([a-f0-9]{32})/install-confirm$' -and $Method -eq 'POST') {
        $id = $Matches[1]
        $state = Get-UhmQueueItem $id
        if ($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.previewId)) { Send-UhmError $Context 'پیش‌نمایش نصب پیدا نشد.' 404; return }
        if (-not [bool]$body.confirmed) { Send-UhmError $Context 'نصب توسط کاربر تأیید نشده است.' 400; return }
        $result = Complete-UhmInstallation -PreviewId ([string]$state.previewId) -OverwriteApproved ([bool]$body.approveOverwrite)
        Set-UhmQueueState -Id $id -Changes @{ status = 'installed'; installResult = $result; error = $null } | Out-Null
        Send-UhmJson $Context @{ success = $true; result = $result }
        return
    }

    if ($Method -eq 'POST' -and $Path -eq '/api/settings') {
        if ($body.PSObject.Properties['maxConcurrentDownloads']) {
            $value = [int]$body.maxConcurrentDownloads
            if ($value -lt 1 -or $value -gt 4) { Send-UhmError $Context 'تعداد دانلود هم‌زمان باید بین ۱ تا ۴ باشد.' 400; return }
            $script:settings.maxConcurrentDownloads = $value
        }
        if ($body.PSObject.Properties['cacheEnabled']) { $script:settings.cacheEnabled = [bool]$body.cacheEnabled }
        if ($body.PSObject.Properties['defaultGamePathId']) {
            $target = Get-UhmTargetPath ([string]$body.defaultGamePathId)
            if ($null -eq $target) { Send-UhmError $Context 'مسیر پیش‌فرض معتبر نیست.' 400; return }
            $script:settings.defaultGamePathId = [string]$target.id
        }
        if ($body.PSObject.Properties['downloadDirectory']) {
            $directory = [IO.Path]::GetFullPath([string]$body.downloadDirectory)
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
            $script:settings.downloadDirectory = $directory
        }
        Save-UhmSettings $settings
        Send-UhmJson $Context @{ success = $true; settings = $settings; message = 'تنظیمات ذخیره شد.' }
        return
    }

    if ($Method -eq 'POST' -and $Path -eq '/api/settings/paths') {
        $script:settings = Add-UhmGamePath -Settings $settings -Path ([string]$body.path) -Name ([string]$body.name)
        Send-UhmJson $Context @{ success = $true; settings = $settings; message = 'مسیر معتبر اضافه شد.' }
        return
    }
    if ($Path -match '^/api/settings/paths/([a-zA-Z0-9-]+)$' -and $Method -eq 'DELETE') {
        if (-not [bool]$body.confirmed) { Send-UhmError $Context 'حذف مسیر از فهرست باید تأیید شود.' 400; return }
        $script:settings = Remove-UhmGamePath -Settings $settings -Id $Matches[1]
        Send-UhmJson $Context @{ success = $true; settings = $settings; message = 'مسیر فقط از فهرست حذف شد؛ فایل‌های بازی تغییر نکردند.' }
        return
    }
    if ($Method -eq 'POST' -and $Path -eq '/api/settings/select-folder') {
        $helper = Join-Path $PSScriptRoot 'SelectFolder.ps1'
        $outputFile = Join-Path $env:TEMP ('uhm-folder-' + [Guid]::NewGuid().ToString('N') + '.txt')
        try {
            $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList @('-NoProfile','-STA','-File',('"' + $helper + '"')) -Wait -PassThru -RedirectStandardOutput $outputFile
            $selected = if (Test-Path -LiteralPath $outputFile) { [IO.File]::ReadAllText($outputFile).Trim() } else { '' }
            Send-UhmJson $Context @{ success = $true; path = $selected }
        } finally { if (Test-Path -LiteralPath $outputFile) { Remove-Item -LiteralPath $outputFile -Force } }
        return
    }
    if ($Method -eq 'POST' -and $Path -eq '/api/settings/cache/clear') {
        if (-not [bool]$body.confirmed) { Send-UhmError $Context 'پاک‌کردن Cache باید تأیید شود.' 400; return }
        foreach ($candidate in @((Join-Path $script:UhmProjectRoot 'data\cache\catalog.json'), (Join-Path $script:UhmProjectRoot 'data\cache\images'))) {
            if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Recurse -Force }
        }
        Send-UhmJson $Context @{ success = $true; message = 'Cache با تأیید کاربر پاک شد.' }
        return
    }
    if ($Method -eq 'POST' -and $Path -eq '/api/diagnostics') {
        $kind = [string]$body.kind
        switch ($kind) {
            'steam' { $script:steamStatus = Get-UhmSteamStatus; Send-UhmJson $Context @{ success = $true; result = $steamStatus } }
            '7zip' { $path7z = Find-Uhm7Zip; Send-UhmJson $Context @{ success = (-not [string]::IsNullOrWhiteSpace($path7z)); result = @{ path = $path7z }; message = if ($path7z) { '7-Zip پیدا شد.' } else { 'برای این فرمت، 7-Zip نصب نیست.' } } }
            'connection' {
                $ok = $false
                try { $uri = [Uri][string]$settings.catalogUrl; $request = [Net.WebRequest]::Create(('https://' + $uri.Host + '/')); $request.Method = 'HEAD'; $request.Timeout = 8000; $response = $request.GetResponse(); $response.Close(); $ok = $true } catch {}
                Send-UhmJson $Context @{ success = $ok; message = if ($ok) { 'اتصال HTTPS برقرار است.' } else { 'اتصال به GitHub برقرار نشد.' } }
            }
            default { Send-UhmError $Context 'نوع تست معتبر نیست.' 400 }
        }
        return
    }
    if ($Method -eq 'POST' -and $Path -eq '/api/shutdown') {
        $script:shutdownRequested = $true
        Send-UhmJson $Context @{ success = $true; message = 'UHM Launcher بسته می‌شود.' }
        return
    }
    Send-UhmError $Context 'مسیر API پیدا نشد.' 404
}

# Downloads interrupted by a prior forced close remain resumable but are never reported as active.
foreach ($item in @(Get-UhmQueueItems | Where-Object { $_.status -in @('starting','connecting','downloading','preparingInstall','canceling') })) {
    Set-UhmQueueState -Id ([string]$item.id) -Changes @{ status = 'failed'; error = 'اجرای قبلی متوقف شد؛ فایل ناقص برای Resume نگه‌داری شده است.' } | Out-Null
}

try {
    $listener.Start()
    Open-UhmInterface -Uri ($baseUri + '/#token=' + [Uri]::EscapeDataString($Token))
    $async = $listener.BeginGetContext($null, $null)
    while (-not $shutdownRequested) {
        if ($async.AsyncWaitHandle.WaitOne(250)) {
            $context = $null
            try {
                $context = $listener.EndGetContext($async)
                $async = $listener.BeginGetContext($null, $null)
                $path = $context.Request.Url.AbsolutePath
                $method = $context.Request.HttpMethod.ToUpperInvariant()
                if ($path.StartsWith('/api/', [StringComparison]::OrdinalIgnoreCase)) {
                    try { Invoke-UhmApiRequest -Context $context -Path $path -Method $method; $lastHeartbeat = [DateTime]::UtcNow }
                    catch {
                        Write-UhmLog -Level ERROR -Event 'bridge.request.failed' -Data @{ path = $path; method = $method; error = $_.Exception.Message }
                        if ($null -ne $context -and $context.Response.OutputStream.CanWrite) { Send-UhmError $context $_.Exception.Message 500 }
                    }
                } elseif ($method -eq 'GET' -and (Test-UhmLocalRequest -Context $context -ExpectedHost $expectedHost -ExpectedOrigin $baseUri)) {
                    Send-UhmStaticFile -Context $context -Path $path
                } else { Send-UhmError $context 'درخواست مجاز نیست.' 403 }
            } catch {
                if ($null -ne $context) { try { $context.Response.Abort() } catch {} }
            }
        }
        Start-UhmPendingWorkers
        if (([DateTime]::UtcNow - $startedAt).TotalSeconds -gt 120 -and ([DateTime]::UtcNow - $lastHeartbeat).TotalSeconds -gt 90) {
            Write-UhmLog -Event 'bridge.heartbeat_timeout' -Data @{}
            $shutdownRequested = $true
        }
    }
} finally {
    Stop-UhmWorkers
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
    Write-UhmLog -Event 'launcher.stop' -Data @{}
}
