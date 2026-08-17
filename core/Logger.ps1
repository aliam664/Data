Set-StrictMode -Version 2.0

function ConvertTo-UhmSafeLogValue {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Uri]) {
        return ('{0}://{1}{2}' -f $Value.Scheme, $Value.Authority, $Value.AbsolutePath)
    }
    if ($Value -is [string]) {
        $text = $Value -replace '(?i)(password|token|credential)(\s*[=:]\s*)[^\s,;]+', '$1$2[REDACTED]'
        if ($text -match '^https?://') {
            try {
                $uri = [Uri]$text
                return ('{0}://{1}{2}' -f $uri.Scheme, $uri.Authority, $uri.AbsolutePath)
            } catch { return $text }
        }
        return $text
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $safe = [ordered]@{}
        foreach ($key in $Value.Keys) {
            if ([string]$key -match '(?i)password|token|credential|authorization') {
                $safe[$key] = '[REDACTED]'
            } else {
                $safe[$key] = ConvertTo-UhmSafeLogValue $Value[$key]
            }
        }
        return $safe
    }
    if (($Value -is [System.Collections.IEnumerable]) -and -not ($Value -is [string])) {
        $items = @()
        foreach ($item in $Value) { $items += ,(ConvertTo-UhmSafeLogValue $item) }
        return $items
    }
    if ($Value -is [psobject]) {
        $safeObject = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -match '(?i)password|token|credential|authorization') {
                $safeObject[$property.Name] = '[REDACTED]'
            } else {
                $safeObject[$property.Name] = ConvertTo-UhmSafeLogValue $property.Value
            }
        }
        return $safeObject
    }
    return $Value
}

function Write-UhmLog {
    [CmdletBinding()]
    param(
        [ValidateSet('DEBUG', 'INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [Parameter(Mandatory = $true)][string]$Event,
        [hashtable]$Data = @{},
        [string]$LogRoot = (Join-Path $script:UhmProjectRoot 'data\logs')
    )

    try {
        if (-not (Test-Path -LiteralPath $LogRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $LogRoot -Force | Out-Null
        }
        $entry = [ordered]@{
            timestamp = [DateTime]::UtcNow.ToString('o')
            level     = $Level
            event     = $Event
            data      = ConvertTo-UhmSafeLogValue $Data
        }
        $line = $entry | ConvertTo-Json -Depth 12 -Compress
        $path = Join-Path $LogRoot ('uhm-{0}.jsonl' -f [DateTime]::UtcNow.ToString('yyyy-MM-dd'))
        $mutex = New-Object System.Threading.Mutex($false, 'Local\UHM-Launcher-Log')
        try {
            if ($mutex.WaitOne(5000)) {
                [IO.File]::AppendAllText($path, $line + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
            }
        } finally {
            try { $mutex.ReleaseMutex() } catch {}
            $mutex.Dispose()
        }
    } catch {
        # Logging must never interrupt a download or installation.
    }
}
