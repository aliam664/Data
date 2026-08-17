# مدل امنیت UHM Launcher

## مرز اعتماد

- کاتالوگ و آرشیو مود **ورودی غیرقابل اعتماد** هستند.
- UI فقط از Origin خود Bridge سرو می‌شود.
- Bridge فقط Loopback است، اما Process محلی دیگر همچنان مهاجم بالقوه محسوب می‌شود؛ Token و Origin دفاع تکمیلی‌اند، نه Sandbox سیستم‌عامل.
- مدیر کاتالوگ مسئول اعتبار لینک، مجوز انتشار و Hash است.

## امنیت رابط Native

مسیر پیش‌فرض نسخه ۰.۲ از WPF/XAML در همان Process کاربر استفاده می‌کند و هیچ HTTP Listener، پورت، Origin یا Token ندارد. رویدادهای Button مستقیماً توابع ازپیش‌تعریف‌شده را فراخوانی می‌کنند؛ متن کاتالوگ هیچ‌گاه به‌عنوان Command تفسیر نمی‌شود. دانلود و عملیات طولانی در Workerهای PowerShell با آرگومان‌های داخلی و شناسه محدود اجرا می‌شوند.

## امنیت Bridge قدیمی

Bridge فقط برای حالت اختیاری `launch-web` باقی مانده است:

1. Prefix دقیق `http://localhost:<random>/` است؛ روی `0.0.0.0` یا LAN Bind نمی‌شود. IP مبدأ نیز باید Loopback (`127.0.0.1` یا `::1`) باشد.
2. پورت در هر اجرا تصادفی است.
3. Token با CSPRNG و ۳۲ بایت entropy تولید می‌شود.
4. Token در Fragment URL اولیه قرار می‌گیرد، به HTTP/Log ارسال نمی‌شود، برای تحمل Reload در `sessionStorage` همان برگه نگه‌داری و Fragment فوراً حذف می‌شود؛ دکمه خروج آن را پاک می‌کند.
5. API Header `X-UHM-Token` را با مقایسه تقریباً constant-time کنترل می‌کند.
6. Remote IP، Host و Origin/Referer/Sec-Fetch-Site بررسی می‌شوند.
7. CORS فعال نیست، Body به ۱ MiB و نرخ به ۳۰ درخواست در ثانیه محدود است.
8. CSP، `frame-ancestors 'none'`، `X-Frame-Options: DENY` و `nosniff` تنظیم می‌شوند.
9. heartbeat در نبود UI Bridge را متوقف می‌کند؛ دکمه خروج توقف فوری است.

محدودیت: مرورگر سیگنال قطعی و portable برای «بسته‌شدن» ندارد. بنابراین توقف خودکار ممکن است پس از timeout حدود ۹۰ ثانیه رخ دهد. Crash سیستم یا Sleep نیز می‌تواند زمان را تغییر دهد.

## URL و دانلود

- فقط URI مطلق HTTPS بدون UserInfo پذیرفته می‌شود.
- مقصد Redirect نهایی باید HTTPS باشد.
- Credential، Cookie و Login ذخیره نمی‌شود.
- CAPTCHA دور زده نمی‌شود.
- HTML به‌عنوان آرشیو موفق پذیرفته نمی‌شود.
- نام فایل از ID/Version کاتالوگ Sanitise می‌شود، نه `Content-Disposition` سرور.
- فایل نهایی موجود بدون تأیید جایگزین نمی‌شود.
- SHA-256، اگر در کاتالوگ ثبت شده باشد، قبل از Move و قبل از نصب کنترل می‌شود.

SSRF: مدیر مخزن عمومی می‌تواند Host یک URL HTTPS را تعیین کند. نسخه فعلی Scheme/UserInfo را محدود می‌کند اما IP خصوصی مقصد DNS را block نمی‌کند؛ چون Bridge روی سیستم کاربر اجرا می‌شود، Catalog production باید با review و allowlist دامنه منتشر شود. برای نسخه سخت‌گیرانه‌تر، allowlist امضاشده یا DNS/IP private-range blocking اضافه کنید.

