BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $cmdPath = Join-Path $repoRoot 'catalog\UHM-Catalog-Manager.cmd'
    $scriptPath = Join-Path $repoRoot 'catalog\UHM-Catalog-Manager.ps1'
    $xamlPath = Join-Path $repoRoot 'catalog\CatalogManager.xaml'
}

Describe 'Native catalog manager entry point' {
    It 'provides a CMD entry point using STA without a custom EXE' {
        $cmd = Get-Content -Raw $cmdPath
        $cmd | Should -Match 'powershell\.exe.+-STA.+UHM-Catalog-Manager\.ps1'
        $cmd | Should -Not -Match '(?i)UHM-Catalog-Manager\.exe'
    }

    It 'contains the professional add-mod workflow controls' {
        $xaml = Get-Content -Raw $xamlPath
        foreach ($name in @('ExistingMods','ModId','ModName','ModNameFa','DownloadUrl','BtnPickArchive','Sha256','InstallRoot','RequiresCsp','ImageUrl','BtnValidate','BtnSave','JsonPreview')) {
            $xaml | Should -Match ('x:Name="' + [regex]::Escape($name) + '"')
        }
    }

    It 'loads the manager XAML using WPF on Windows' -Skip:(-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
        Add-Type -AssemblyName PresentationFramework
        Add-Type -AssemblyName PresentationCore
        Add-Type -AssemblyName WindowsBase
        Add-Type -AssemblyName System.Xaml
        [xml]$xaml = Get-Content -Raw $xamlPath
        $reader = New-Object Xml.XmlNodeReader($xaml)
        try {
            $window = [Windows.Markup.XamlReader]::Load($reader)
            $window.FindName('BtnSave') | Should -Not -BeNullOrEmpty
            $window.FindName('EditorTabs') | Should -Not -BeNullOrEmpty
            $window.Close()
        } finally { $reader.Dispose() }
    }
}

Describe 'Catalog manager safety and validation' {
    It 'uses launcher validators and atomic catalog writes' {
        $source = Get-Content -Raw $scriptPath
        $source | Should -Match 'Test-UhmModRecord'
        $source | Should -Match 'Test-UhmCatalog\s+\$candidate'
        $source | Should -Match 'catalog-backups'
        $source | Should -Match 'Move-Item.+CatalogPath.+-Force'
        $source | Should -Not -Match '(?im)^\s*Invoke-Expression\b'
    }

    It 'never copies the selected mod archive into the repository' {
        $source = Get-Content -Raw $scriptPath
        $start = $source.IndexOf('function Select-UhmLocalArchive')
        $end = $source.IndexOf('function Select-UhmLocalImages', $start)
        $archiveFunction = $source.Substring($start, $end - $start)
        $archiveFunction | Should -Match 'Get-UhmFileSha256'
        $archiveFunction | Should -Not -Match 'Copy-Item'
    }

    It 'does not implement deletion of catalog records' {
        $source = Get-Content -Raw $scriptPath
        $source | Should -Not -Match 'Remove-UhmCatalogRecord|Delete-UhmCatalogRecord'
    }
}
