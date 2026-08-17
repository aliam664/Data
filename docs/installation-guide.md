# راهنمای نصب و رفتار هسته

## اجرای برنامه

فقط `UHM-Launcher.cmd` را اجرا کنید. CMD وجود PowerShell 5.1 و Windows 10/11 را بررسی و PowerShell را با `-STA` اجرا می‌کند. Core فایل `wpf/MainWindow.xaml` را با WPF بارگذاری و رویدادهای کلیک را به Queue، Downloader و Installer متصل می‌کند. در اجرای پیش‌فرض مرورگر، پورت محلی یا Token وجود ندارد.

حالت HTML قدیمی حذف نشده است و توسعه‌دهنده می‌تواند آن را با `core/UHM-Core.ps1 -Action launch-web` اجرا کند؛ این حالت ورودی عمومی نسخه ۰.۲ نیست.

## کشف بازی

`SteamDetector.ps1` کلیدهای Registry کاربر/ماشین، `libraryfolders.vdf` مدرن و Legacy و مسیر `steamapps/common/assettocorsa` را بررسی می‌کند. یک مسیر فقط وقتی معتبر است که این چهار مورد وجود داشته باشند:

- `AssettoCorsa.exe`
- `content/`
- `content/cars/`
- `content/tracks/`

همه مسیرها نمایش داده می‌شوند. انتخاب Default فقط تنظیم UHM را تغییر می‌دهد. حذف مسیر از فهرست هیچ فایل یا Library Steam را حذف نمی‌کند.

## چرخه دانلود

1. URL باید HTTPS، بدون UserInfo و دارای Host معتبر باشد.
2. Redirect خودکار حداکثر پنج مرحله و مقصد نهایی فقط HTTPS است.
3. فایل در `<destination>.part` نوشته می‌شود.
4. Pause خواندن Stream را متوقف می‌کند؛ Cancel پردازش را پایان می‌دهد ولی `.part` را نگه می‌دارد.
5. Retry اندازه `.part` را می‌خواند و Header `Range: bytes=<offset>-` می‌فرستد.
6. اگر سرور `206 Partial Content` ندهد، فایل ناقص خودکار truncate/delete نمی‌شود؛ شروع مجدد به تأیید حذف نیاز دارد.
7. پاسخ HTML به‌عنوان Login/CAPTCHA/صفحه واسط تشخیص داده می‌شود.
8. Content-Length، حجم کاتالوگ و SHA-256 در صورت وجود کنترل می‌شوند.
9. `.part` فقط پس از تکمیل به نام نهایی Move می‌شود.

Pause در حافظه همان Process است. خروج Launcher Process دانلود را متوقف می‌کند و Resume در اجرای بعد با Range انجام می‌شود. سروری که Range ندارد Resume واقعی ارائه نمی‌دهد.

## استخراج

- ZIP بدون رمز با `System.IO.Compression` و استخراج Entry-by-Entry انجام می‌شود.
- RAR/7Z/ZIP رمزدار با 7-Zip رسمی استخراج می‌شود.
- TAR/TAR.GZ از `tar.exe` داخلی Windows 10/11 استفاده می‌کند.
- پیش از استخراج، Entry مطلق، Drive، `..` و NUL رد می‌شود.
- لینک TAR و Reparse Point رد می‌شوند.
- فایل اجرایی یا Script هیچ‌گاه اجرا نمی‌شود؛ وجود آن در پیش‌نمایش هشدار ایجاد می‌کند.
- پس از خطای استخراج، Staging متعلق به برنامه پاک می‌شود؛ آرشیو دانلودشده باقی می‌ماند.

7-Zip در `%ProgramFiles%\7-Zip`، `%ProgramFiles(x86)%\7-Zip` و PATH جست‌وجو می‌شود. UHM نصب خودکار انجام نمی‌دهد.

## پیش‌نمایش و نصب

1. Game Path دوباره اعتبارسنجی می‌شود.
2. SHA-256 دوباره بررسی می‌شود.
3. CSP خوانده و با حداقل نسخه مقایسه می‌شود.
4. آرشیو در `data/cache/staging/<random-id>` استخراج می‌شود.
5. هر فایل به مسیر Canonical زیر Game Root نگاشت می‌شود.
6. فایل‌های موجود، Executable/Script و هشدار CSP به UI برمی‌گردند.
7. اگر Overwrite وجود دارد، Checkbox تأیید اجباری است.
8. یک Mutex سراسری مانع دو نصب هم‌زمان می‌شود.
9. پوشه‌های لازم ایجاد و فایل‌ها Copy می‌شوند؛ هیچ فایل مقصد حذف نمی‌شود.
10. نتیجه و Manifest در `data/settings/installed-mods.json` ثبت می‌شود.
11. Staging موفق پاک می‌شود.
12. بازی و Content Manager اجرا نمی‌شوند.

Backup اجباری نیست. نسخه پایه Backup اختیاری هم ارائه نمی‌کند؛ برای فایل‌های مهم پیش از تأیید Overwrite دستی Backup بگیرید. اگر Copy در میانه عملیات خطا دهد، Rollback خودکار وجود ندارد و Log وضعیت «بخشی از نصب با خطا مواجه شد» را مشخص می‌کند.

## نصب چند مود

ترتیب `order` صف حفظ می‌شود و تعداد Worker دانلود از Settings می‌آید. وضعیت هر مود مستقل است و خطای یک مود صف بعدی را متوقف نمی‌کند. نصب با Mutex سریال است، بنابراین دو مود هم‌زمان روی فایل مشترک نمی‌نویسند. نصب مجدد یک مود به تأیید جداگانه نیاز دارد.

## مودهای گرافیکی

برای `graphics` و `pack`، Rootهای شناخته‌شده `extension`، `system`، `cfg` و `apps` به ریشه بازی نگاشت می‌شوند. بسته‌هایی شامل CSP، Pure، Sol، Weather FX، Grass FX، VAO، Custom Lights، Extension Config، System Files و Lua Apps باید وابستگی‌ها، فایل‌های در معرض تغییر و `activationSteps` دقیق داشته باشند. فعال‌سازی خودکار Content Manager انجام نمی‌شود.

## نصب دستی فایل دریافت‌شده

UI نسخه 0.1.0 Import فایل دستی ندارد. در سایت CAPTCHA/Login فایل را از صفحه رسمی دریافت کنید و منتظر قابلیت Import امن بمانید؛ توصیه نمی‌شود با تغییر Job JSON آن را تزریق کنید. توسعه Import باید File Picker، تشخیص نوع، SHA و همان Preview Installer را استفاده کند.
