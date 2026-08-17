BeforeAll {
    $repoRoot = Split-Path -Parent $PSScriptRoot
}

Describe 'Windows PowerShell 5.1 source encoding' {
    It 'stores every PowerShell source file as UTF-8 with BOM' {
        $files = @(Get-ChildItem (Join-Path $repoRoot 'core'),(Join-Path $repoRoot 'wpf'),(Join-Path $repoRoot 'catalog'),(Join-Path $repoRoot 'tests') -Recurse -Filter *.ps1 -File)
        $files.Count | Should -BeGreaterThan 0
        foreach ($file in $files) {
            $bytes = [IO.File]::ReadAllBytes($file.FullName)
            $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
            $hasBom | Should -BeTrue -Because "$($file.FullName) contains Persian literals and is parsed by Windows PowerShell 5.1"
        }
    }
}
