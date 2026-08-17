Set-StrictMode -Version 2.0

function Update-UhmDownloadProgress {
    param([string]$StatePath, [hashtable]$Changes)
    try {
        $item = [IO.File]::ReadAllText($StatePath) | ConvertFrom-Json
        foreach ($key in $Changes.Keys) {
            if ($item.PSObject.Properties[$key]) { $item.$key = $Changes[$key] }
            else { $item | Add-Member -NotePropertyName $key -NotePropertyValue $Changes[$key] }
        }
        $item.updatedAt = [DateTime]::UtcNow.ToString('o')
        Write-UhmJsonAtomic -Path $StatePath -Value $item
    } catch {}
}

function Invoke-UhmDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Mod,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$StatePath,
        [Parameter(Mandatory = $true)][string]$PauseSignal,
        [Parameter(Mandatory = $true)][string]$CancelSignal
    )
    if (-not (Test-UhmHttpsUrl ([string]$Mod.downloadUrl))) { throw 'لینک دانلود معتبر نیست.' }
    $directory = Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $partial = $Destination + '.part'
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $existingLength = (Get-Item -LiteralPath $Destination).Length
        $hashMatches = $false
        if (-not [string]::IsNullOrWhiteSpace([string]$Mod.sha256)) {
            $hashMatches = (Get-UhmFileSha256 $Destination) -eq ([string]$Mod.sha256).ToLowerInvariant()
        } elseif ([long]$Mod.sizeBytes -gt 0) {
            $hashMatches = $existingLength -eq [long]$Mod.sizeBytes
        }
        if ($hashMatches) {
            Update-UhmDownloadProgress $StatePath @{ status = 'downloaded'; progress = 100; bytesReceived = $existingLength; totalBytes = $existingLength }
            return $Destination
        }
        throw 'فایل مقصد از قبل وجود دارد و اعتبار آن تأیید نشد؛ بدون تأیید جایگزین نمی‌شود.'
    }
    Add-Type -AssemblyName System.Net.Http
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $handler = New-Object Net.Http.HttpClientHandler
    # Redirects are handled manually so every hop can be required to remain HTTPS.
    $handler.AllowAutoRedirect = $false
    $handler.AutomaticDecompression = [Net.DecompressionMethods]::None
    $client = New-Object Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromMilliseconds(-1)
    $offset = if (Test-Path -LiteralPath $partial -PathType Leaf) { (Get-Item -LiteralPath $partial).Length } else { 0L }
    $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, [string]$Mod.downloadUrl)
    $request.Headers.UserAgent.ParseAdd('UHM-Launcher/0.1')
    if ($offset -gt 0) { $request.Headers.Range = New-Object Net.Http.Headers.RangeHeaderValue($offset, $null) }
    $response = $null
    $httpCode = $null
    $inputStream = $null
    $outputStream = $null
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        Update-UhmDownloadProgress $StatePath @{ status = 'connecting'; error = $null }
        for ($redirectCount = 0; $redirectCount -le 5; $redirectCount++) {
            $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
            $statusNumber = [int]$response.StatusCode
            if (@(301,302,303,307,308) -notcontains $statusNumber) { break }
            if ($redirectCount -eq 5 -or $null -eq $response.Headers.Location) { throw 'تعداد یا ساختار Redirectهای دانلود معتبر نیست.' }
            $nextUri = if ($response.Headers.Location.IsAbsoluteUri) { $response.Headers.Location } else { New-Object Uri($request.RequestUri, $response.Headers.Location) }
            if ($nextUri.Scheme -ne 'https') { throw 'تغییر مسیر دانلود به نشانی غیرامن مسدود شد.' }
            $response.Dispose(); $response = $null
            $request.Dispose()
            $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $nextUri)
            $request.Headers.UserAgent.ParseAdd('UHM-Launcher/0.1')
            if ($offset -gt 0) { $request.Headers.Range = New-Object Net.Http.Headers.RangeHeaderValue($offset, $null) }
        }
        if ($null -eq $response) { throw 'پاسخ دانلود دریافت نشد.' }
        $finalUri = $response.RequestMessage.RequestUri
        if ($finalUri.Scheme -ne 'https') { throw 'تغییر مسیر دانلود به نشانی غیرامن مسدود شد.' }
        $httpCode = [int]$response.StatusCode
        Update-UhmDownloadProgress $StatePath @{ httpCode = $httpCode }
        if (-not $response.IsSuccessStatusCode) { throw ('خطای HTTP {0} هنگام دانلود.' -f $httpCode) }
        if ($offset -gt 0 -and $response.StatusCode -ne [Net.HttpStatusCode]::PartialContent) {
            throw 'سرور ادامه دانلود را پشتیبانی نمی‌کند؛ برای شروع دوباره، حذف فایل ناقص را تأیید کنید.'
        }
        if ($offset -gt 0 -and $null -ne $response.Content.Headers.ContentRange -and $response.Content.Headers.ContentRange.From -ne $offset) {
            throw 'محدوده پاسخ Resume با فایل ناقص مطابقت ندارد.'
        }
        $mediaType = if ($null -ne $response.Content.Headers.ContentType) { [string]$response.Content.Headers.ContentType.MediaType } else { '' }
        if ($mediaType -match 'text/html|application/xhtml') {
            throw 'MANUAL_DOWNLOAD_REQUIRED: لینک به صفحه وب، ورود یا CAPTCHA می‌رسد؛ دانلود دستی لازم است.'
        }
        $remaining = $response.Content.Headers.ContentLength
        $total = if ($null -ne $remaining) { [long]$remaining + $offset } elseif ([long]$Mod.sizeBytes -gt 0) { [long]$Mod.sizeBytes } else { 0L }
        if ([long]$Mod.sizeBytes -gt 0 -and $total -gt 0 -and $total -ne [long]$Mod.sizeBytes) { throw 'حجم اعلام‌شده سرور با کاتالوگ مطابقت ندارد.' }
        $partialExists = Test-Path -LiteralPath $partial -PathType Leaf
        $fileMode = if ($offset -gt 0) { [IO.FileMode]::Append } elseif ($partialExists) { [IO.FileMode]::Open } else { [IO.FileMode]::CreateNew }
        $outputStream = New-Object IO.FileStream($partial, $fileMode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $buffer = New-Object byte[] (1024 * 256)
        $received = $offset
        $lastUpdate = [DateTime]::UtcNow
        $lastBytes = $received
        Update-UhmDownloadProgress $StatePath @{ status = 'downloading'; bytesReceived = $received; totalBytes = $total }
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if (Test-Path -LiteralPath $CancelSignal -PathType Leaf) { throw 'DOWNLOAD_CANCELED: دانلود توسط کاربر لغو شد.' }
            while (Test-Path -LiteralPath $PauseSignal -PathType Leaf) {
                Update-UhmDownloadProgress $StatePath @{ status = 'paused'; speedBytes = 0; etaSeconds = $null }
                Start-Sleep -Milliseconds 300
                if (Test-Path -LiteralPath $CancelSignal -PathType Leaf) { throw 'DOWNLOAD_CANCELED: دانلود توسط کاربر لغو شد.' }
            }
            $outputStream.Write($buffer, 0, $read)
            $received += $read
            if ([long]$Mod.sizeBytes -gt 0 -and $received -gt [long]$Mod.sizeBytes) { throw 'حجم دانلود از مقدار ثبت‌شده در کاتالوگ عبور کرد.' }
            $now = [DateTime]::UtcNow
            $seconds = ($now - $lastUpdate).TotalSeconds
            if ($seconds -ge 0.5) {
                $speed = [long](($received - $lastBytes) / $seconds)
                $progress = if ($total -gt 0) { [Math]::Min(100, [Math]::Round(($received * 100.0) / $total, 1)) } else { 0 }
                $eta = if ($speed -gt 0 -and $total -gt $received) { [long](($total - $received) / $speed) } else { $null }
                Update-UhmDownloadProgress $StatePath @{ status = 'downloading'; progress = $progress; bytesReceived = $received; totalBytes = $total; speedBytes = $speed; etaSeconds = $eta }
                $lastUpdate = $now; $lastBytes = $received
            }
        }
        $outputStream.Flush(); $outputStream.Dispose(); $outputStream = $null
        if ($total -gt 0 -and $received -ne $total) { throw 'دانلود ناقص است و می‌توان آن را ادامه داد.' }
        if ([long]$Mod.sizeBytes -gt 0 -and $received -ne [long]$Mod.sizeBytes) { throw 'حجم فایل دریافت‌شده با کاتالوگ مطابقت ندارد.' }
        $hash = Get-UhmFileSha256 $partial
        if (-not [string]::IsNullOrWhiteSpace([string]$Mod.sha256) -and $hash -ne ([string]$Mod.sha256).ToLowerInvariant()) { throw 'هش SHA-256 فایل با کاتالوگ مطابقت ندارد.' }
        Move-Item -LiteralPath $partial -Destination $Destination
        $stopwatch.Stop()
        Update-UhmDownloadProgress $StatePath @{ status = 'downloaded'; progress = 100; bytesReceived = $received; totalBytes = $received; speedBytes = 0; etaSeconds = 0; sha256 = $hash }
        Write-UhmLog -Event 'download.success' -Data @{ mod = $Mod.id; url = [Uri][string]$Mod.downloadUrl; destination = $Destination; hash = $hash; status = 'downloaded'; httpCode = [int]$response.StatusCode; durationMs = $stopwatch.ElapsedMilliseconds }
        return $Destination
    } catch {
        $stopwatch.Stop()
        $message = $_.Exception.Message
        $status = if ($message.StartsWith('DOWNLOAD_CANCELED:')) { 'canceled' } elseif ($message.StartsWith('MANUAL_DOWNLOAD_REQUIRED:')) { 'manualRequired' } else { 'failed' }
        $cleanMessage = $message -replace '^(DOWNLOAD_CANCELED|MANUAL_DOWNLOAD_REQUIRED):\s*', ''
        Update-UhmDownloadProgress $StatePath @{ status = $status; error = $cleanMessage; speedBytes = 0; etaSeconds = $null }
        Write-UhmLog -Level ERROR -Event 'download.failed' -Data @{ mod = $Mod.id; url = [Uri][string]$Mod.downloadUrl; destination = $Destination; status = $status; error = $cleanMessage; httpCode = $httpCode; durationMs = $stopwatch.ElapsedMilliseconds }
        throw
    } finally {
        if ($null -ne $inputStream) { $inputStream.Dispose() }
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        $request.Dispose(); $client.Dispose(); $handler.Dispose()
    }
}
