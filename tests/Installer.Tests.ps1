BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:UhmProjectRoot = Join-Path $TestDrive 'uhm-runtime'
    New-Item -ItemType Directory -Path (Join-Path $script:UhmProjectRoot 'data\settings'),(Join-Path $script:UhmProjectRoot 'data\cache'),(Join-Path $script:UhmProjectRoot 'data\logs') -Force | Out-Null
    foreach ($module in @('Logger.ps1','Security.ps1','QueueManager.ps1','CspChecker.ps1','Extractor.ps1','Installer.ps1')) { . (Join-Path $repoRoot ('core\' + $module)) }
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    function New-TestGame([string]$Name) {
        $game = Join-Path $TestDrive $Name
        New-Item -ItemType Directory -Path (Join-Path $game 'content\cars'),(Join-Path $game 'content\tracks') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $game 'AssettoCorsa.exe') -Value 'fixture'
        return $game
    }
    function New-TestZip([string]$Path, [hashtable]$Entries) {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
        $zip = New-Object IO.Compression.ZipArchive($stream, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($name in $Entries.Keys) {
                $entry = $zip.CreateEntry($name)
                $writer = New-Object IO.StreamWriter($entry.Open())
                try { $writer.Write([string]$Entries[$name]) } finally { $writer.Dispose() }
            }
        } finally { $zip.Dispose(); $stream.Dispose() }
    }
    function New-TestMod([string]$Id, [string]$InstallRoot) {
        return [pscustomobject]@{
            id=$Id; name='Test mod'; nameFa='مود تست'; version='1.0.0'; archiveType='zip'; installType='content'; installRoot=$InstallRoot
            passwordRequired=$false; password=''; sha256=''; requiresCsp=$false; minCspVersion=''; cspPreviewRequired=$false; blockInstall=$false
        }
    }
}

Describe 'Safe ZIP extraction' {
    It 'extracts a normal ZIP inside staging' {
        $zipPath = Join-Path $TestDrive 'normal.zip'; $destination = Join-Path $TestDrive 'normal-out'
        New-TestZip $zipPath @{ 'content/cars/demo/data.acd' = 'data' }
        Expand-UhmArchiveSafely -ArchivePath $zipPath -ArchiveType zip -Destination $destination | Out-Null
        Test-Path (Join-Path $destination 'content\cars\demo\data.acd') | Should -BeTrue
    }

    It 'blocks traversal and removes failed staging' {
        $zipPath = Join-Path $TestDrive 'traversal.zip'; $destination = Join-Path $TestDrive 'bad-out'
        New-TestZip $zipPath @{ '../outside.txt' = 'evil' }
        { Expand-UhmArchiveSafely -ArchivePath $zipPath -ArchiveType zip -Destination $destination } | Should -Throw
        Test-Path (Join-Path $TestDrive 'outside.txt') | Should -BeFalse
        Test-Path $destination | Should -BeFalse
    }
}

Describe 'Installation plan mapping' {
    It 'maps cars/car_id without producing cars/cars' {
        $game = New-TestGame 'game-car'; $zipPath = Join-Path $TestDrive 'car.zip'
        New-TestZip $zipPath @{ 'cars/demo_car/data.acd' = 'car' }
        $preview = New-UhmInstallationPreview -Mod (New-TestMod 'test-car' 'content/cars') -ArchivePath $zipPath -GamePath $game
        $preview.plan[0].relative | Should -Be 'content\cars\demo_car\data.acd'
        $preview.plan[0].relative | Should -Not -Match 'cars\\cars'
        $result = Complete-UhmInstallation -PreviewId $preview.id -OverwriteApproved $false
        $result.success | Should -BeTrue
        Test-Path (Join-Path $game 'content\cars\demo_car\data.acd') | Should -BeTrue
    }

    It 'maps content/tracks directly' {
        $game = New-TestGame 'game-track'; $zipPath = Join-Path $TestDrive 'track.zip'
        New-TestZip $zipPath @{ 'wrapper/content/tracks/demo_track/ui/ui_track.json' = '{}' }
        $preview = New-UhmInstallationPreview -Mod (New-TestMod 'test-track' 'content/tracks') -ArchivePath $zipPath -GamePath $game
        $preview.plan[0].relative | Should -Be 'content\tracks\demo_track\ui\ui_track.json'
    }

    It 'requires overwrite approval' {
        $game = New-TestGame 'game-overwrite'; $existing = Join-Path $game 'content\cars\demo\data.acd'
        New-Item -ItemType Directory -Path (Split-Path -Parent $existing) -Force | Out-Null; Set-Content $existing 'old'
        $zipPath = Join-Path $TestDrive 'overwrite.zip'; New-TestZip $zipPath @{ 'demo/data.acd' = 'new' }
        $preview = New-UhmInstallationPreview -Mod (New-TestMod 'test-overwrite' 'content/cars') -ArchivePath $zipPath -GamePath $game
        @($preview.overwrites).Count | Should -Be 1
        { Complete-UhmInstallation -PreviewId $preview.id -OverwriteApproved $false } | Should -Throw
        (Get-Content -Raw $existing).Trim() | Should -Be 'old'
    }

    It 'reports executable scripts but never invokes them' {
        $game = New-TestGame 'game-script'; $zipPath = Join-Path $TestDrive 'script.zip'
        New-TestZip $zipPath @{ 'demo/setup.cmd' = 'exit /b 99' }
        $preview = New-UhmInstallationPreview -Mod (New-TestMod 'test-script' 'content/cars') -ArchivePath $zipPath -GamePath $game
        @($preview.executableFiles).Count | Should -Be 1
        Test-Path (Join-Path $game 'content\cars\demo\setup.cmd') | Should -BeFalse
    }
}

Describe 'Queue persistence and user-confirmed deletion' {
    It 'requires confirmation before removing queue metadata' {
        $mod = New-TestMod 'test-queue' 'content/cars'; $mod | Add-Member image ''; $mod | Add-Member sizeBytes 10; $mod | Add-Member downloadUrl 'https://example.com/test.zip'
        $downloads = Join-Path $TestDrive 'downloads'; New-Item -ItemType Directory $downloads | Out-Null
        $item = New-UhmQueueItem -Mod $mod -TargetId '' -TargetPath '' -InstallAfterDownload $false -DownloadDirectory $downloads
        { Remove-UhmQueueItem -Id $item.id -Confirmed $false -DeletePartial $false } | Should -Throw
        Get-UhmQueueItem $item.id | Should -Not -BeNullOrEmpty
    }
}
