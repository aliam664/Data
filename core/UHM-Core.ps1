[CmdletBinding()]
param(
    [ValidateSet('launch','launch-web','download-worker')][string]$Action = 'launch',
    [string]$JobPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:UhmProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

foreach ($module in @('Logger.ps1','Security.ps1','SteamDetector.ps1','CspChecker.ps1','Settings.ps1','CatalogClient.ps1','QueueManager.ps1','Downloader.ps1','Extractor.ps1','Installer.ps1')) {
    . (Join-Path $PSScriptRoot $module)
}

function Assert-UhmPlatform {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or [Environment]::OSVersion.Version.Major -lt 10) {
        throw 'UHM Launcher فقط از Windows 10 و Windows 11 پشتیبانی می‌کند.'
    }
}

function Start-UhmNativeLauncher {
    Assert-UhmPlatform
    Write-UhmLog -Event 'launcher.native.start' -Data @{ version = '0.2.0'; ui = 'WPF' }
    & (Join-Path $script:UhmProjectRoot 'wpf\UHM-Wpf.ps1') -ProjectRoot $script:UhmProjectRoot
}

function Start-UhmWebLauncher {
    Assert-UhmPlatform
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $listener.Stop()
    $token = New-UhmSecureToken
    Write-UhmLog -Event 'launcher.start' -Data @{ version = '0.1.0'; port = $port }
    & (Join-Path $PSScriptRoot 'UHM-Bridge.ps1') -Port $port -Token $token -ProjectRoot $script:UhmProjectRoot
}

function Start-UhmDownloadWorker {
    if ([string]::IsNullOrWhiteSpace($JobPath)) { throw 'مسیر Job مشخص نشده است.' }
    $queueRoot = [IO.Path]::GetFullPath((Get-UhmQueueRoot)).TrimEnd('\') + '\'
    $jobFull = [IO.Path]::GetFullPath($JobPath)
    if (-not $jobFull.StartsWith($queueRoot, [StringComparison]::OrdinalIgnoreCase) -or -not $jobFull.EndsWith('.job.json', [StringComparison]::OrdinalIgnoreCase)) { throw 'مسیر Job معتبر نیست.' }
    $job = [IO.File]::ReadAllText($jobFull) | ConvertFrom-Json
    if ([string]$job.id -notmatch '^[a-f0-9]{32}$') { throw 'شناسه Job معتبر نیست.' }
    $root = Get-UhmQueueRoot
    $statePath = Join-Path $root ([string]$job.id + '.state.json')
    $pausePath = Join-Path $root ([string]$job.id + '.pause')
    $cancelPath = Join-Path $root ([string]$job.id + '.cancel')
    try {
        $archive = Invoke-UhmDownload -Mod $job.mod -Destination ([string]$job.downloadPath) -StatePath $statePath -PauseSignal $pausePath -CancelSignal $cancelPath
        if ([bool]$job.installAfterDownload) {
            if ([string]::IsNullOrWhiteSpace([string]$job.targetPath) -or -not (Test-UhmGamePath ([string]$job.targetPath))) {
                Update-UhmDownloadProgress $statePath @{ status = 'downloaded'; error = 'برای نصب خودکار، یک مسیر معتبر Assetto Corsa انتخاب کنید.' }
            } else {
                Invoke-UhmInstallWorkflow -Mod $job.mod -ArchivePath $archive -GamePath ([string]$job.targetPath) -QueueId ([string]$job.id)
            }
        }
    } catch {
        # Downloader and installer already write a sanitized state and log entry.
        exit 1
    }
}

switch ($Action) {
    'launch' { Start-UhmNativeLauncher }
    'launch-web' { Start-UhmWebLauncher }
    'download-worker' { Start-UhmDownloadWorker }
}
