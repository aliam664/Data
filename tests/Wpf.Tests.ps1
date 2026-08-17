BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $xamlPath = Join-Path $repoRoot 'wpf\MainWindow.xaml'
    $scriptPath = Join-Path $repoRoot 'wpf\UHM-Wpf.ps1'
}

Describe 'Native WPF entry point' {
    It 'launches PowerShell in STA mode from CMD' {
        $cmd = Get-Content -Raw (Join-Path $repoRoot 'UHM-Launcher.cmd')
        $cmd | Should -Match 'powershell\.exe.+-STA.+-Action launch'
    }

    It 'uses WPF as the default launch action and preserves web as an explicit legacy action' {
        $core = Get-Content -Raw (Join-Path $repoRoot 'core\UHM-Core.ps1')
        $core | Should -Match "'launch'\s*\{\s*Start-UhmNativeLauncher"
        $core | Should -Match "'launch-web'\s*\{\s*Start-UhmWebLauncher"
    }

    It 'contains all required native pages and action controls' {
        [xml]$xaml = Get-Content -Raw $xamlPath
        $source = Get-Content -Raw $xamlPath
        foreach ($name in @('PageDashboard','PageCatalog','PageQueue','PageInstalled','PageSettings','CatalogList','QueueList','BtnDetailDownload','BtnDetailInstall','SettingsDefaultPath')) {
            $source | Should -Match ('x:Name="' + [regex]::Escape($name) + '"')
        }
    }

    It 'loads the XAML using the Windows WPF runtime' -Skip:(-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase
        Add-Type -AssemblyName System.Xaml
        [xml]$xaml = Get-Content -Raw $xamlPath
        $reader = New-Object Xml.XmlNodeReader($xaml)
        try {
            $window = [Windows.Markup.XamlReader]::Load($reader)
            $window | Should -Not -BeNullOrEmpty
            $window.FindName('PageCatalog') | Should -Not -BeNullOrEmpty
            $window.Close()
        } finally { $reader.Dispose() }
    }

    It 'connects native clicks to queue, workers, downloader and installer without Invoke-Expression' {
        $source = Get-Content -Raw $scriptPath
        $source | Should -Match 'Add-UhmNativeQueueItem'
        $source | Should -Match 'Start-UhmNativePendingWorkers'
        $source | Should -Match 'Invoke-UhmNativeInstallPreview'
        $source | Should -Not -Match '(?im)^\s*Invoke-Expression\b'
    }
}
