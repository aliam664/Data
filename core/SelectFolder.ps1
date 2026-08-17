param([string]$Description = 'پوشه Assetto Corsa را انتخاب کنید.')
Set-StrictMode -Version 2.0
Add-Type -AssemblyName System.Windows.Forms
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.Description = $Description
$dialog.ShowNewFolderButton = $false
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    [Console]::Write($dialog.SelectedPath)
}
$dialog.Dispose()
