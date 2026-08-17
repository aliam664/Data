[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ProjectRoot)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:UhmProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) {
    throw 'رابط WPF باید با PowerShell -STA اجرا شود. برنامه را از UHM-Launcher.cmd باز کنید.'
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms

# Load the operational modules in this native UI scope. No local HTTP bridge is needed.
foreach ($module in @('Logger.ps1','Security.ps1','SteamDetector.ps1','CspChecker.ps1','Settings.ps1','CatalogClient.ps1','QueueManager.ps1','Downloader.ps1','Extractor.ps1','Installer.ps1')) {
    . (Join-Path $script:UhmProjectRoot ('core\' + $module))
}

$xamlPath = Join-Path $script:UhmProjectRoot 'wpf\MainWindow.xaml'
[xml]$xaml = [IO.File]::ReadAllText($xamlPath, [Text.Encoding]::UTF8)
$reader = New-Object Xml.XmlNodeReader($xaml)
try { $window = [Windows.Markup.XamlReader]::Load($reader) }
finally { $reader.Dispose() }

$script:controls = @{}
foreach ($match in [regex]::Matches([IO.File]::ReadAllText($xamlPath), 'x:Name="([A-Za-z0-9_]+)"')) {
    $name = $match.Groups[1].Value
    $control = $window.FindName($name)
    if ($null -ne $control) { $script:controls[$name] = $control }
}

$script:workers = @{}
$script:settings = $null
$script:catalogResult = $null
$script:steamStatus = $null
$script:selectedMod = $null
$script:currentPage = 'Dashboard'
$script:lastQueueSignature = ''
$script:refreshPowerShell = $null
$script:refreshHandle = $null
$script:isClosing = $false
$script:brushConverter = New-Object Windows.Media.BrushConverter

function Get-UhmNativeControl {
    param([Parameter(Mandatory = $true)][string]$Name)
    return $script:controls[$Name]
}

function ConvertTo-UhmFaNumber {
    param($Value)
    $text = [string]$Value
    return $text.Replace('0','۰').Replace('1','۱').Replace('2','۲').Replace('3','۳').Replace('4','۴').Replace('5','۵').Replace('6','۶').Replace('7','۷').Replace('8','۸').Replace('9','۹')
}

function Format-UhmNativeBytes {
    param([long]$Bytes)
    if ($Bytes -le 0) { return '۰ B' }
    $units = @('B','KB','MB','GB','TB')
    $index = 0
    $value = [double]$Bytes
    while ($value -ge 1024 -and $index -lt $units.Count - 1) { $value /= 1024; $index++ }
    return ('{0} {1}' -f (ConvertTo-UhmFaNumber ([Math]::Round($value, 1))), $units[$index])
}

function Get-UhmNativeCategoryName {
    param([string]$Category)
    $names = @{ cars='خودرو'; tracks='پیست'; skins='اسکین'; graphics='گرافیک'; packs='پک کامل'; apps='اپلیکیشن'; sounds='صدا'; weather='آب‌وهوا'; ppfilters='فیلتر گرافیکی'; miscellaneous='متفرقه' }
    if ($names.ContainsKey($Category)) { return $names[$Category] }
    return $Category
}

function Set-UhmNativeStatus {
    param([string]$Text, [ValidateSet('normal','success','warning','error')][string]$Kind = 'normal')
    $colors = @{ normal='#8B98A7'; success='#50E395'; warning='#FF9F43'; error='#FF5864' }
    (Get-UhmNativeControl 'StatusText').Text = $Text
    (Get-UhmNativeControl 'StatusText').Foreground = $script:brushConverter.ConvertFromString($colors[$Kind])
}

function Show-UhmNativeMessage {
    param([string]$Text, [string]$Title = 'UHM Launcher', [ValidateSet('Info','Warning','Error')][string]$Kind = 'Info')
    $icon = switch ($Kind) {
        'Warning' { [Windows.MessageBoxImage]::Warning }
        'Error' { [Windows.MessageBoxImage]::Error }
        default { [Windows.MessageBoxImage]::Information }
    }
    [void][Windows.MessageBox]::Show($window, $Text, $Title, [Windows.MessageBoxButton]::OK, $icon)
}

function Confirm-UhmNativeAction {
    param([string]$Text, [string]$Title = 'تأیید عملیات')
    return [Windows.MessageBox]::Show($window, $Text, $Title, [Windows.MessageBoxButton]::YesNo, [Windows.MessageBoxImage]::Warning) -eq [Windows.MessageBoxResult]::Yes
}

function Set-UhmNativeBusy {
    param([bool]$Visible, [string]$Title = 'در حال پردازش…', [string]$Message = 'لطفاً پنجره را نبندید.')
    (Get-UhmNativeControl 'BusyTitle').Text = $Title
    (Get-UhmNativeControl 'BusyMessage').Text = $Message
    $busyOverlay = Get-UhmNativeControl 'BusyOverlay'
    if ($Visible) { $busyOverlay.Visibility = [Windows.Visibility]::Visible } else { $busyOverlay.Visibility = [Windows.Visibility]::Collapsed }
    if ($Visible) { [System.Windows.Forms.Application]::DoEvents() }
}

function Show-UhmNativePage {
    param([ValidateSet('Dashboard','Catalog','Queue','Installed','Settings')][string]$Page)
    foreach ($name in @('Dashboard','Catalog','Queue','Installed','Settings')) {
        $pageControl = Get-UhmNativeControl ('Page' + $name)
        if ($name -eq $Page) { $pageControl.Visibility = [Windows.Visibility]::Visible } else { $pageControl.Visibility = [Windows.Visibility]::Collapsed }
        $button = Get-UhmNativeControl ('Nav' + $name)
        if ($name -eq $Page) {
            $button.Background = $script:brushConverter.ConvertFromString('#1EDFFF32')
            $button.Foreground = $script:brushConverter.ConvertFromString('#F3F6F8')
            $button.BorderBrush = $script:brushConverter.ConvertFromString('#3ADFFF32')
        } else {
            $button.Background = [Windows.Media.Brushes]::Transparent
            $button.Foreground = $script:brushConverter.ConvertFromString('#8B98A7')
            $button.BorderBrush = [Windows.Media.Brushes]::Transparent
        }
    }
    $script:currentPage = $Page
    if ($Page -eq 'Catalog') { Update-UhmNativeCatalogView }
    if ($Page -eq 'Queue') { Update-UhmNativeQueueView -Force }
    if ($Page -eq 'Installed') { Update-UhmNativeInstalledView }
    if ($Page -eq 'Settings') { Update-UhmNativeSettingsView }
}

function Get-UhmNativePathModels {
    $items = @()
    foreach ($gamePath in @($script:settings.gamePaths)) {
        $items += [pscustomobject]@{ id=[string]$gamePath.id; name=[string]$gamePath.name; path=[string]$gamePath.path; isValid=[bool]$gamePath.isValid; display=('{0} — {1}' -f [string]$gamePath.name, [string]$gamePath.path) }
    }
    return $items
}

function Get-UhmNativeTarget {
    param([AllowNull()][string]$Id)
    if ([string]::IsNullOrWhiteSpace($Id)) { $Id = [string]$script:settings.defaultGamePathId }
    return $script:settings.gamePaths | Where-Object { $_.id -eq $Id -and $_.isValid } | Select-Object -First 1
}

function Update-UhmNativeDashboard {
    $mods = @($script:catalogResult.catalog.mods | Where-Object { $_.enabled })
    $installed = @(Get-UhmInstalledMods)
    $queue = @(Get-UhmQueueItems)
    $active = @($queue | Where-Object { $_.status -in @('queued','starting','connecting','downloading','paused','preparingInstall') }).Count
    (Get-UhmNativeControl 'StatTotalMods').Text = ConvertTo-UhmFaNumber $mods.Count
    (Get-UhmNativeControl 'StatInstalled').Text = ConvertTo-UhmFaNumber $installed.Count
    (Get-UhmNativeControl 'StatActive').Text = ConvertTo-UhmFaNumber $active
    $defaultPath = Get-UhmNativeTarget ([string]$script:settings.defaultGamePathId)
    if ($null -ne $defaultPath) {
        (Get-UhmNativeControl 'StatGame').Text = 'آماده نصب'
        (Get-UhmNativeControl 'StatGame').Foreground = $script:brushConverter.ConvertFromString('#50E395')
        (Get-UhmNativeControl 'StatGamePath').Text = [string]$defaultPath.path
        (Get-UhmNativeControl 'HealthGame').Text = 'مسیر معتبر'
        (Get-UhmNativeControl 'HealthGame').Foreground = $script:brushConverter.ConvertFromString('#50E395')
    } else {
        (Get-UhmNativeControl 'StatGame').Text = 'بدون مسیر'
        (Get-UhmNativeControl 'StatGame').Foreground = $script:brushConverter.ConvertFromString('#FF9F43')
        (Get-UhmNativeControl 'StatGamePath').Text = 'از تنظیمات مسیر بازی را اضافه کنید'
        (Get-UhmNativeControl 'HealthGame').Text = 'پیدا نشد'
        (Get-UhmNativeControl 'HealthGame').Foreground = $script:brushConverter.ConvertFromString('#FF5864')
    }
    $healthSteam = Get-UhmNativeControl 'HealthSteam'
    if ($script:steamStatus.steamFound) { $healthSteam.Text = 'شناسایی شد'; $healthSteam.Foreground = $script:brushConverter.ConvertFromString('#50E395') } else { $healthSteam.Text = 'پیدا نشد'; $healthSteam.Foreground = $script:brushConverter.ConvertFromString('#FF9F43') }
    $featured = @($mods | Where-Object { $_.featured } | Select-Object -First 6 | ForEach-Object { [pscustomobject]@{ display=('{0}  ·  v{1}  ·  {2}' -f $_.nameFa, $_.version, (Get-UhmNativeCategoryName $_.category)); id=$_.id } })
    $list = Get-UhmNativeControl 'FeaturedList'
    $list.DisplayMemberPath = 'display'
    $list.ItemsSource = $featured
}

function Update-UhmNativeCatalogView {
    if ($null -eq $script:catalogResult) { return }
    $query = ([string](Get-UhmNativeControl 'CatalogSearch').Text).Trim().ToLowerInvariant()
    $categoryControl = Get-UhmNativeControl 'CategoryFilter'
    $category = if ($null -ne $categoryControl.SelectedValue) { [string]$categoryControl.SelectedValue } else { 'all' }
    $sortControl = Get-UhmNativeControl 'SortFilter'
    $sort = if ($null -ne $sortControl.SelectedValue) { [string]$sortControl.SelectedValue } else { 'newest' }
    $version = [string](Get-UhmNativeControl 'VersionFilter').SelectedValue
    $csp = [string](Get-UhmNativeControl 'CspFilter').SelectedValue
    $password = [string](Get-UhmNativeControl 'PasswordFilter').SelectedValue
    $installedFilter = [string](Get-UhmNativeControl 'InstalledFilter').SelectedValue
    if ([string]::IsNullOrWhiteSpace($version)) { $version = 'all' }; if ([string]::IsNullOrWhiteSpace($csp)) { $csp = 'all' }; if ([string]::IsNullOrWhiteSpace($password)) { $password = 'all' }; if ([string]::IsNullOrWhiteSpace($installedFilter)) { $installedFilter = 'all' }
    $installedIds = @(Get-UhmInstalledMods | ForEach-Object { [string]$_.modId })
    $mods = @($script:catalogResult.catalog.mods | Where-Object {
        if (-not $_.enabled) { return $false }
        $matchesQuery = [string]::IsNullOrWhiteSpace($query) -or (('{0} {1} {2} {3}' -f $_.name, $_.nameFa, $_.author, $_.shortDescription).ToLowerInvariant().Contains($query))
        $matchesCategory = $category -eq 'all' -or $_.category -eq $category
        $matchesVersion = $version -eq 'all' -or $_.version -eq $version
        $matchesCsp = $csp -eq 'all' -or ($csp -eq 'yes' -and $_.requiresCsp) -or ($csp -eq 'no' -and -not $_.requiresCsp)
        $matchesPassword = $password -eq 'all' -or ($password -eq 'yes' -and $_.passwordRequired) -or ($password -eq 'no' -and -not $_.passwordRequired)
        $isInstalled = $installedIds -contains [string]$_.id
        $matchesInstalled = $installedFilter -eq 'all' -or ($installedFilter -eq 'yes' -and $isInstalled) -or ($installedFilter -eq 'no' -and -not $isInstalled)
        return $matchesQuery -and $matchesCategory -and $matchesVersion -and $matchesCsp -and $matchesPassword -and $matchesInstalled
    })
    switch ($sort) {
        'name' { $mods = @($mods | Sort-Object nameFa) }
        'size' { $mods = @($mods | Sort-Object sizeBytes -Descending) }
        'popular' { $mods = @($mods | Sort-Object popularity -Descending) }
        'updated' { $mods = @($mods | Sort-Object updatedAt -Descending) }
        default { $mods = @($mods | Sort-Object releaseDate -Descending) }
    }
    $view = @($mods | ForEach-Object {
        [pscustomobject]@{
            id = [string]$_.id; nameFa = [string]$_.nameFa; image = [string]$_.image; categoryFa = Get-UhmNativeCategoryName ([string]$_.category)
            authorLine = ('{0}  ·  v{1}' -f [string]$_.author, [string]$_.version); shortDescription = [string]$_.shortDescription
            specLine = ('{0}  ·  {1}' -f [string]$_.sizeText, ([string]$_.archiveType).ToUpperInvariant())
        }
    })
    (Get-UhmNativeControl 'CatalogList').ItemsSource = $view
    (Get-UhmNativeControl 'CatalogCount').Text = ('{0} مود' -f (ConvertTo-UhmFaNumber $view.Count))
}

function Get-UhmNativeStatusName {
    param([string]$Status)
    $names = @{ queued='در صف'; starting='در حال شروع'; connecting='در حال اتصال'; downloading='در حال دانلود'; paused='مکث‌شده'; canceling='در حال لغو'; canceled='لغوشده'; failed='خطای دانلود'; manualRequired='نیازمند دانلود دستی'; downloaded='آماده نصب'; preparingInstall='آماده‌سازی نصب'; awaitingConfirmation='نیازمند تأیید'; installed='نصب‌شده'; installFailed='خطای نصب' }
    if ($names.ContainsKey($Status)) { return $names[$Status] }
    return $Status
}

function Get-UhmNativeQueuePrimary {
    param($Item)
    switch ([string]$Item.status) {
        'queued' { return @('شروع خودکار','none') }
        'starting' { return @('مکث','pause') }
        'connecting' { return @('مکث','pause') }
        'downloading' { return @('مکث','pause') }
        'paused' { return @('ادامه','resume') }
        'failed' { return @('تلاش مجدد','retry') }
        'canceled' { return @('تلاش مجدد','retry') }
        'manualRequired' { return @('صفحه رسمی','details') }
        'downloaded' { return @('نصب','install') }
        'installFailed' { return @('تلاش نصب','install') }
        'awaitingConfirmation' { return @('بررسی و تأیید','confirm') }
        'installed' { return @('جزئیات','details') }
        default { return @('در حال پردازش','none') }
    }
}

function Update-UhmNativeQueueView {
    param([switch]$Force)
    $items = @(Get-UhmQueueItems)
    $signature = $items | ConvertTo-Json -Depth 8 -Compress
    if (-not $Force -and $signature -eq $script:lastQueueSignature) { return }
    $script:lastQueueSignature = $signature
    $view = @()
    foreach ($item in $items) {
        $primary = Get-UhmNativeQueuePrimary $item
        $progress = [Math]::Max(0, [Math]::Min(100, [double]$item.progress))
        $view += [pscustomobject]@{
            id=[string]$item.id; modId=[string]$item.modId; nameFa=[string]$item.nameFa; initials=([string]$item.name).Substring(0, [Math]::Min(2, ([string]$item.name).Length)).ToUpperInvariant()
            versionLine=('v{0}{1}' -f [string]$item.version, $(if ($item.installAfterDownload) { ' · نصب خودکار' } else { '' })); statusFa=Get-UhmNativeStatusName ([string]$item.status)
            progress=$progress; progressText=('{0}٪' -f (ConvertTo-UhmFaNumber ([Math]::Round($progress, 1)))); transferLine=('{0} / {1}  ·  {2}/s' -f (Format-UhmNativeBytes ([long]$item.bytesReceived)), (Format-UhmNativeBytes ([long]$item.totalBytes)), (Format-UhmNativeBytes ([long]$item.speedBytes)))
            error=[string]$item.error; primaryLabel=$primary[0]; primaryAction=$primary[1]
        }
    }
    (Get-UhmNativeControl 'QueueList').ItemsSource = $view
    $active = @($items | Where-Object { $_.status -in @('queued','starting','connecting','downloading','paused','preparingInstall') }).Count
    $statusQueue = Get-UhmNativeControl 'StatusQueue'
    if ($items.Count -eq 0) { $statusQueue.Text = 'صف خالی' } else { $statusQueue.Text = ('{0} آیتم · {1} فعال' -f (ConvertTo-UhmFaNumber $items.Count), (ConvertTo-UhmFaNumber $active)) }
    Update-UhmNativeDashboard
}

function Update-UhmNativeInstalledView {
    $view = @(Get-UhmInstalledMods | ForEach-Object {
        $installedDate = [string]$_.installedAt
        try { $installedDate = ([DateTime]$_.installedAt).ToString('yyyy/MM/dd HH:mm') } catch {}
        [pscustomobject]@{ nameFa=[string]$_.nameFa; installedVersion=[string]$_.installedVersion; installedDate=$installedDate; fileCount=ConvertTo-UhmFaNumber ([int]$_.fileCount); gamePath=[string]$_.gamePath }
    })
    (Get-UhmNativeControl 'InstalledGrid').ItemsSource = $view
}

function Update-UhmNativeSettingsView {
    $paths = @(Get-UhmNativePathModels)
    $defaultCombo = Get-UhmNativeControl 'SettingsDefaultPath'
    $defaultCombo.ItemsSource = $paths
    $defaultCombo.SelectedValue = [string]$script:settings.defaultGamePathId
    (Get-UhmNativeControl 'DetailTargetPath').ItemsSource = $paths
    (Get-UhmNativeControl 'DetailTargetPath').SelectedValue = [string]$script:settings.defaultGamePathId
    (Get-UhmNativeControl 'DownloadDirectory').Text = [string]$script:settings.downloadDirectory
    (Get-UhmNativeControl 'MaxDownloads').SelectedIndex = [Math]::Max(0, [Math]::Min(3, [int]$script:settings.maxConcurrentDownloads - 1))
    (Get-UhmNativeControl 'CacheEnabled').IsChecked = [bool]$script:settings.cacheEnabled
    (Get-UhmNativeControl 'SettingsCatalogVersion').Text = [string]$script:catalogResult.catalog.catalogVersion
}

function Show-UhmNativeModDetails {
    param([string]$ModId)
    $mod = $script:catalogResult.catalog.mods | Where-Object { $_.id -eq $ModId -and $_.enabled } | Select-Object -First 1
    if ($null -eq $mod) { Show-UhmNativeMessage 'مود فعال در کاتالوگ پیدا نشد.' 'خطا' 'Error'; return }
    $script:selectedMod = $mod
    (Get-UhmNativeControl 'DetailCategory').Text = Get-UhmNativeCategoryName ([string]$mod.category)
    (Get-UhmNativeControl 'DetailName').Text = [string]$mod.nameFa
    (Get-UhmNativeControl 'DetailAuthor').Text = ('{0} · {1}' -f [string]$mod.name, [string]$mod.author)
    (Get-UhmNativeControl 'DetailDescription').Text = [string]$mod.description
    $instructionLines = @($mod.dependencies | ForEach-Object { '• وابستگی: ' + [string]$_ }) + @($mod.installInstructions | ForEach-Object { '• ' + [string]$_ }) + @($mod.activationSteps | ForEach-Object { '• پس از نصب: ' + [string]$_ })
    $detailInstructions = Get-UhmNativeControl 'DetailInstructions'
    if ($instructionLines.Count) { $detailInstructions.Text = $instructionLines -join [Environment]::NewLine } else { $detailInstructions.Text = 'دستورالعمل اضافه‌ای ثبت نشده است.' }
    (Get-UhmNativeControl 'DetailVersion').Text = [string]$mod.version
    (Get-UhmNativeControl 'DetailSize').Text = [string]$mod.sizeText
    (Get-UhmNativeControl 'DetailArchive').Text = ([string]$mod.archiveType).ToUpperInvariant()
    $detailCsp = Get-UhmNativeControl 'DetailCsp'
    if ($mod.requiresCsp) {
        $previewSuffix = if ($mod.cspPreviewRequired) { ' Preview' } else { '' }
        $detailCsp.Text = ('حداقل {0}{1}' -f [string]$mod.minCspVersion, $previewSuffix)
    } else { $detailCsp.Text = 'نیاز ندارد' }
    (Get-UhmNativeControl 'DetailInstallRoot').Text = [string]$mod.installRoot
    Update-UhmNativeSettingsView
    (Get-UhmNativeControl 'DetailAutoInstall').IsChecked = [bool](Get-UhmNativeControl 'CatalogAutoInstall').IsChecked
    (Get-UhmNativeControl 'BtnDetailInstall').IsEnabled = @($script:settings.gamePaths | Where-Object { $_.isValid }).Count -gt 0
    (Get-UhmNativeControl 'DetailsOverlay').Visibility = [Windows.Visibility]::Visible
}

function Add-UhmNativeQueueItem {
    param([bool]$InstallAfterDownload)
    if ($null -eq $script:selectedMod) { return }
    $duplicate = Get-UhmQueueItems | Where-Object { $_.modId -eq [string]$script:selectedMod.id -and $_.status -ne 'installed' } | Select-Object -First 1
    if ($null -ne $duplicate) { Show-UhmNativeMessage 'این مود از قبل در صف وجود دارد. همان آیتم را ادامه یا Retry کنید.' 'صف دانلود' 'Warning'; return }
    $targetId = [string](Get-UhmNativeControl 'DetailTargetPath').SelectedValue
    $target = Get-UhmNativeTarget $targetId
    if ($InstallAfterDownload -and $null -eq $target) { Show-UhmNativeMessage 'برای نصب، ابتدا یک مسیر معتبر Assetto Corsa انتخاب کنید.' 'مسیر بازی' 'Warning'; return }
    $targetIdValue = if ($null -ne $target) { [string]$target.id } else { $null }
    $targetPathValue = if ($null -ne $target) { [string]$target.path } else { $null }
    [void](New-UhmQueueItem -Mod $script:selectedMod -TargetId $targetIdValue -TargetPath $targetPathValue -InstallAfterDownload $InstallAfterDownload -DownloadDirectory ([string]$script:settings.downloadDirectory))
    (Get-UhmNativeControl 'DetailsOverlay').Visibility = [Windows.Visibility]::Collapsed
    Set-UhmNativeStatus ('«{0}» به صف اضافه شد.' -f [string]$script:selectedMod.nameFa) 'success'
    Update-UhmNativeQueueView -Force
    Show-UhmNativePage 'Queue'
}

function Start-UhmNativePendingWorkers {
    foreach ($id in @($script:workers.Keys)) {
        $process = $script:workers[$id]
        if ($process.HasExited) {
            $item = Get-UhmQueueItem $id
            if ($null -ne $item -and $item.status -in @('starting','connecting','downloading','preparingInstall','canceling')) {
                Set-UhmQueueState -Id $id -Changes @{ status='failed'; error='Worker بدون تکمیل عملیات متوقف شد؛ فایل ناقص باقی مانده است.' } | Out-Null
            }
            $process.Dispose(); [void]$script:workers.Remove($id)
        }
    }
    $maximum = [Math]::Max(1, [Math]::Min(4, [int]$script:settings.maxConcurrentDownloads))
    $available = $maximum - $script:workers.Count
    if ($available -le 0) { return }
    foreach ($item in @(Get-UhmQueueItems | Where-Object { $_.status -eq 'queued' } | Select-Object -First $available)) {
        $jobPath = Join-Path (Get-UhmQueueRoot) ([string]$item.id + '.job.json')
        if (-not (Test-Path -LiteralPath $jobPath -PathType Leaf)) { Set-UhmQueueState -Id ([string]$item.id) -Changes @{status='failed';error='فایل داخلی صف پیدا نشد.'}|Out-Null; continue }
        Set-UhmQueueState -Id ([string]$item.id) -Changes @{status='starting';error=$null}|Out-Null
        $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"' + (Join-Path $script:UhmProjectRoot 'core\UHM-Core.ps1') + '"'),'-Action','download-worker','-JobPath',('"' + $jobPath + '"'))
        try {
            $process = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
            $script:workers[[string]$item.id] = $process
        } catch {
            Set-UhmQueueState -Id ([string]$item.id) -Changes @{status='failed';error=$_.Exception.Message}|Out-Null
        }
    }
}

function Stop-UhmNativeWorkers {
    foreach ($id in @($script:workers.Keys)) {
        $process = $script:workers[$id]
        try {
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                $item = Get-UhmQueueItem $id
                if ($null -ne $item -and $item.status -in @('starting','connecting','downloading','paused','preparingInstall')) {
                    Set-UhmQueueState -Id $id -Changes @{status='failed';error='لانچر بسته شد؛ فایل ناقص برای Resume نگه‌داری شد.'}|Out-Null
                }
            }
        } catch {}
        $process.Dispose()
    }
    $script:workers.Clear()
}

function Invoke-UhmNativeInstallPreview {
    param([string]$Id, [bool]$ConfirmReinstall = $false)
    $state = Get-UhmQueueItem $Id
    $jobPath = Join-Path (Get-UhmQueueRoot) ($Id + '.job.json')
    if ($null -eq $state -or -not (Test-Path -LiteralPath $jobPath -PathType Leaf)) { Show-UhmNativeMessage 'آیتم صف پیدا نشد.' 'نصب' 'Error'; return }
    if (-not (Test-Path -LiteralPath ([string]$state.downloadPath) -PathType Leaf)) { Show-UhmNativeMessage 'دانلود این مود کامل نشده است.' 'نصب' 'Warning'; return }
    $job = [IO.File]::ReadAllText($jobPath) | ConvertFrom-Json
    $target = Get-UhmNativeTarget ([string]$state.targetId)
    if ($null -eq $target) { $target = Get-UhmNativeTarget ([string]$script:settings.defaultGamePathId) }
    if ($null -eq $target) { Show-UhmNativeMessage 'مسیر Assetto Corsa معتبر نیست.' 'نصب' 'Error'; return }
    Set-UhmNativeBusy $true 'ساخت پیش‌نمایش نصب' 'آرشیو در پوشه موقت امن بررسی می‌شود…'
    try {
        $preview = New-UhmInstallationPreview -Mod $job.mod -ArchivePath ([string]$state.downloadPath) -GamePath ([string]$target.path) -ConfirmReinstall $ConfirmReinstall -QueueId $Id
        Set-UhmQueueState -Id $Id -Changes @{status='awaitingConfirmation';previewId=$preview.id;fileCount=$preview.fileCount;installBytes=$preview.totalBytes;overwrites=@($preview.overwrites);executableFiles=@($preview.executableFiles);csp=$preview.csp}|Out-Null
        Set-UhmNativeBusy $false
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add(('تعداد فایل: {0}' -f (ConvertTo-UhmFaNumber $preview.fileCount)))
        $lines.Add(('حجم استخراج‌شده: {0}' -f (Format-UhmNativeBytes ([long]$preview.totalBytes))))
        if (-not $preview.csp.compatible) { $lines.Add(('هشدار CSP: {0}' -f [string]$preview.csp.message)) }
        if (@($preview.executableFiles).Count -gt 0) { $lines.Add(('{0} فایل اجرایی/اسکریپت شناسایی شد؛ UHM آن‌ها را اجرا نمی‌کند.' -f (ConvertTo-UhmFaNumber @($preview.executableFiles).Count))) }
        if (@($preview.overwrites).Count -gt 0) {
            $lines.Add(('{0} فایل جایگزین خواهد شد:' -f (ConvertTo-UhmFaNumber @($preview.overwrites).Count)))
            foreach ($path in @($preview.overwrites | Select-Object -First 12)) { $lines.Add('  • ' + [string]$path) }
            if (@($preview.overwrites).Count -gt 12) { $lines.Add('  … و موارد بیشتر') }
        } else { $lines.Add('فایل موجودی برای جایگزینی پیدا نشد.') }
        $lines.Add('بازی و Content Manager اجرا نخواهند شد.')
        if (Confirm-UhmNativeAction -Text (($lines -join [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine + 'نصب انجام شود؟') -Title 'تأیید نهایی نصب') {
            Set-UhmNativeBusy $true 'در حال نصب مود' 'فایل‌ها در مقصد امن کپی می‌شوند…'
            $result = Complete-UhmInstallation -PreviewId $preview.id -OverwriteApproved (@($preview.overwrites).Count -gt 0)
            Set-UhmQueueState -Id $Id -Changes @{status='installed';installResult=$result;error=$null}|Out-Null
            Set-UhmNativeStatus $result.message 'success'
            Update-UhmNativeInstalledView
        }
    } catch {
        Set-UhmNativeBusy $false
        if (-not $ConfirmReinstall -and $_.Exception.Message -match 'قبلاً نصب') {
            if (Confirm-UhmNativeAction 'این مود قبلاً نصب شده است. پیش‌نمایش نصب مجدد ساخته شود؟' 'نصب مجدد') { Invoke-UhmNativeInstallPreview -Id $Id -ConfirmReinstall $true }
        } else {
            Set-UhmQueueState -Id $Id -Changes @{status='installFailed';error=$_.Exception.Message}|Out-Null
            Show-UhmNativeMessage $_.Exception.Message 'خطای نصب' 'Error'
        }
    } finally {
        Set-UhmNativeBusy $false
        Update-UhmNativeQueueView -Force
    }
}

function Invoke-UhmNativeExistingConfirmation {
    param([string]$Id)
    $state = Get-UhmQueueItem $Id
    if ($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.previewId)) { Show-UhmNativeMessage 'پیش‌نمایش نصب پیدا نشد.' 'نصب' 'Error'; return }
    $lines = @('پیش‌نمایش نصب آماده است.')
    if (@($state.overwrites).Count -gt 0) { $lines += ('{0} فایل جایگزین خواهد شد.' -f (ConvertTo-UhmFaNumber @($state.overwrites).Count)) }
    if (@($state.executableFiles).Count -gt 0) { $lines += ('{0} فایل اجرایی/اسکریپت فقط کپی و هرگز اجرا نمی‌شود.' -f (ConvertTo-UhmFaNumber @($state.executableFiles).Count)) }
    if (-not (Confirm-UhmNativeAction (($lines -join [Environment]::NewLine) + [Environment]::NewLine + 'ادامه نصب؟') 'تأیید نصب')) { return }
    Set-UhmNativeBusy $true 'در حال نصب مود'
    try {
        $result = Complete-UhmInstallation -PreviewId ([string]$state.previewId) -OverwriteApproved (@($state.overwrites).Count -gt 0)
        Set-UhmQueueState -Id $Id -Changes @{status='installed';installResult=$result;error=$null}|Out-Null
        Set-UhmNativeStatus $result.message 'success'
        Update-UhmNativeInstalledView
    } catch { Show-UhmNativeMessage $_.Exception.Message 'خطای نصب' 'Error' }
    finally { Set-UhmNativeBusy $false; Update-UhmNativeQueueView -Force }
}

function Invoke-UhmNativeQueuePrimary {
    param([string]$Id)
    $item = Get-UhmQueueItem $Id
    if ($null -eq $item) { return }
    $action = (Get-UhmNativeQueuePrimary $item)[1]
    switch ($action) {
        'pause' { Set-UhmQueueSignal -Id $Id -Signal pause -Enabled $true; Set-UhmQueueState -Id $Id -Changes @{status='paused'}|Out-Null }
        'resume' { Set-UhmQueueSignal -Id $Id -Signal pause -Enabled $false; if (-not $script:workers.ContainsKey($Id)) { Reset-UhmQueueItem $Id|Out-Null } else { Set-UhmQueueState -Id $Id -Changes @{status='downloading'}|Out-Null } }
        'retry' { Reset-UhmQueueItem $Id | Out-Null }
        'install' { Invoke-UhmNativeInstallPreview $Id }
        'confirm' { Invoke-UhmNativeExistingConfirmation $Id }
        'details' { Show-UhmNativeModDetails ([string]$item.modId) }
    }
    Update-UhmNativeQueueView -Force
}

function Invoke-UhmNativeQueueCancel {
    param([string]$Id)
    $item = Get-UhmQueueItem $Id
    if ($null -eq $item -or $item.status -in @('installed','canceled','failed','downloaded')) { return }
    if (-not (Confirm-UhmNativeAction 'دانلود لغو شود؟ فایل ناقص برای Resume یا حذف بعدی نگه‌داری می‌شود.' 'لغو دانلود')) { return }
    Set-UhmQueueSignal -Id $Id -Signal cancel -Enabled $true
    $status = if ($script:workers.ContainsKey($Id) -and -not $script:workers[$Id].HasExited) { 'canceling' } else { 'canceled' }
    Set-UhmQueueState -Id $Id -Changes @{status=$status}|Out-Null
    Update-UhmNativeQueueView -Force
}

function Invoke-UhmNativeQueueRemove {
    param([string]$Id)
    if ($script:workers.ContainsKey($Id) -and -not $script:workers[$Id].HasExited) { Show-UhmNativeMessage 'ابتدا دانلود را لغو و تا توقف Worker صبر کنید.' 'صف دانلود' 'Warning'; return }
    if (-not (Confirm-UhmNativeAction 'رکورد از صف حذف شود؟ هیچ فایل بازی حذف نمی‌شود.' 'حذف رکورد صف')) { return }
    $deleteFile = Confirm-UhmNativeAction 'فایل ناقص یا فایل دانلودشده نیز حذف شود؟ انتخاب «خیر» فایل را نگه می‌دارد.' 'حذف فایل دانلود'
    Remove-UhmQueueItem -Id $Id -Confirmed $true -DeletePartial $deleteFile
    Update-UhmNativeQueueView -Force
}

function Select-UhmNativeFolder {
    param([string]$Description)
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = $Description
    $dialog.ShowNewFolderButton = $true
    try { if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath } }
    finally { $dialog.Dispose() }
    return $null
}

function Start-UhmNativeCatalogRefresh {
    if ($null -ne $script:refreshHandle) { Set-UhmNativeStatus 'به‌روزرسانی کاتالوگ هم‌اکنون در حال اجرا است.' 'warning'; return }
    (Get-UhmNativeControl 'BtnRefresh').IsEnabled = $false
    Set-UhmNativeStatus 'در حال دریافت کاتالوگ از GitHub…' 'warning'
    $scriptText = @'
param($Root, $Url, $CacheEnabled)
$script:UhmProjectRoot = $Root
foreach ($module in @('Logger.ps1','Security.ps1','CatalogClient.ps1')) { . (Join-Path $Root ('core\' + $module)) }
$result = Update-UhmCatalog -Url $Url -CacheEnabled $CacheEnabled
$result | ConvertTo-Json -Depth 20 -Compress
'@
    $script:refreshPowerShell = [PowerShell]::Create()
    [void]$script:refreshPowerShell.AddScript($scriptText).AddArgument($script:UhmProjectRoot).AddArgument([string]$script:settings.catalogUrl).AddArgument([bool]$script:settings.cacheEnabled)
    $script:refreshHandle = $script:refreshPowerShell.BeginInvoke()
}

function Complete-UhmNativeCatalogRefresh {
    if ($null -eq $script:refreshHandle -or -not $script:refreshHandle.IsCompleted) { return }
    try {
        $output = $script:refreshPowerShell.EndInvoke($script:refreshHandle)
        if ($script:refreshPowerShell.Streams.Error.Count -gt 0) { throw [string]$script:refreshPowerShell.Streams.Error[0] }
        $result = (($output | ForEach-Object { [string]$_ }) -join '') | ConvertFrom-Json
        $script:catalogResult = Get-UhmCatalog
        if (-not $result.offline) {
            $script:settings.lastCatalogRefresh = [DateTime]::UtcNow.ToString('o')
            $script:settings.catalogVersion = [string]$script:catalogResult.catalog.catalogVersion
            Save-UhmSettings $script:settings
            (Get-UhmNativeControl 'ConnectionText').Text = 'کاتالوگ آنلاین'
            (Get-UhmNativeControl 'ConnectionDot').Fill = $script:brushConverter.ConvertFromString('#50E395')
            Set-UhmNativeStatus 'کاتالوگ با موفقیت بررسی و به‌روز شد.' 'success'
        } else {
            (Get-UhmNativeControl 'ConnectionText').Text = 'Cache آفلاین'
            (Get-UhmNativeControl 'ConnectionDot').Fill = $script:brushConverter.ConvertFromString('#FF9F43')
            Set-UhmNativeStatus 'ارتباط برقرار نشد؛ آخرین Cache نمایش داده می‌شود.' 'warning'
        }
        Update-UhmNativeCatalogView; Update-UhmNativeDashboard; Update-UhmNativeSettingsView
    } catch { Set-UhmNativeStatus ('خطای Refresh: ' + $_.Exception.Message) 'error'; Show-UhmNativeMessage $_.Exception.Message 'خطای Refresh' 'Error' }
    finally {
        if ($null -ne $script:refreshPowerShell) { $script:refreshPowerShell.Dispose() }
        $script:refreshPowerShell = $null; $script:refreshHandle = $null
        (Get-UhmNativeControl 'BtnRefresh').IsEnabled = $true
    }
}

function Get-UhmNativeButtonAncestor {
    param([Windows.DependencyObject]$Source)
    $current = $Source
    while ($null -ne $current) {
        if ($current -is [Windows.Controls.Button]) { return $current }
        try { $current = [Windows.Media.VisualTreeHelper]::GetParent($current) } catch { return $null }
    }
    return $null
}

# Initial persisted state. Interrupted workers are resumable, never falsely displayed as active.
foreach ($item in @(Get-UhmQueueItems | Where-Object { $_.status -in @('starting','connecting','downloading','preparingInstall','canceling') })) {
    Set-UhmQueueState -Id ([string]$item.id) -Changes @{status='failed';error='اجرای قبلی متوقف شد؛ فایل ناقص برای Resume نگه‌داری شده است.'}|Out-Null
}
$script:settings = Get-UhmSettings -DetectSteam
$script:catalogResult = Get-UhmCatalog
$script:steamStatus = Get-UhmSteamStatus

# Filter data.
$categories = @([pscustomobject]@{id='all';name='همه دسته‌ها'}) + @(
    'cars','tracks','skins','graphics','packs','apps','sounds','weather','ppfilters','miscellaneous' | ForEach-Object { [pscustomobject]@{id=$_;name=(Get-UhmNativeCategoryName $_)} }
)
$categoryFilter = Get-UhmNativeControl 'CategoryFilter'; $categoryFilter.ItemsSource=$categories; $categoryFilter.DisplayMemberPath='name'; $categoryFilter.SelectedValuePath='id'; $categoryFilter.SelectedValue='all'
$sortItems = @([pscustomobject]@{id='newest';name='جدیدترین'},[pscustomobject]@{id='popular';name='محبوب‌ترین'},[pscustomobject]@{id='name';name='نام'},[pscustomobject]@{id='size';name='حجم'},[pscustomobject]@{id='updated';name='آخرین به‌روزرسانی'})
$sortFilter = Get-UhmNativeControl 'SortFilter'; $sortFilter.ItemsSource=$sortItems; $sortFilter.DisplayMemberPath='name'; $sortFilter.SelectedValuePath='id'; $sortFilter.SelectedValue='newest'
$versionItems = @([pscustomobject]@{id='all';name='همه نسخه‌ها'}) + @($script:catalogResult.catalog.mods | Where-Object enabled | Select-Object -ExpandProperty version -Unique | Sort-Object | ForEach-Object { [pscustomobject]@{id=[string]$_;name=('نسخه ' + [string]$_)} })
$versionFilter = Get-UhmNativeControl 'VersionFilter'; $versionFilter.ItemsSource=$versionItems; $versionFilter.DisplayMemberPath='name'; $versionFilter.SelectedValuePath='id'; $versionFilter.SelectedValue='all'
$cspItems = @([pscustomobject]@{id='all';name='همه وضعیت‌های CSP'},[pscustomobject]@{id='yes';name='نیازمند CSP'},[pscustomobject]@{id='no';name='بدون نیاز به CSP'})
$cspFilter = Get-UhmNativeControl 'CspFilter'; $cspFilter.ItemsSource=$cspItems; $cspFilter.DisplayMemberPath='name'; $cspFilter.SelectedValuePath='id'; $cspFilter.SelectedValue='all'
$passwordItems = @([pscustomobject]@{id='all';name='همه آرشیوها'},[pscustomobject]@{id='yes';name='آرشیو رمزدار'},[pscustomobject]@{id='no';name='بدون رمز'})
$passwordFilter = Get-UhmNativeControl 'PasswordFilter'; $passwordFilter.ItemsSource=$passwordItems; $passwordFilter.DisplayMemberPath='name'; $passwordFilter.SelectedValuePath='id'; $passwordFilter.SelectedValue='all'
$installedItems = @([pscustomobject]@{id='all';name='همه مودها'},[pscustomobject]@{id='yes';name='فقط نصب‌شده'},[pscustomobject]@{id='no';name='فقط نصب‌نشده'})
$installedFilter = Get-UhmNativeControl 'InstalledFilter'; $installedFilter.ItemsSource=$installedItems; $installedFilter.DisplayMemberPath='name'; $installedFilter.SelectedValuePath='id'; $installedFilter.SelectedValue='all'

# Window and navigation events.
(Get-UhmNativeControl 'BtnClose').Add_Click({ $window.Close() })
(Get-UhmNativeControl 'BtnMinimize').Add_Click({ $window.WindowState = [Windows.WindowState]::Minimized })
(Get-UhmNativeControl 'TitleBar').Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($eventArgs.ClickCount -eq 2) {
        if ($window.WindowState -eq [Windows.WindowState]::Maximized) { $window.WindowState = [Windows.WindowState]::Normal } else { $window.WindowState = [Windows.WindowState]::Maximized }
    } else { try { $window.DragMove() } catch {} }
})
foreach ($page in @('Dashboard','Catalog','Queue','Installed','Settings')) { $pageCopy=$page; (Get-UhmNativeControl ('Nav'+$page)).Add_Click({ Show-UhmNativePage $pageCopy }.GetNewClosure()) }
(Get-UhmNativeControl 'BtnDashboardCatalog').Add_Click({ Show-UhmNativePage 'Catalog' })
(Get-UhmNativeControl 'CatalogSearch').Add_TextChanged({ Update-UhmNativeCatalogView })
(Get-UhmNativeControl 'CategoryFilter').Add_SelectionChanged({ Update-UhmNativeCatalogView })
(Get-UhmNativeControl 'SortFilter').Add_SelectionChanged({ Update-UhmNativeCatalogView })
foreach ($filterName in @('VersionFilter','CspFilter','PasswordFilter','InstalledFilter')) { (Get-UhmNativeControl $filterName).Add_SelectionChanged({ Update-UhmNativeCatalogView }) }
(Get-UhmNativeControl 'GlobalSearch').Add_TextChanged({ $text=[string](Get-UhmNativeControl 'GlobalSearch').Text; if ((Get-UhmNativeControl 'CatalogSearch').Text -ne $text) { (Get-UhmNativeControl 'CatalogSearch').Text=$text }; if (-not [string]::IsNullOrWhiteSpace($text)) { Show-UhmNativePage 'Catalog' } })
(Get-UhmNativeControl 'BtnRefresh').Add_Click({ Start-UhmNativeCatalogRefresh })
(Get-UhmNativeControl 'BtnCloseDetails').Add_Click({ (Get-UhmNativeControl 'DetailsOverlay').Visibility=[Windows.Visibility]::Collapsed })
(Get-UhmNativeControl 'BtnDetailDownload').Add_Click({ Add-UhmNativeQueueItem $false })
(Get-UhmNativeControl 'BtnDetailInstall').Add_Click({ Add-UhmNativeQueueItem $true })
(Get-UhmNativeControl 'BtnOfficialPage').Add_Click({ if ($null -ne $script:selectedMod -and (Test-UhmHttpsUrl ([string]$script:selectedMod.pageUrl))) { Start-Process ([string]$script:selectedMod.pageUrl) } })

# Routed clicks from data templates.
$window.AddHandler([Windows.Controls.Button]::ClickEvent, [Windows.RoutedEventHandler]{
    param($sender,$eventArgs)
    $button = Get-UhmNativeButtonAncestor $eventArgs.OriginalSource
    if ($null -eq $button -or [string]::IsNullOrWhiteSpace([string]$button.Tag)) { return }
    $id = [string]$button.Tag
    switch ([string]$button.Name) {
        'CatalogOpenButton' { Show-UhmNativeModDetails $id }
        'QueuePrimaryButton' { Invoke-UhmNativeQueuePrimary $id }
        'QueueCancelButton' { Invoke-UhmNativeQueueCancel $id }
        'QueueRemoveButton' { Invoke-UhmNativeQueueRemove $id }
    }
})

# Settings and diagnostics events.
(Get-UhmNativeControl 'BtnBrowseGame').Add_Click({ $path=Select-UhmNativeFolder 'پوشه اصلی Assetto Corsa را انتخاب کنید.'; if ($path) { (Get-UhmNativeControl 'NewPathValue').Text=$path } })
(Get-UhmNativeControl 'BtnBrowseDownloads').Add_Click({ $path=Select-UhmNativeFolder 'پوشه دانلود UHM را انتخاب کنید.'; if ($path) { (Get-UhmNativeControl 'DownloadDirectory').Text=$path } })
(Get-UhmNativeControl 'BtnAddPath').Add_Click({
    try { $script:settings=Add-UhmGamePath -Settings $script:settings -Path ([string](Get-UhmNativeControl 'NewPathValue').Text) -Name ([string](Get-UhmNativeControl 'NewPathName').Text); Update-UhmNativeSettingsView; Update-UhmNativeDashboard; Set-UhmNativeStatus 'مسیر معتبر اضافه شد.' 'success' }
    catch { Show-UhmNativeMessage $_.Exception.Message 'مسیر نامعتبر' 'Error' }
})
(Get-UhmNativeControl 'BtnRemovePath').Add_Click({
    $id=[string](Get-UhmNativeControl 'SettingsDefaultPath').SelectedValue; if ([string]::IsNullOrWhiteSpace($id)) { return }
    if (Confirm-UhmNativeAction 'مسیر فقط از فهرست UHM حذف شود؟ هیچ فایل بازی حذف نخواهد شد.' 'حذف مسیر') { $script:settings=Remove-UhmGamePath -Settings $script:settings -Id $id; Update-UhmNativeSettingsView; Update-UhmNativeDashboard }
})
(Get-UhmNativeControl 'BtnSaveSettings').Add_Click({
    try {
        $selectedPath=[string](Get-UhmNativeControl 'SettingsDefaultPath').SelectedValue; if (-not [string]::IsNullOrWhiteSpace($selectedPath)) { $script:settings.defaultGamePathId=$selectedPath }
        $directory=[IO.Path]::GetFullPath([string](Get-UhmNativeControl 'DownloadDirectory').Text); if (-not (Test-Path -LiteralPath $directory -PathType Container)) { New-Item -ItemType Directory -Path $directory -Force|Out-Null }; $script:settings.downloadDirectory=$directory
        $selectedMax=(Get-UhmNativeControl 'MaxDownloads').SelectedItem; $script:settings.maxConcurrentDownloads=[int]$selectedMax.Content; $script:settings.cacheEnabled=[bool](Get-UhmNativeControl 'CacheEnabled').IsChecked
        Save-UhmSettings $script:settings; Set-UhmNativeStatus 'تنظیمات ذخیره شد.' 'success'; Update-UhmNativeSettingsView
    } catch { Show-UhmNativeMessage $_.Exception.Message 'خطای تنظیمات' 'Error' }
})
(Get-UhmNativeControl 'BtnTestSteam').Add_Click({ $script:steamStatus=Get-UhmSteamStatus; Update-UhmNativeDashboard; Show-UhmNativeMessage $(if ($script:steamStatus.steamFound) { ('Steam و {0} Library شناسایی شد.' -f (ConvertTo-UhmFaNumber @($script:steamStatus.libraries).Count)) } else { 'Steam پیدا نشد؛ می‌توانید مسیر بازی را دستی اضافه کنید.' }) 'تست Steam' $(if ($script:steamStatus.steamFound){'Info'}else{'Warning'}) })
(Get-UhmNativeControl 'BtnTest7Zip').Add_Click({ $path=Find-Uhm7Zip; (Get-UhmNativeControl 'Health7Zip').Text=if($path){'شناسایی شد'}else{'پیدا نشد'}; (Get-UhmNativeControl 'Health7Zip').Foreground=$script:brushConverter.ConvertFromString($(if($path){'#50E395'}else{'#FF9F43'})); Show-UhmNativeMessage $(if($path){'7-Zip پیدا شد: '+$path}else{'7-Zip نصب نیست؛ نصب خودکار انجام نمی‌شود.'}) 'تست 7-Zip' $(if($path){'Info'}else{'Warning'}) })
(Get-UhmNativeControl 'BtnRunDiagnostics').Add_Click({ (Get-UhmNativeControl 'BtnTestSteam').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))); (Get-UhmNativeControl 'BtnTest7Zip').RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Button]::ClickEvent))) })
(Get-UhmNativeControl 'BtnClearCache').Add_Click({ if(Confirm-UhmNativeAction 'Cache کاتالوگ و تصاویر پاک شود؟ فایل بازی و دانلود حذف نمی‌شود.' 'پاک‌کردن Cache'){ foreach($candidate in @((Join-Path $script:UhmProjectRoot 'data\cache\catalog.json'),(Join-Path $script:UhmProjectRoot 'data\cache\images'))){if(Test-Path -LiteralPath $candidate){Remove-Item -LiteralPath $candidate -Recurse -Force}}; Set-UhmNativeStatus 'Cache با تأیید کاربر پاک شد.' 'success' } })

