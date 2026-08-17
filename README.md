# UHM Launcher

لانچر فارسی و متن‌باز مدیریت مود **Assetto Corsa** برای Windows 10 و Windows 11. UHM Launcher مودها را از یک کاتالوگ عمومی GitHub نمایش می‌دهد، دانلود مستقیم HTTPS را در یک صف محلی انجام می‌دهد، آرشیو را در پوشه موقت امن بررسی می‌کند و فقط پس از نمایش فایل‌های قابل جایگزینی آن را نصب می‌کند.

> **وضعیت پروژه:** نسخه `0.2.0` یک پیاده‌سازی پایه با رابط Native است. کاتالوگ همراه پروژه صرفاً Demo است و همه URLهای `example.com` عمداً جعلی و غیرقابل دانلود هستند. پیش از انتشار عمومی، لینک‌های رسمی/مجاز و تست‌های یکپارچه Windows را اضافه کنید.

## اصول پروژه

- فایل اصلی **EXE نیست**؛ ورودی برنامه `UHM-Launcher.cmd` است.
- رابط اصلی با **WPF و XAML**، فارسی، RTL، قابل تغییر اندازه و بدون مرورگر ساخته شده است.
- عملیات UI و سیستم با CMD و Windows PowerShell 5.1 اجرا می‌شود.
- رابط HTML قبلی حذف نشده و فقط به‌عنوان حالت Legacy با `UHM-Core.ps1 -Action launch-web` باقی مانده است؛ در حالت Native هیچ Local HTTP Bridge باز نمی‌شود.
- بازی و Content Manager پس از نصب خودکار اجرا نمی‌شوند.
- حذف مود در این نسخه وجود ندارد.
- فایل بازی حذف نمی‌شود. حذف Cache، فایل ناقص یا رکورد صف فقط پس از تأیید کاربر انجام می‌شود.

## قابلیت‌ها

- داشبورد وضعیت کاتالوگ، Steam، Assetto Corsa و دانلودها
- کاتالوگ Native کارتی با جست‌وجوی لحظه‌ای، فیلتر دسته/نسخه/CSP/رمز/نصب و پنج روش مرتب‌سازی
- صفحه جزئیات، وابستگی‌ها، وضعیت CSP و مراحل فعال‌سازی
- Refresh از GitHub، اعتبارسنجی JSON، Cache محلی و fallback آفلاین
- کشف Steam از Registry و خواندن Libraryهای جدید و Legacy از `libraryfolders.vdf`
- پشتیبانی چند مسیر بازی، نام‌گذاری و انتخاب مقصد پیش‌فرض
- صف پایدار، تعداد دانلود قابل تنظیم (۱ تا ۴)، Progress، Pause، Resume با HTTP Range، Cancel و Retry
- تشخیص لینک واسط HTML/CAPTCHA/Login به‌عنوان «نیازمند دانلود دستی»
- ZIP داخلی و RAR/7Z با شناسایی 7-Zip؛ TAR/TAR.GZ با `tar.exe` ویندوز
- رمز آرشیو فقط از کاتالوگ؛ بدون حدس، brute force یا ثبت رمز در Log
- جلوگیری از Path Traversal، مسیر مطلق، Reparse Point و لینک TAR
- SHA-256 اختیاری، پیش‌نمایش Overwrite و قفل سراسری نصب
- تشخیص ساختارهای `content`، `cars`، `tracks` و ریشه‌های پک گرافیکی
- بررسی نسخه CSP با هشدار قابل تنظیم `blockInstall`
- Log روزانه JSONL با redaction اطلاعات حساس

## پیش‌نیازها

