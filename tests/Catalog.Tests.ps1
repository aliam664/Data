BeforeAll {
    $script:UhmProjectRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:UhmProjectRoot 'core\Logger.ps1')
    . (Join-Path $script:UhmProjectRoot 'core\Security.ps1')
    . (Join-Path $script:UhmProjectRoot 'core\CatalogClient.ps1')
}

Describe 'Bundled catalog' {
    BeforeAll {
        $catalogPath = Join-Path $script:UhmProjectRoot 'catalog\catalog.json'
        $catalog = Read-UhmCatalogFile $catalogPath
    }

    It 'parses and has no module validation errors' {
        @(Test-UhmCatalog $catalog).Count | Should -Be 0
    }

    It 'contains unique IDs' {
        @($catalog.mods.id | Sort-Object -Unique).Count | Should -Be @($catalog.mods).Count
    }

    It 'uses only HTTPS links' {
        foreach ($mod in $catalog.mods) {
            Test-UhmHttpsUrl $mod.pageUrl | Should -BeTrue -Because $mod.id
            Test-UhmHttpsUrl $mod.downloadUrl | Should -BeTrue -Because $mod.id
        }
    }

    It 'contains only one download URL field per mod and no mirrors' {
        foreach ($mod in $catalog.mods) {
            $mod.PSObject.Properties.Name | Should -Contain 'downloadUrl'
            $mod.PSObject.Properties.Name | Should -Not -Contain 'mirrors'
            $mod.PSObject.Properties.Name | Should -Not -Contain 'mirrorUrls'
        }
    }

    It 'marks every sample URL as example.com' {
        foreach ($mod in $catalog.mods) { ([Uri]$mod.downloadUrl).DnsSafeHost | Should -Be 'example.com' }
    }

    It 'has a password whenever passwordRequired is true' {
        foreach ($mod in @($catalog.mods | Where-Object passwordRequired)) { [string]$mod.password | Should -Not -BeNullOrEmpty }
    }

    It 'has no archives committed to the catalog or image tree' {
        $archives = @(Get-ChildItem (Join-Path $script:UhmProjectRoot 'catalog'),(Join-Path $script:UhmProjectRoot 'images') -Recurse -File | Where-Object Extension -In @('.zip','.rar','.7z','.tar','.gz'))
        $archives.Count | Should -Be 0
    }
}

Describe 'Invalid catalog records' {
    It 'rejects HTTP download URLs' {
        $bad = [pscustomobject]@{ id='bad-mod'; name='Bad'; nameFa='بد'; category='cars'; version='1.0'; downloadUrl='http://example.com/a.zip'; archiveType='zip'; installType='content'; installRoot='content/cars'; passwordRequired=$false; sha256='' }
        @(Test-UhmModRecord $bad) -join ' ' | Should -Match 'لینک دانلود'
    }

    It 'rejects a missing public password' {
        $bad = [pscustomobject]@{ id='bad-pass'; name='Bad'; nameFa='بد'; category='cars'; version='1.0'; downloadUrl='https://example.com/a.7z'; archiveType='7z'; installType='content'; installRoot='content/cars'; passwordRequired=$true; password=''; sha256='' }
        @(Test-UhmModRecord $bad) -join ' ' | Should -Match 'رمز آرشیو'
    }
}
