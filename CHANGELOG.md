# تاریخچه تغییرات

همه تغییرات مهم UHM Launcher در این فایل ثبت می‌شوند. قالب نسخه‌ها بر اساس Semantic Versioning است.

## [Unreleased]

### ابزار مدیریت کاتالوگ

- اضافه‌شدن `catalog/UHM-Catalog-Manager.cmd` با رابط Native WPF برای افزودن مرحله‌ای مود
- تولید ID، محاسبه Size/SHA-256، تست لینک، انتخاب تصاویر، Clone Template، Preview امن، Backup و ذخیره Atomic
- تضمین عدم کپی آرشیو مود در Repository و عدم پیاده‌سازی حذف رکورد

### طراحی رابط

- بازطراحی کامل Design System رابط WPF با Hero، Sidebar حرفه‌ای، کارت‌های تصویری، Empty State و کنترل‌های Dark اختصاصی
- اضافه‌شدن Hover/Focus State، Shadow، Progress سفارشی، DataGrid مدرن، Maximize Button و نمایش تصویری جزئیات مود
- بهینه‌سازی تایپوگرافی فارسی با `fa-IR` و Segoe UI داخلی Windows بدون دانلود Font

### رفع باگ

- رفع Scope جداشده `GetNewClosure()` در منوی WPF روی Windows PowerShell 5.1
- اضافه‌شدن Handler سراسری Dispatcher برای جلوگیری از بسته‌شدن کل پنجره در خطای یک رویداد UI
- رفع Materialization فهرست‌های Generic و Encoding فارسی در Windows PowerShell 5.1

### برنامه بعدی

- اجرای تست یکپارچه واقعی روی Windows 10 و Windows 11
- کاتالوگ تولیدی با لینک‌های رسمی و مجاز
- امکان حذف امن مود پس از طراحی Manifest/Conflict کامل (در نسخه فعلی وجود ندارد)

## [0.2.0] - 2026-08-17

### تغییر معماری UI

- رابط پیش‌فرض از مرورگر به WPF/XAML Native تغییر کرد.
- پنجره فارسی RTL با Dashboard، Catalog، Queue، Installed و Settings اضافه شد.
- کلیک‌های رابط مستقیماً Queue/Downloader/Installer را فراخوانی می‌کنند و Local HTTP Bridge در مسیر پیش‌فرض وجود ندارد.
- Workerهای دانلود، Refresh غیرهم‌زمان، Folder Picker، نصب و تأیید Overwrite به رابط Native متصل شدند.
- `UHM-Launcher.cmd` اکنون PowerShell را با `-STA` اجرا می‌کند.
- رابط HTML بدون حذف فایل‌ها به‌عنوان حالت Legacy با `-Action launch-web` نگه داشته شد.

## [0.1.0] - 2026-08-16

### افزوده شد

- نقطه ورود `UHM-Launcher.cmd` بدون ساخت فایل EXE
- رابط فارسی، RTL، Responsive و تم تیره ریسینگ
- Local Bridge محدود به `127.0.0.1` با توکن تصادفی، Origin/Host check، rate limit و heartbeat
- دریافت و Cache کاتالوگ GitHub با fallback آفلاین
- شناسایی Registry، `libraryfolders.vdf` و چند Steam Library
- صف دانلود پایدار با Progress، Pause، Resume مبتنی بر HTTP Range، Cancel و Retry
- استخراج امن ZIP، RAR، 7Z، TAR و TAR.GZ و پشتیبانی از آرشیو رمزدار
- پیش‌نمایش Overwrite، کنترل Path Traversal، بررسی SHA-256 و ثبت مودهای نصب‌شده
- بررسی CSP و هشدار سازگاری Pure/Sol/Content Manager
- Log ساختاریافته JSONL با حذف Token، Credential و رمز
- Schema کاتالوگ، داده نمایشی، تست‌های Pester و مستندات توسعه/امنیت

### محدودیت شناخته‌شده

- تمام URLهای مود در کاتالوگ نمونه به `example.com` اشاره می‌کنند و عمداً قابل دانلود نیستند.
- توقف Bridge بعد از بستن مرورگر با heartbeat انجام می‌شود و ممکن است تا ۹۰ ثانیه زمان ببرد.
- Pause در سطح stream برنامه است؛ تضمین Resume به پشتیبانی Range در سرور وابسته است.
