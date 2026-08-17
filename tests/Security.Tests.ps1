BeforeAll {
    $script:UhmProjectRoot = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:UhmProjectRoot 'core\Logger.ps1')
    . (Join-Path $script:UhmProjectRoot 'core\Security.ps1')
}

Describe 'UHM URL security' {
    It 'accepts only absolute HTTPS without user info' {
        Test-UhmHttpsUrl 'https://example.com/file.zip' | Should -BeTrue
        Test-UhmHttpsUrl 'http://example.com/file.zip' | Should -BeFalse
        Test-UhmHttpsUrl 'https://user:pass@example.com/file.zip' | Should -BeFalse
        Test-UhmHttpsUrl 'file:///C:/mod.zip' | Should -BeFalse
        Test-UhmHttpsUrl 'not a url' | Should -BeFalse
    }

    It 'compares bridge tokens' {
        Test-UhmFixedTimeEquals 'same-token' 'same-token' | Should -BeTrue
        Test-UhmFixedTimeEquals 'same-token' 'other-token' | Should -BeFalse
        Test-UhmFixedTimeEquals '' $null | Should -BeFalse
    }
}

Describe 'UHM path traversal controls' {
    It 'rejects traversal, rooted, UNC and drive paths' {
        foreach ($path in @('../evil', '..\evil', 'folder/../../evil', 'C:\evil', '\\server\share', '/rooted', 'file.txt:stream', 'CON.txt', 'folder\name. ', "bad$([char]0)name")) {
            Test-UhmSafeArchivePath $path | Should -BeFalse -Because $path
        }
    }

    It 'accepts a normal content path' {
        Test-UhmSafeArchivePath 'content/cars/demo/data.acd' | Should -BeTrue
    }

    It 'resolves only children of a root' {
        $root = Join-Path $TestDrive 'root'
        New-Item -ItemType Directory -Path $root | Out-Null
        (Get-UhmSafeChildPath -Root $root -RelativePath 'content\cars\demo') | Should -Be (Join-Path $root 'content\cars\demo')
        { Get-UhmSafeChildPath -Root $root -RelativePath '..\outside' } | Should -Throw
    }
}

Describe 'Sensitive logging values' {
    It 'redacts sensitive dictionary keys and query strings' {
        $safe = ConvertTo-UhmSafeLogValue @{ password = 'secret'; token = 'abc'; url = 'https://example.com/file.zip?signature=secret' }
        $safe.password | Should -Be '[REDACTED]'
        $safe.token | Should -Be '[REDACTED]'
        $safe.url | Should -Be 'https://example.com/file.zip'
    }
}

Describe 'Static command injection guardrails' {
    It 'does not use Invoke-Expression anywhere in core' {
        $source = (Get-ChildItem (Join-Path $script:UhmProjectRoot 'core') -Filter *.ps1 | Get-Content -Raw) -join "`n"
        $source | Should -Not -Match '(?im)^\s*Invoke-Expression\b'
    }

    It 'binds the HTTP listener to IPv4 loopback only' {
        $bridge = Get-Content -Raw (Join-Path $script:UhmProjectRoot 'core\UHM-Bridge.ps1')
        $bridge | Should -Match "http://localhost"
        $bridge | Should -Not -Match "http://\+"
        $bridge | Should -Not -Match "http://0\.0\.0\.0"
    }
}
