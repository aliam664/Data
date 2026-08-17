# معماری رابط Native UHM Launcher

## انتخاب فناوری

رابط پیش‌فرض نسخه ۰.۲ با **Windows Presentation Foundation (WPF)** و **XAML** ساخته شده است. WPF بخشی از پلتفرم Desktop ویندوز است و برای Window، Control، Layout، Style، Template، Binding، Graphics و Animation طراحی شده است.

این انتخاب با محدودیت‌های UHM سازگار است:

- ورودی اصلی همچنان `UHM-Launcher.cmd` است؛
- فایل EXE اختصاصی تولید نمی‌شود؛
- Windows PowerShell 5.1 و Assemblyهای داخلی WPF استفاده می‌شوند؛
- رابط در پنجره Native اجرا می‌شود، نه Browser؛
- کلیک‌ها مستقیماً توابع PowerShell امن را فراخوانی می‌کنند؛
- Downloader و Installer موجود دوباره استفاده می‌شوند.

## مقایسه گزینه‌ها

| گزینه | نتیجه |
|---|---|
| WPF + XAML + PowerShell | انتخاب اصلی؛ Native، قابل Style، بدون Build EXE |
| WinForms | قابل اجرا ولی برای طراحی مدرن، Template و Layout ضعیف‌تر از WPF |
| Electron/Tauri/WebView2 | ظاهر خوب، اما معمولاً نیازمند بسته اجرایی/Runtime و مغایر شرط «بدون EXE اختصاصی» |
| Python GUI | نیازمند نصب Python یا بسته‌بندی EXE و وابستگی اضافی |
| HTA/MSHTA | همچنان HTML و از نظر امنیتی/عمر فناوری مناسب انتشار جدید نیست |

## فایل‌ها

- `wpf/MainWindow.xaml`: ظاهر، Styleها، Templateها، Layout و DataTemplateها
- `wpf/UHM-Wpf.ps1`: بارگذاری XAML، Event Handlerها، Queue Workerها و اتصال به هسته
- `UHM-Launcher.cmd`: اجرای PowerShell با `-STA`
- `core/UHM-Core.ps1`: انتخاب رابط Native با Action پیش‌فرض `launch`

رابط HTML قبلی حذف نشده و فقط با Action صریح `launch-web` قابل اجرا است.

## مسیر کلیک تا عملیات

```text
WPF Button Click
  → Event Handler ثابت
  → اعتبارسنجی Mod و Target
  → Queue State/Job
  → PowerShell Worker مخفی
  → Downloader / Extractor / Installer
  → DispatcherTimer
  → ProgressBar و وضعیت فارسی
```

هیچ متن Catalog به‌عنوان Script یا Command اجرا نمی‌شود. Event Handlerها از قبل در کد تعریف شده‌اند و `Invoke-Expression` وجود ندارد.

## سیستم طراحی

- تم Dark Racing با Accent لیمویی، Cyan برای انتقال داده و Green برای وضعیت سالم
- Hero گاراژ، Sidebar گرادیانی، کارت‌های آماری با رنگ وضعیت و Cardهای تصویری کاتالوگ
- Template اختصاصی برای Button، TextBox، ComboBox، ProgressBar، DataGrid و Empty Stateها
- Hover/Focus/Pressed State روشن برای کار با ماوس و صفحه‌کلید
- `fa-IR`، Layout Rounding و Text Formatting برای نمایش واضح فارسی
- فونت داخلی `Segoe UI` ویندوز؛ بدون دانلود فونت، وابستگی شبکه یا ریسک Supply Chain
- پنجره قابل Resize/Maximize با Title Bar اختصاصی و دیالوگ‌های دارای Shadow

## صفحه‌ها

1. Dashboard: Hero، آمار کاتالوگ، نصب، دانلود و سلامت Steam/بازی
2. Catalog: کارت مود، جست‌وجو، فیلتر و مرتب‌سازی
3. Details: توضیح، وابستگی، CSP، مقصد و دکمه دانلود/نصب
4. Queue: Progress، Pause، Resume، Cancel، Retry و Install
5. Installed: Manifest نصب‌ها بدون دکمه حذف
6. Settings: مسیرها، دانلود، Cache، Steam و 7-Zip

## Threading

WPF به Thread از نوع STA نیاز دارد؛ CMD از `powershell.exe -STA` استفاده می‌کند. UI روی Dispatcher اصلی است و دانلود در Processهای Worker جدا اجرا می‌شود. Refresh کاتالوگ نیز در Runspace غیرهم‌زمان انجام می‌شود. ساخت Preview نصب آرشیو در نسخه فعلی هنوز ممکن است برای آرشیو بسیار بزرگ UI را موقتاً مشغول کند و بهتر است در نسخه بعد به Worker دارای Progress منتقل شود.

## تست لازم

تست `tests/Wpf.Tests.ps1` وجود XAML، Action پیش‌فرض، کنترل‌های لازم و Load شدن XAML با Runtime ویندوز را بررسی می‌کند. تست Runtime واقعی فقط روی Windows 10/11 ممکن است و باید پیش از Release عمومی اجرا شود.
