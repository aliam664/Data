[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:UhmProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:CatalogPath = Join-Path $PSScriptRoot 'catalog.json'
$script:CategoriesPath = Join-Path $PSScriptRoot 'categories.json'
$script:PendingImages = @()
$script:CurrentCatalog = $null
$script:Controls = @{}
$script:Closing = $false

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or [Environment]::OSVersion.Version.Major -lt 10) { throw 'مدیریت کاتالوگ فقط روی Windows 10 و Windows 11 اجرا می‌شود.' }
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne [Threading.ApartmentState]::STA) { throw 'برنامه باید با فایل UHM-Catalog-Manager.cmd و PowerShell -STA اجرا شود.' }

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Xaml
Add-Type -AssemblyName System.Windows.Forms

foreach ($module in @('Logger.ps1','Security.ps1','CatalogClient.ps1')) { . (Join-Path $script:UhmProjectRoot ('core\' + $module)) }

$singleInstance = New-Object Threading.Mutex($false, 'Local\UHM-Catalog-Manager')
$ownsSingleInstance = $false
try { $ownsSingleInstance = $singleInstance.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsSingleInstance = $true }
if (-not $ownsSingleInstance) {
    [void][Windows.MessageBox]::Show('یک پنجره مدیریت کاتالوگ از قبل باز است.', 'UHM Catalog Manager', [Windows.MessageBoxButton]::OK, [Windows.MessageBoxImage]::Information)
    $singleInstance.Dispose()
    exit 4
}

$xamlPath = Join-Path $PSScriptRoot 'CatalogManager.xaml'
[xml]$xaml = [IO.File]::ReadAllText($xamlPath, [Text.Encoding]::UTF8)
$reader = New-Object Xml.XmlNodeReader($xaml)
try { $window = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Dispose() }
foreach ($match in [regex]::Matches([IO.File]::ReadAllText($xamlPath), 'x:Name="([A-Za-z0-9_]+)"')) {
    $name = $match.Groups[1].Value; $control = $window.FindName($name); if ($null -ne $control) { $script:Controls[$name] = $control }
}

function Get-UhmCatalogControl {
    param([string]$Name)
    return $script:Controls[$Name]
}

function Set-UhmCatalogStatus {
    param([string]$Text, [ValidateSet('normal','success','warning','error')][string]$Kind='normal')
    $colors=@{normal='#8D9AA8';success='#51E49A';warning='#FFA34B';error='#FF5D68'}
    (Get-UhmCatalogControl 'FooterStatus').Text=$Text
    (Get-UhmCatalogControl 'ValidationStatus').Text=$Text
    (Get-UhmCatalogControl 'ValidationStatus').Foreground=(New-Object Windows.Media.BrushConverter).ConvertFromString($colors[$Kind])
}

function Show-UhmCatalogMessage {
    param([string]$Text,[string]$Title='UHM Catalog Manager',[ValidateSet('Info','Warning','Error')][string]$Kind='Info')
    $icon = switch ($Kind) {
        'Warning' { [Windows.MessageBoxImage]::Warning }
        'Error' { [Windows.MessageBoxImage]::Error }
        default { [Windows.MessageBoxImage]::Information }
    }
    [void][Windows.MessageBox]::Show($window,$Text,$Title,[Windows.MessageBoxButton]::OK,$icon)
}

function Confirm-UhmCatalogAction {
    param([string]$Text, [string]$Title='تأیید')
    return [Windows.MessageBox]::Show($window,$Text,$Title,[Windows.MessageBoxButton]::YesNo,[Windows.MessageBoxImage]::Warning) -eq [Windows.MessageBoxResult]::Yes
}

function Set-UhmCatalogBusy {
    param([bool]$Visible,[string]$Text='در حال پردازش…')
    (Get-UhmCatalogControl 'BusyText').Text = $Text
    $overlay = Get-UhmCatalogControl 'BusyOverlay'
    if ($Visible) { $overlay.Visibility = [Windows.Visibility]::Visible } else { $overlay.Visibility = [Windows.Visibility]::Collapsed }
    if ($Visible) { [System.Windows.Forms.Application]::DoEvents() }
}

function ConvertTo-UhmSlug {
    param([string]$Value)
    $slug=([string]$Value).ToLowerInvariant().Trim()
    $slug=[regex]::Replace($slug,'[^a-z0-9._-]+','-')
    $slug=[regex]::Replace($slug,'-{2,}','-').Trim('-','_','.')
    if($slug.Length -lt 3){$slug='mod-'+[Guid]::NewGuid().ToString('N').Substring(0,10)}
    if($slug.Length -gt 80){$slug=$slug.Substring(0,80).TrimEnd('-')}
    return $slug
}

function Format-UhmCatalogBytes {
    param([long]$Bytes)
    if ($Bytes -le 0) { return '0 B' }
    $units = @('B','KB','MB','GB','TB')
    $index = 0
    $value = [double]$Bytes
    while ($value -ge 1024 -and $index -lt ($units.Count - 1)) { $value /= 1024; $index++ }
    return ('{0} {1}' -f [Math]::Round($value,1),$units[$index])
}

function Get-UhmTextLines {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    return @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Get-UhmNextCatalogVersion {
    param([string]$Current)
    $prefix=[DateTime]::UtcNow.ToString('yyyy.MM.dd');$match=[regex]::Match([string]$Current,('^'+[regex]::Escape($prefix)+'\.(\d+)$'))
    if($match.Success){return $prefix+'.'+([int]$match.Groups[1].Value+1)}
    return $prefix+'.1'
}

function Update-UhmExistingList {
    $query=([string](Get-UhmCatalogControl 'ExistingSearch').Text).Trim().ToLowerInvariant()
    $items=@($script:CurrentCatalog.mods|Where-Object{[string]::IsNullOrWhiteSpace($query)-or(('{0} {1} {2}'-f$_.id,$_.name,$_.nameFa).ToLowerInvariant().Contains($query))}|Sort-Object nameFa|ForEach-Object{[pscustomobject]@{id=[string]$_.id;display=('{0} · v{1}'-f$_.nameFa,$_.version);shortCategory=([string]$_.category).Substring(0,[Math]::Min(2,([string]$_.category).Length)).ToUpperInvariant()}})
    (Get-UhmCatalogControl 'ExistingMods').ItemsSource=$items
    (Get-UhmCatalogControl 'HeaderCatalogVersion').Text=('Catalog '+[string]$script:CurrentCatalog.catalogVersion+' · '+$items.Count+' mods')
}

function Set-UhmComboItems {
    param([string]$Name,$Items,$Selected)
    $combo=Get-UhmCatalogControl $Name;$combo.ItemsSource=@($Items);$combo.SelectedItem=$Selected
}

function Reset-UhmCatalogForm {
    $script:PendingImages=@()
    foreach($name in @('ModName','ModNameFa','ModId','Author','ShortDescription','Description','PageUrl','DownloadUrl','SizeBytes','SizeText','Sha256','MinCspVersion','Dependencies','InstallInstructions','ActivationSteps','ImageUrl','GalleryUrls','JsonPreview')){(Get-UhmCatalogControl $name).Text=''}
    (Get-UhmCatalogControl 'ArchivePassword').Password=''
    (Get-UhmCatalogControl 'Version').Text='1.0.0';(Get-UhmCatalogControl 'ReleaseDate').Text=[DateTime]::UtcNow.ToString('yyyy-MM-dd')
    (Get-UhmCatalogControl 'Popularity').Text='0';(Get-UhmCatalogControl 'CatalogVersion').Text=Get-UhmNextCatalogVersion([string]$script:CurrentCatalog.catalogVersion)
    (Get-UhmCatalogControl 'ImageBaseUrl').Text='https://raw.githubusercontent.com/aliam664/Data/main/images'
    (Get-UhmCatalogControl 'Category').SelectedValue='cars';(Get-UhmCatalogControl 'ArchiveType').SelectedItem='zip';(Get-UhmCatalogControl 'InstallType').SelectedValue='content';(Get-UhmCatalogControl 'InstallRoot').Text='content/cars'
    (Get-UhmCatalogControl 'PureCompatibility').SelectedItem='unknown';(Get-UhmCatalogControl 'SolCompatibility').SelectedItem='unknown';(Get-UhmCatalogControl 'CmCompatibility').SelectedItem='recommended'
    foreach($name in @('PasswordRequired','RequiresCsp','CspPreviewRequired','BlockInstall','Featured','Verified','ConfirmRights')){(Get-UhmCatalogControl $name).IsChecked=$false}
    (Get-UhmCatalogControl 'Enabled').IsChecked=$true;(Get-UhmCatalogControl 'ImagePreview').Source=$null
    (Get-UhmCatalogControl 'ArchiveLocalStatus').Text='فایل مود در GitHub کپی نمی‌شود';(Get-UhmCatalogControl 'LinkTestStatus').Text='تست نشده';(Get-UhmCatalogControl 'FormModeBadge').Text='NEW RECORD';(Get-UhmCatalogControl 'EditorTabs').SelectedIndex=0
    Set-UhmCatalogStatus 'فرم جدید آماده است.'
}

function New-UhmUniqueId {
    $base = ConvertTo-UhmSlug ([string](Get-UhmCatalogControl 'ModName').Text)
    $candidate = $base
    $index = 2
    $ids = @($script:CurrentCatalog.mods | ForEach-Object { [string]$_.id })
    while ($ids -contains $candidate) { $candidate = $base + '-' + $index; $index++ }
    (Get-UhmCatalogControl 'ModId').Text = $candidate
}

function Get-UhmCatalogFormRecord {
    $size = 0L
    if (-not [long]::TryParse(([string](Get-UhmCatalogControl 'SizeBytes').Text).Trim(),[ref]$size) -or $size -lt 0) { throw 'حجم دقیق فایل باید عدد صحیح نامنفی باشد.' }
    $popularity = 0
    if (-not [int]::TryParse(([string](Get-UhmCatalogControl 'Popularity').Text).Trim(),[ref]$popularity) -or $popularity -lt 0 -or $popularity -gt 100) { throw 'محبوبیت باید عددی بین ۰ تا ۱۰۰ باشد.' }
    $passwordRequired = [bool](Get-UhmCatalogControl 'PasswordRequired').IsChecked
    $requiresCsp = [bool](Get-UhmCatalogControl 'RequiresCsp').IsChecked

    return [pscustomobject][ordered]@{
        id = ([string](Get-UhmCatalogControl 'ModId').Text).Trim()
        name = ([string](Get-UhmCatalogControl 'ModName').Text).Trim()
        nameFa = ([string](Get-UhmCatalogControl 'ModNameFa').Text).Trim()
        category = [string](Get-UhmCatalogControl 'Category').SelectedValue
        description = ([string](Get-UhmCatalogControl 'Description').Text).Trim()
        shortDescription = ([string](Get-UhmCatalogControl 'ShortDescription').Text).Trim()
        author = ([string](Get-UhmCatalogControl 'Author').Text).Trim()
        version = ([string](Get-UhmCatalogControl 'Version').Text).Trim()
        releaseDate = ([string](Get-UhmCatalogControl 'ReleaseDate').Text).Trim()
        updatedAt = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
        image = ([string](Get-UhmCatalogControl 'ImageUrl').Text).Trim()
        gallery = @(Get-UhmTextLines ([string](Get-UhmCatalogControl 'GalleryUrls').Text))
        pageUrl = ([string](Get-UhmCatalogControl 'PageUrl').Text).Trim()
        downloadUrl = ([string](Get-UhmCatalogControl 'DownloadUrl').Text).Trim()
        archiveType = [string](Get-UhmCatalogControl 'ArchiveType').SelectedItem
        sizeBytes = $size
        sizeText = ([string](Get-UhmCatalogControl 'SizeText').Text).Trim()
        sha256 = ([string](Get-UhmCatalogControl 'Sha256').Text).Trim().ToLowerInvariant()
        passwordRequired = $passwordRequired
        password = if ($passwordRequired) { [string](Get-UhmCatalogControl 'ArchivePassword').Password } else { '' }
        requiresCsp = $requiresCsp
        minCspVersion = if ($requiresCsp) { ([string](Get-UhmCatalogControl 'MinCspVersion').Text).Trim() } else { '' }
        cspPreviewRequired = [bool](Get-UhmCatalogControl 'CspPreviewRequired').IsChecked
        blockInstall = [bool](Get-UhmCatalogControl 'BlockInstall').IsChecked
        compatibility = [pscustomobject][ordered]@{
            pure = [string](Get-UhmCatalogControl 'PureCompatibility').SelectedItem
            sol = [string](Get-UhmCatalogControl 'SolCompatibility').SelectedItem
            contentManager = [string](Get-UhmCatalogControl 'CmCompatibility').SelectedItem
        }
        dependencies = @(Get-UhmTextLines ([string](Get-UhmCatalogControl 'Dependencies').Text))
        installType = [string](Get-UhmCatalogControl 'InstallType').SelectedValue
        installRoot = ([string](Get-UhmCatalogControl 'InstallRoot').Text).Trim()
        installInstructions = @(Get-UhmTextLines ([string](Get-UhmCatalogControl 'InstallInstructions').Text))
        activationSteps = @(Get-UhmTextLines ([string](Get-UhmCatalogControl 'ActivationSteps').Text))
        featured = [bool](Get-UhmCatalogControl 'Featured').IsChecked
        verified = [bool](Get-UhmCatalogControl 'Verified').IsChecked
        enabled = [bool](Get-UhmCatalogControl 'Enabled').IsChecked
        popularity = $popularity
    }
}

function Test-UhmCatalogFormRecord {
    param($Record,[switch]$ForSave)
    $errors = @(Test-UhmModRecord $Record)
    if (@($script:CurrentCatalog.mods | Where-Object { $_.id -eq $Record.id }).Count -gt 0) { $errors += 'شناسه مود از قبل در کاتالوگ وجود دارد.' }
    if ($Record.requiresCsp -and [string]::IsNullOrWhiteSpace($Record.minCspVersion)) { $errors += 'برای مود نیازمند CSP، حداقل نسخه را وارد کنید.' }
    if ([string]::IsNullOrWhiteSpace($Record.sizeText)) { $errors += 'حجم نمایشی فایل خالی است.' }
    if ($ForSave -and -not [bool](Get-UhmCatalogControl 'ConfirmRights').IsChecked) { $errors += 'تأیید مجوز لینک‌ها و تصاویر الزامی است.' }
    $catalogVersion = ([string](Get-UhmCatalogControl 'CatalogVersion').Text).Trim()
    if ([string]::IsNullOrWhiteSpace($catalogVersion)) { $errors += 'نسخه جدید کاتالوگ خالی است.' }
    return @($errors)
}

function Show-UhmJsonPreview {
    try {
        $record = Get-UhmCatalogFormRecord
        $errors = @(Test-UhmCatalogFormRecord $record)
        $clone = ($record | ConvertTo-Json -Depth 15 | ConvertFrom-Json)
        if ($clone.passwordRequired) { $clone.password = '[REDACTED IN PREVIEW]' }
        (Get-UhmCatalogControl 'JsonPreview').Text = $clone | ConvertTo-Json -Depth 15
        if ($errors.Count) { Set-UhmCatalogStatus $errors[0] 'error' }
        else { Set-UhmCatalogStatus 'رکورد معتبر است و آماده ذخیره است.' 'success' }
        (Get-UhmCatalogControl 'EditorTabs').SelectedIndex = 4
    } catch {
        Set-UhmCatalogStatus $_.Exception.Message 'error'
        Show-UhmCatalogMessage $_.Exception.Message 'خطای فرم' 'Error'
    }
}

function Populate-UhmFormFromRecord {
    param($Mod)
    Reset-UhmCatalogForm
    (Get-UhmCatalogControl 'ModName').Text=[string]$Mod.name;(Get-UhmCatalogControl 'ModNameFa').Text=[string]$Mod.nameFa;(Get-UhmCatalogControl 'ModId').Text=(([string]$Mod.id)+'-copy');(Get-UhmCatalogControl 'Author').Text=[string]$Mod.author;(Get-UhmCatalogControl 'Category').SelectedValue=[string]$Mod.category;(Get-UhmCatalogControl 'Version').Text=[string]$Mod.version
    (Get-UhmCatalogControl 'ShortDescription').Text=[string]$Mod.shortDescription;(Get-UhmCatalogControl 'Description').Text=[string]$Mod.description;(Get-UhmCatalogControl 'PageUrl').Text=[string]$Mod.pageUrl;(Get-UhmCatalogControl 'DownloadUrl').Text=[string]$Mod.downloadUrl;(Get-UhmCatalogControl 'ArchiveType').SelectedItem=[string]$Mod.archiveType;(Get-UhmCatalogControl 'SizeBytes').Text=[string]$Mod.sizeBytes;(Get-UhmCatalogControl 'SizeText').Text=[string]$Mod.sizeText;(Get-UhmCatalogControl 'Sha256').Text=[string]$Mod.sha256
    (Get-UhmCatalogControl 'PasswordRequired').IsChecked=[bool]$Mod.passwordRequired;(Get-UhmCatalogControl 'ArchivePassword').Password=[string]$Mod.password;(Get-UhmCatalogControl 'RequiresCsp').IsChecked=[bool]$Mod.requiresCsp;(Get-UhmCatalogControl 'MinCspVersion').Text=[string]$Mod.minCspVersion;(Get-UhmCatalogControl 'CspPreviewRequired').IsChecked=[bool]$Mod.cspPreviewRequired;(Get-UhmCatalogControl 'BlockInstall').IsChecked=$(if($Mod.PSObject.Properties['blockInstall']){[bool]$Mod.blockInstall}else{$false})
    (Get-UhmCatalogControl 'PureCompatibility').SelectedItem=[string]$Mod.compatibility.pure;(Get-UhmCatalogControl 'SolCompatibility').SelectedItem=[string]$Mod.compatibility.sol;(Get-UhmCatalogControl 'CmCompatibility').SelectedItem=[string]$Mod.compatibility.contentManager;(Get-UhmCatalogControl 'InstallType').SelectedValue=[string]$Mod.installType;(Get-UhmCatalogControl 'InstallRoot').Text=[string]$Mod.installRoot
    (Get-UhmCatalogControl 'Dependencies').Text=@($Mod.dependencies)-join[Environment]::NewLine;(Get-UhmCatalogControl 'InstallInstructions').Text=@($Mod.installInstructions)-join[Environment]::NewLine;(Get-UhmCatalogControl 'ActivationSteps').Text=$(if($Mod.PSObject.Properties['activationSteps']){@($Mod.activationSteps)-join[Environment]::NewLine}else{''});(Get-UhmCatalogControl 'ImageUrl').Text=[string]$Mod.image;(Get-UhmCatalogControl 'GalleryUrls').Text=@($Mod.gallery)-join[Environment]::NewLine
    (Get-UhmCatalogControl 'Featured').IsChecked=[bool]$Mod.featured;(Get-UhmCatalogControl 'Verified').IsChecked=[bool]$Mod.verified;(Get-UhmCatalogControl 'Enabled').IsChecked=[bool]$Mod.enabled;(Get-UhmCatalogControl 'Popularity').Text=$(if($Mod.PSObject.Properties['popularity']){[string]$Mod.popularity}else{'0'});(Get-UhmCatalogControl 'FormModeBadge').Text='CLONED TEMPLATE';(Get-UhmCatalogControl 'ConfirmRights').IsChecked=$false
    New-UhmUniqueId
}

function Get-UhmImagePlan {
    param([string]$Source,[int]$Index)
    if ([string]::IsNullOrWhiteSpace([string](Get-UhmCatalogControl 'ModId').Text)) { New-UhmUniqueId }
    $id = ConvertTo-UhmSlug ([string](Get-UhmCatalogControl 'ModId').Text)
    $category = [string](Get-UhmCatalogControl 'Category').SelectedValue
    if ([string]::IsNullOrWhiteSpace($category)) { $category = 'miscellaneous' }
    $extension = [IO.Path]::GetExtension($Source).ToLowerInvariant()
    if (@('.jpg','.jpeg','.png','.webp') -notcontains $extension) { throw 'فرمت تصویر باید JPG، PNG یا WebP باشد.' }
    $suffix = if ($Index -eq 0) { 'cover' } else { 'gallery-' + $Index }
    $fileName = $id + '-' + $suffix + $extension
    $destination = Join-Path $script:UhmProjectRoot ('images\' + $category + '\' + $fileName)
    if (Test-Path -LiteralPath $destination) { throw ('فایل تصویر مقصد از قبل وجود دارد: ' + $destination) }
    $base = ([string](Get-UhmCatalogControl 'ImageBaseUrl').Text).Trim().TrimEnd('/')
    if (-not (Test-UhmHttpsUrl $base)) { throw 'Raw image base URL باید HTTPS معتبر باشد.' }
    return [pscustomobject]@{source=$Source;destination=$destination;url=($base+'/'+$category+'/'+$fileName);index=$Index}
}

function Select-UhmLocalArchive {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Mod archives|*.zip;*.rar;*.7z;*.tar;*.tar.gz|All files|*.*'
    $dialog.Multiselect = $false
    if ($dialog.ShowDialog($window) -ne $true) { return }
    Set-UhmCatalogBusy $true 'در حال محاسبه حجم و SHA-256…'
    try {
        $file = Get-Item -LiteralPath $dialog.FileName
        $type = if ($file.Name.ToLowerInvariant().EndsWith('.tar.gz')) { 'tar.gz' } else { $file.Extension.TrimStart('.').ToLowerInvariant() }
        if (@('zip','rar','7z','tar','tar.gz') -notcontains $type) { throw 'نوع آرشیو انتخاب‌شده پشتیبانی نمی‌شود.' }
        (Get-UhmCatalogControl 'ArchiveType').SelectedItem = $type
        (Get-UhmCatalogControl 'SizeBytes').Text = [string]$file.Length
        (Get-UhmCatalogControl 'SizeText').Text = Format-UhmCatalogBytes $file.Length
        (Get-UhmCatalogControl 'Sha256').Text = Get-UhmFileSha256 $file.FullName
        (Get-UhmCatalogControl 'ArchiveLocalStatus').Text = ('بررسی شد: ' + $file.Name + ' — فایل کپی نمی‌شود')
        Set-UhmCatalogStatus 'حجم و Hash فایل محلی ثبت شد.' 'success'
    } catch { Show-UhmCatalogMessage $_.Exception.Message 'خطای آرشیو' 'Error' }
    finally { Set-UhmCatalogBusy $false }
}

function Select-UhmLocalImages {
    param([switch]$Gallery)
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = 'Images|*.jpg;*.jpeg;*.png;*.webp'
    $dialog.Multiselect = [bool]$Gallery
    if ($dialog.ShowDialog($window) -ne $true) { return }
    try {
        if ($Gallery) {
            $existingIndexes = @($script:PendingImages | ForEach-Object { [int]$_.index })
            $index = if ($existingIndexes.Count) { [int](($existingIndexes | Measure-Object -Maximum).Maximum) + 1 } else { 1 }
            $urls = @(Get-UhmTextLines ([string](Get-UhmCatalogControl 'GalleryUrls').Text))
            foreach ($file in @($dialog.FileNames)) {
                $plan = Get-UhmImagePlan -Source $file -Index $index
                $script:PendingImages += $plan
                $urls += $plan.url
                $index++
            }
            (Get-UhmCatalogControl 'GalleryUrls').Text = $urls -join [Environment]::NewLine
        } else {
            $plan = Get-UhmImagePlan -Source $dialog.FileName -Index 0
            $script:PendingImages = @($script:PendingImages | Where-Object { [int]$_.index -ne 0 }) + $plan
            (Get-UhmCatalogControl 'ImageUrl').Text = $plan.url
            try {
                $bitmap = New-Object Windows.Media.Imaging.BitmapImage
                $bitmap.BeginInit(); $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad; $bitmap.UriSource = [Uri]$plan.source; $bitmap.EndInit(); $bitmap.Freeze()
                (Get-UhmCatalogControl 'ImagePreview').Source = $bitmap
            } catch {
                (Get-UhmCatalogControl 'ImagePreview').Source = $null
                Set-UhmCatalogStatus 'تصویر انتخاب شد، اما Codec پیش‌نمایش این فرمت در WPF موجود نیست.' 'warning'
                return
            }
        }
        Set-UhmCatalogStatus 'تصویر برای کپی هنگام ذخیره آماده شد.' 'success'
    } catch { Show-UhmCatalogMessage $_.Exception.Message 'خطای تصویر' 'Error' }
}

function Test-UhmCatalogHeadUrl {
    param([string]$Url)
    if (-not (Test-UhmHttpsUrl $Url)) { throw 'URL باید HTTPS معتبر باشد.' }
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.Method = 'HEAD'; $request.AllowAutoRedirect = $true; $request.MaximumAutomaticRedirections = 5; $request.Timeout = 8000; $request.UserAgent = 'UHM-Catalog-Manager/0.2'
    $response = $null
    try {
        $response = [Net.HttpWebResponse]$request.GetResponse()
        if ($response.ResponseUri.Scheme -ne 'https') { throw 'Redirect نهایی غیر HTTPS است.' }
        return [pscustomobject]@{code=[int]$response.StatusCode;contentType=[string]$response.ContentType;final=[string]$response.ResponseUri}
    } finally { if ($null -ne $response) { $response.Close() } }
}

function Test-UhmCatalogLinks {
    Set-UhmCatalogBusy $true 'در حال تست لینک‌های HTTPS…'
    try {
        $page = Test-UhmCatalogHeadUrl ([string](Get-UhmCatalogControl 'PageUrl').Text)
        $download = Test-UhmCatalogHeadUrl ([string](Get-UhmCatalogControl 'DownloadUrl').Text)
        $message = ('صفحه: HTTP {0} | دانلود: HTTP {1}' -f $page.code,$download.code)
        if ($download.contentType -match 'text/html') {
            (Get-UhmCatalogControl 'LinkTestStatus').Text = $message + ' — احتمال دانلود دستی'
            Set-UhmCatalogStatus 'لینک دانلود HTML است؛ CAPTCHA/Login را بررسی کنید.' 'warning'
        } else {
            (Get-UhmCatalogControl 'LinkTestStatus').Text = $message
            Set-UhmCatalogStatus 'هر دو لینک HTTPS پاسخ دادند.' 'success'
        }
    } catch {
        (Get-UhmCatalogControl 'LinkTestStatus').Text = 'ناموفق'
        Set-UhmCatalogStatus $_.Exception.Message 'error'
        Show-UhmCatalogMessage $_.Exception.Message 'تست لینک' 'Warning'
    } finally { Set-UhmCatalogBusy $false }
}

function Save-UhmCatalogRecord {
    $record = Get-UhmCatalogFormRecord
    $errors = @(Test-UhmCatalogFormRecord $record -ForSave)
    if ($errors.Count) {
        (Get-UhmCatalogControl 'EditorTabs').SelectedIndex = 4
        (Get-UhmCatalogControl 'JsonPreview').Text = ($errors | ForEach-Object { '• ' + $_ }) -join [Environment]::NewLine
        throw ($errors -join [Environment]::NewLine)
    }

    $candidate = ($script:CurrentCatalog | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    $candidate.mods = @($candidate.mods) + $record
    $candidate.catalogVersion = ([string](Get-UhmCatalogControl 'CatalogVersion').Text).Trim()
    $candidate.generatedAt = [DateTime]::UtcNow.ToString('o')
    $catalogErrors = @(Test-UhmCatalog $candidate)
    if ($catalogErrors.Count) { throw ($catalogErrors -join [Environment]::NewLine) }

    $summaryTemplate = 'مود «{0}» با شناسه {1} اضافه شود؟' + [Environment]::NewLine +
        'نسخه کاتالوگ: {2}' + [Environment]::NewLine +
        'فایل مود داخل Repository کپی نخواهد شد.'
    $summary = $summaryTemplate -f $record.nameFa,$record.id,$candidate.catalogVersion
    if (-not (Confirm-UhmCatalogAction $summary 'تأیید افزودن مود')) { return }

    $saveMutex = New-Object Threading.Mutex($false,'Local\UHM-Catalog-Write')
    $ownsSaveMutex = $false
    try { $ownsSaveMutex = $saveMutex.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $ownsSaveMutex = $true }
    if (-not $ownsSaveMutex) { $saveMutex.Dispose(); throw 'یک عملیات دیگر در حال تغییر کاتالوگ است.' }
    Set-UhmCatalogBusy $true 'در حال ساخت Backup و ذخیره امن…'
    try {
        $backupRoot = Join-Path $script:UhmProjectRoot 'data\cache\catalog-backups'
        if (-not (Test-Path -LiteralPath $backupRoot)) { New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null }
        $backup = Join-Path $backupRoot ('catalog-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '.json')
        Copy-Item -LiteralPath $script:CatalogPath -Destination $backup

        $imageCount = @($script:PendingImages).Count
        # Preflight every source and destination before copying the first image.
        foreach ($image in @($script:PendingImages)) {
            if (-not (Test-Path -LiteralPath $image.source -PathType Leaf)) { throw ('تصویر منبع پیدا نشد: ' + $image.source) }
            if (Test-Path -LiteralPath $image.destination) { throw ('تصویر مقصد موجود است و جایگزین نمی‌شود: ' + $image.destination) }
        }
        foreach ($image in @($script:PendingImages)) {
            $parent = Split-Path -Parent $image.destination
            if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
            Copy-Item -LiteralPath $image.source -Destination $image.destination
        }

        $temp = $script:CatalogPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        $json = $candidate | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($temp,$json,(New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $temp -Destination $script:CatalogPath -Force

        $script:CurrentCatalog = Read-UhmCatalogFile $script:CatalogPath
        Update-UhmExistingList
        Write-UhmLog -Event 'catalog.manager.added' -Data @{mod=$record.id;version=$candidate.catalogVersion;imageCount=$imageCount}
        Show-UhmCatalogMessage ('مود با موفقیت اضافه شد.' + [Environment]::NewLine + 'Backup: ' + $backup) 'ذخیره موفق' 'Info'
        Reset-UhmCatalogForm
        Set-UhmCatalogStatus 'مود جدید با موفقیت به catalog.json اضافه شد.' 'success'
    } finally {
        try { $saveMutex.ReleaseMutex() } catch {}
        $saveMutex.Dispose()
        Set-UhmCatalogBusy $false
    }
}

# Load and populate fixed data.
$script:CurrentCatalog=Read-UhmCatalogFile $script:CatalogPath
$categoryData=[IO.File]::ReadAllText($script:CategoriesPath,[Text.Encoding]::UTF8)|ConvertFrom-Json
(Get-UhmCatalogControl 'Category').ItemsSource=@($categoryData.categories);(Get-UhmCatalogControl 'ArchiveType').ItemsSource=@('zip','rar','7z','tar','tar.gz')
(Get-UhmCatalogControl 'InstallType').ItemsSource=@([pscustomobject]@{id='content';name='محتوای بازی'},[pscustomobject]@{id='graphics';name='پک گرافیکی'},[pscustomobject]@{id='pack';name='پک چندبخشی'},[pscustomobject]@{id='root';name='ساختار ریشه'})
$compatibility=@('compatible','incompatible','required','recommended','unknown');foreach($name in@('PureCompatibility','SolCompatibility','CmCompatibility')){(Get-UhmCatalogControl $name).ItemsSource=$compatibility}
Update-UhmExistingList;Reset-UhmCatalogForm

# Window behavior.
(Get-UhmCatalogControl 'BtnClose').Add_Click({ $window.Close() })
(Get-UhmCatalogControl 'BtnMinimize').Add_Click({ $window.WindowState = [Windows.WindowState]::Minimized })
(Get-UhmCatalogControl 'BtnMaximize').Add_Click({
    if ($window.WindowState -eq [Windows.WindowState]::Maximized) { $window.WindowState = [Windows.WindowState]::Normal }
    else { $window.WindowState = [Windows.WindowState]::Maximized }
})
(Get-UhmCatalogControl 'TitleBar').Add_MouseLeftButtonDown({
    param($sender,$eventArgs)
    if ($eventArgs.ClickCount -eq 2) {
        if ($window.WindowState -eq [Windows.WindowState]::Maximized) { $window.WindowState = [Windows.WindowState]::Normal }
        else { $window.WindowState = [Windows.WindowState]::Maximized }
    } else { try { $window.DragMove() } catch {} }
})
$window.Dispatcher.add_UnhandledException({
    param($sender,$eventArgs)
    try {
        Write-UhmLog -Level ERROR -Event 'catalog.manager.ui_error' -Data @{error=$eventArgs.Exception.Message}
        $eventArgs.Handled = $true
        Show-UhmCatalogMessage $eventArgs.Exception.Message 'خطای کنترل‌شده رابط' 'Error'
    } catch { $eventArgs.Handled = $true }
})

# Form events.
(Get-UhmCatalogControl 'ExistingSearch').Add_TextChanged({ Update-UhmExistingList })
(Get-UhmCatalogControl 'BtnReset').Add_Click({ Reset-UhmCatalogForm })
(Get-UhmCatalogControl 'BtnGenerateId').Add_Click({ New-UhmUniqueId })
(Get-UhmCatalogControl 'ModName').Add_LostFocus({ if ([string]::IsNullOrWhiteSpace([string](Get-UhmCatalogControl 'ModId').Text)) { New-UhmUniqueId } })
(Get-UhmCatalogControl 'BtnClone').Add_Click({
    $selected = (Get-UhmCatalogControl 'ExistingMods').SelectedItem
    if ($null -eq $selected) { Show-UhmCatalogMessage 'ابتدا یک مود را انتخاب کنید.' 'ساخت Template' 'Warning'; return }
    $mod = $script:CurrentCatalog.mods | Where-Object {$_.id -eq $selected.id} | Select-Object -First 1
    if ($null -ne $mod) { Populate-UhmFormFromRecord $mod }
})
(Get-UhmCatalogControl 'BtnPickArchive').Add_Click({ Select-UhmLocalArchive })
(Get-UhmCatalogControl 'BtnPickImage').Add_Click({ Select-UhmLocalImages })
(Get-UhmCatalogControl 'BtnPickGallery').Add_Click({ Select-UhmLocalImages -Gallery })
(Get-UhmCatalogControl 'BtnTestLinks').Add_Click({ Test-UhmCatalogLinks })
(Get-UhmCatalogControl 'BtnBuildPreview').Add_Click({ Show-UhmJsonPreview })
(Get-UhmCatalogControl 'BtnValidate').Add_Click({ Show-UhmJsonPreview })
(Get-UhmCatalogControl 'BtnSave').Add_Click({
    try { Save-UhmCatalogRecord }
    catch {
        Set-UhmCatalogBusy $false
        Set-UhmCatalogStatus $_.Exception.Message 'error'
        Show-UhmCatalogMessage $_.Exception.Message 'ذخیره انجام نشد' 'Error'
    }
})
(Get-UhmCatalogControl 'Category').Add_SelectionChanged({
    $category = [string](Get-UhmCatalogControl 'Category').SelectedValue
    if ($category -eq 'cars') { (Get-UhmCatalogControl 'InstallRoot').Text = 'content/cars' }
    elseif ($category -eq 'tracks') { (Get-UhmCatalogControl 'InstallRoot').Text = 'content/tracks' }
    elseif ($category -eq 'apps') { (Get-UhmCatalogControl 'InstallRoot').Text = 'apps/lua' }
})
(Get-UhmCatalogControl 'PasswordRequired').Add_Checked({ (Get-UhmCatalogControl 'ArchivePassword').IsEnabled = $true })
(Get-UhmCatalogControl 'PasswordRequired').Add_Unchecked({ (Get-UhmCatalogControl 'ArchivePassword').IsEnabled = $false; (Get-UhmCatalogControl 'ArchivePassword').Password = '' })
(Get-UhmCatalogControl 'RequiresCsp').Add_Checked({ (Get-UhmCatalogControl 'MinCspVersion').IsEnabled = $true })
(Get-UhmCatalogControl 'RequiresCsp').Add_Unchecked({
    (Get-UhmCatalogControl 'MinCspVersion').IsEnabled = $false
    (Get-UhmCatalogControl 'MinCspVersion').Text = ''
    (Get-UhmCatalogControl 'CspPreviewRequired').IsChecked = $false
    (Get-UhmCatalogControl 'BlockInstall').IsChecked = $false
})
$window.Add_Closing({
    $script:Closing = $true
    try { $singleInstance.ReleaseMutex() } catch {}
    $singleInstance.Dispose()
})

(Get-UhmCatalogControl 'ArchivePassword').IsEnabled = $false
(Get-UhmCatalogControl 'MinCspVersion').IsEnabled = $false
Set-UhmCatalogStatus 'مدیریت کاتالوگ آماده است.' 'success'
[void]$window.ShowDialog()