## استخراج و مسیرها

- مسیر مطلق، UNC، Drive، segment `..` و NUL رد می‌شود.
- `GetFullPath` و Prefix comparison تضمین می‌کند مقصد زیر Staging/Game Root بماند.
- ZIP به‌صورت Entry-by-Entry استخراج می‌شود.
- 7-Zip فقط بعد از List و بررسی path اجرا می‌شود.
- TAR link و Reparse Point رد می‌شوند.
- پس از استخراج، کل Tree دوباره بررسی می‌شود.
- EXE/COM/MSI/SCR و Scriptهای BAT/CMD/PowerShell/VBS/JS اجرا نمی‌شوند و در Preview هشدار دارند.

هیچ فرایندی از داخل آرشیو Start نمی‌شود. DLL مود ممکن است توسط خود بازی در اجرای بعدی load شود؛ UHM اصالت آن را تضمین نمی‌کند. فقط مود معتبر با Hash رسمی نصب کنید.

## آرشیو رمزدار

رمز فقط از `password` کاتالوگ می‌آید؛ خالی بودن خطاست و brute force وجود ندارد. Logger کلیدهای password/token/credential را Redact می‌کند و Catalog ارسال‌شده به UI رمز خالی دارد.

محدودیت 7-Zip: رابط خط فرمان استاندارد رمز را با `-p...` می‌گیرد. UHM خروجی را نمایش/Log نمی‌کند، اما کاربر Administrator یا ابزار بررسی Process ممکن است آرگومان را در عمر کوتاه Process ببیند. راه‌حل قوی‌تر نیازمند کتابخانه extraction auditشده با API حافظه‌ای است که با شرط «بدون وابستگی سنگین» نسخه فعلی سازگار نیست.

## نصب و حذف

- Game Path چهار علامت معتبر دارد.
- Install Root نسبی است و برای هر فایل Canonical می‌شود.
- Overwrite قبل از Copy فهرست و دوباره در لحظه نصب بررسی می‌شود.
- Mutex نصب، Race بین دو مود را کاهش می‌دهد.
- هیچ فایل بازی Delete نمی‌شود.
- Uninstall وجود ندارد؛ Manifest فقط برای معماری آینده ثبت می‌شود و `removalSupported: false` دارد.
- Cache/partial/queue record فقط در پاسخ به تأیید UI حذف می‌شود؛ Staging برنامه پس از موفقیت یا خطای extraction طبق چرخه موقت پاک می‌شود.

## Command Injection

- `Invoke-Expression` ممنوع و در کد وجود ندارد.
- URL با `HttpClient` و Path با APIهای .NET پردازش می‌شود.
- ID صف Regex محدود دارد.
- 7-Zip از Argument array و marker `--` استفاده می‌کند.
- هیچ command از فیلد مود ساخته/Parse نمی‌شود.

توجه: Windows PowerShell 5.1 در `Start-Process -ArgumentList` در نهایت Command Line string می‌سازد. تمام مسیرهای Worker داخلی و تحت ریشه پروژه‌اند؛ ورودی کاتالوگ به این invocation وارد نمی‌شود.

## Log و حریم خصوصی

هر خط JSONL شامل timestamp، level، event و data است. URL بدون Query، مقصد، مود، Hash، HTTP code، مدت و نتیجه ثبت می‌شود. رمز، Token، Authorization و Credential Redact می‌شوند. Path محلی برای عیب‌یابی ثبت می‌شود و ممکن است نام کاربری Windows را در خود داشته باشد؛ پیش از انتشار Log آن را بررسی کنید.

## گزارش آسیب‌پذیری

Token، رمز شخصی یا فایل مود را در Issue عمومی منتشر نکنید. برای استقرار واقعی یک `SECURITY.md` با کانال خصوصی نگه‌دارنده اضافه شود. تا آن زمان، از اجرای Catalogهای ناشناس خودداری کنید.