# Timer drives worker maintenance and UI state without blocking downloads.
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(750)
$timer.Add_Tick({
    if ($script:isClosing) { return }
    try { Start-UhmNativePendingWorkers; Update-UhmNativeQueueView; Complete-UhmNativeCatalogRefresh }
    catch { Set-UhmNativeStatus ('خطای پس‌زمینه: ' + $_.Exception.Message) 'error' }
})
$timer.Start()

$window.Add_Closing({
    param($sender, $eventArgs)
    $script:isClosing=$true
    $timer.Stop()
    if ($script:workers.Count -gt 0 -and -not (Confirm-UhmNativeAction 'دانلود فعال وجود دارد. با خروج، Worker متوقف ولی فایل ناقص نگه‌داری می‌شود. خارج شوید؟' 'خروج از UHM')) { $eventArgs.Cancel=$true; $script:isClosing=$false; $timer.Start(); return }
    Stop-UhmNativeWorkers
    if ($null -ne $script:refreshPowerShell) { try { $script:refreshPowerShell.Stop() } catch {}; $script:refreshPowerShell.Dispose() }
    Write-UhmLog -Event 'launcher.native.stop' -Data @{}
})

Update-UhmNativeSettingsView
Update-UhmNativeCatalogView
Update-UhmNativeDashboard
Update-UhmNativeQueueView -Force
Update-UhmNativeInstalledView
Show-UhmNativePage 'Dashboard'
Set-UhmNativeStatus 'رابط Native آماده است.' 'success'
[void]$window.ShowDialog()
