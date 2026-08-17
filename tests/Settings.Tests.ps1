BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
    $script:UhmProjectRoot = Join-Path $TestDrive 'settings-runtime'
    New-Item -ItemType Directory -Path (Join-Path $script:UhmProjectRoot 'data\settings'),(Join-Path $script:UhmProjectRoot 'data\downloads'),(Join-Path $script:UhmProjectRoot 'data\logs') -Force | Out-Null
    . (Join-Path $repoRoot 'core\Logger.ps1')
    . (Join-Path $repoRoot 'core\Security.ps1')
    function Find-UhmAssettoCorsaInstallations { return @() }
    . (Join-Path $repoRoot 'core\Settings.ps1')
}

Describe 'Settings compatibility with Windows PowerShell 5.1' {
    It 'materializes an empty generic path list without ArgumentException' {
        { $script:result = Get-UhmSettings -DetectSteam } | Should -Not -Throw
        $script:result | Should -Not -BeNullOrEmpty
        @($script:result.gamePaths).Count | Should -Be 0
        $script:result.appVersion | Should -Be '0.2.0'
    }

    It 'materializes detected paths as a normal object array' {
        function Find-UhmAssettoCorsaInstallations { return [pscustomobject]@{ id='steam-1'; name='Assetto Corsa 1'; path='D:\SteamLibrary\steamapps\common\assettocorsa'; source='steam'; isValid=$true } }
        $settings = Get-UhmSettings -DetectSteam
        @($settings.gamePaths).Count | Should -Be 1
        $settings.gamePaths[0].id | Should -Be 'steam-1'
    }
}