1. Windows 10 یا Windows 11؛ Windows 7 پشتیبانی نمی‌شود.
2. Windows PowerShell 5.1.
3. Assetto Corsa نصب‌شده برای عملیات نصب (مرور کاتالوگ و دانلود بدون آن ممکن است).
4. برای RAR، 7Z و ZIP رمزدار: [7-Zip](https://www.7-zip.org/)؛ UHM آن را بدون تأیید نصب نمی‌کند.
5. اتصال HTTPS مستقیم برای دانلود. سرور باید برای Resume از HTTP Range پشتیبانی کند.

## اجرا

1. Release یا مخزن را در پوشه‌ای با دسترسی نوشتن Extract کنید.
2. روی `UHM-Launcher.cmd` دوبار کلیک کنید.
3. CMD نسخه Windows/PowerShell را بررسی و PowerShell را در حالت STA اجرا می‌کند.
4. `wpf/MainWindow.xaml` به‌عنوان یک پنجره Native Windows بارگذاری می‌شود؛ مرورگر، Electron یا EXE اختصاصی UHM باز نمی‌شود.
5. دکمه‌ها مستقیماً توابع امن PowerShell را فراخوانی می‌کنند و دانلودها در Workerهای مخفی پس‌زمینه اجرا می‌شوند.
6. با خروج، Worker فعال پس از تأیید متوقف می‌شود و فایل ناقص برای Resume باقی می‌ماند.

حالت وب قدیمی فقط برای توسعه/مقایسه نگه داشته شده و ورودی پیش‌فرض نیست.

## ساختار

```text
UHM-Launcher.cmd       CMD entry point (PowerShell -STA)
wpf/                   رابط اصلی Native: XAML + PowerShell event handlers
ui/                    رابط HTML قدیمی برای حالت Legacy
core/                  Downloader، Installer، Queue و سایر ماژول‌های PowerShell
catalog/               catalog.json، categories.json و JSON Schema
images/                تصاویر عمومی کاتالوگ (بدون فایل مود)
data/                  Cache، تنظیمات، Log و دانلود محلی (در Git ignore)
docs/                  راهنماهای تفصیلی
tests/                 تست‌های Pester و برنامه تست Windows
```

## افزودن مود

1. رکورد را مطابق `catalog/schema.json` به `catalog/catalog.json` اضافه کنید.
2. `id` یکتا و پایدار، دسته معتبر و فقط **یک** `downloadUrl` مستقیم HTTPS تعیین کنید.
3. URL رسمی صفحه سازنده را در `pageUrl` بگذارید؛ برای مود پولی فقط صفحه رسمی مجاز است.
4. مقدار `installRoot` را نسبت به ریشه Assetto Corsa بنویسید؛ نمونه: `content/cars`.
5. در صورت امکان SHA-256 فایل رسمی را ثبت کنید.
6. کاتالوگ را Validate و لینک را با اجازه صاحب اثر آزمایش کنید.
7. لینک خراب/نامعتبر را با `enabled: false` پنهان کنید.

جزئیات و نمونه‌ها: [راهنمای کاتالوگ](docs/catalog-guide.md).

## آرشیو رمزدار

```json
{
  "archiveType": "7z",
  "passwordRequired": true,
  "password": "public-password-from-author"
}
```

رمز مخزن عمومی محرمانه نیست، اما UHM آن را در UI، CMD و Log نمایش نمی‌دهد. اگر `password` خالی باشد، عملیات با خطا متوقف می‌شود؛ هیچ رمز پیش‌فرضی حدس زده نمی‌شود. 7-Zip رمز را به‌صورت آرگومان process دریافت می‌کند و ممکن است در ابزارهای مدیریتی سطح Administrator برای مدت کوتاه قابل مشاهده باشد؛ توضیح این محدودیت در [سند امنیت](docs/security.md) آمده است.

## تصویر و گالری

- تصویر را با مجوز مناسب در `images/<category>/` قرار دهید و Raw GitHub HTTPS آن را در رکورد وارد کنید؛ یا از CDN رسمی سازنده استفاده کنید.
- فرمت‌های پیشنهادی JPG/WebP با عرض ۱۲۸۰ پیکسل و حجم مناسب‌اند.
- فایل مود، آرشیو یا محتوای پولی را داخل GitHub قرار ندهید.
- تصاویر جدید هنگام Refresh (به‌جز دامنه Demo) در Cache ذخیره می‌شوند.

## CSP و پک گرافیکی

- `requiresCsp`، `minCspVersion` و `cspPreviewRequired` نیازمندی را تعریف می‌کنند.
- `blockInstall: true` فقط وقتی استفاده شود که ناسازگاری قطعاً نصب را خراب می‌کند؛ در حالت عادی هشدار کافی است.
- برای پک‌های چندریشه‌ای `installType: "graphics"` یا `"pack"` انتخاب کنید. Installer فایل‌های `extension`، `system`، `cfg` و `apps` را جداگانه به ریشه امن نگاشت می‌کند و هیچ آرشیوی را کورکورانه روی پوشه بازی Extract نمی‌کند.
- مراحل دستی فعال‌سازی Pure، Weather FX یا PP Filter را در `activationSteps` بنویسید.

## محدودیت لینک دانلود

UHM فقط دانلود مستقیم HTTPS را می‌پذیرد و Redirect نهایی نیز باید HTTPS باشد. برنامه:

- CAPTCHA را دور نمی‌زند؛
- Login یا Cookie کاربر را ذخیره/خودکار نمی‌کند؛
- صفحه واسط HTML را موفق گزارش نمی‌کند؛
- DRM یا محدودیت سازنده را دور نمی‌زند؛
- Mirror ندارد.

در این وضعیت، صفحه رسمی را در جزئیات باز و فایل را دستی دریافت کنید. Import دستی آرشیو در نسخه `0.2.0` UI ندارد؛ می‌توان آن را در نسخه بعد با File Picker و همان زنجیره اعتبارسنجی افزود.

## رفع خطای سریع

- **مسیر بازی پیدا نشد:** Settings → مسیرهای Assetto Corsa؛ پوشه‌ای را انتخاب کنید که `AssettoCorsa.exe` و `content/cars`/`tracks` دارد.
- **7-Zip نصب نیست:** نسخه رسمی 7-Zip را نصب و Launcher را دوباره اجرا کنید.
- **Resume انجام نمی‌شود:** سرور Range را پشتیبانی نمی‌کند. حذف فایل ناقص باید در UI تأیید و دانلود از ابتدا آغاز شود.
- **حالت آفلاین:** Cache آخرین کاتالوگ معتبر است؛ URL کاتالوگ و اینترنت را تست کنید.
- **جزئیات بیشتر:** `data/logs/uhm-YYYY-MM-DD.jsonl` و [راهنمای عیب‌یابی](docs/troubleshooting.md).

## توسعه‌دهنده

- رابط اصلی از Assemblyهای داخلی WPF/.NET Framework ویندوز استفاده می‌کند و وابستگی UI جداگانه‌ای نصب نمی‌شود.
- همه فایل‌های `.ps1` عمداً با **UTF-8 BOM** ذخیره می‌شوند تا Windows PowerShell 5.1 متن فارسی را به‌درستی Parse کند؛ تنظیم آن در `.editorconfig` ثبت شده است.
- PowerShell با `Set-StrictMode` نوشته شده و از `Invoke-Expression` استفاده نمی‌کند.
- حالت Native مستقیماً با هسته کار می‌کند؛ محدودیت Body یک MiB فقط مربوط به Bridge قدیمی است.
- تست‌ها با Pester 5 روی Windows اجرا می‌شوند:

```powershell
Invoke-Pester -Path .\tests -Output Detailed
```

الگوی آماده Workflow ویندوز در `docs/ci/windows-test-workflow.yml` قرار دارد و JSON، Syntax PowerShell، XAML و تست‌های واحد را بررسی می‌کند. نگه‌دارنده‌ای که مجوز Workflows دارد می‌تواند آن را مطابق `docs/ci/README.md` فعال کند. سناریوهای نیازمند Steam واقعی، چند Library، قطع شبکه و Windows 10/11 در `tests/TEST-PLAN.md` برای اجرای دستی/VM مشخص شده‌اند.

## اسناد

- [معماری رابط Native WPF](docs/native-ui.md)
- [ممیزی فنی و آمادگی انتشار](docs/project-audit.md)
- [راهنمای کاتالوگ](docs/catalog-guide.md)
- [راهنمای نصب و رفتار Installer](docs/installation-guide.md)
- [مدل امنیت](docs/security.md)
- [عیب‌یابی](docs/troubleshooting.md)
- [برنامه تست](tests/TEST-PLAN.md)

## مجوز

کد تحت [MIT License](LICENSE) منتشر می‌شود. این مجوز مالکیت مودها، تصاویر، علائم تجاری Assetto Corsa، Kunos Simulazioni یا محتوای شخص ثالث را منتقل نمی‌کند. مدیر کاتالوگ مسئول دریافت اجازه و ثبت لینک قانونی است.
