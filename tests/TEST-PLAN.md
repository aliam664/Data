# برنامه تست UHM Launcher

## روش

- تست‌های واحد Pester: `Security.Tests.ps1` و `Catalog.Tests.ps1`.
- تست‌های Installer/ZIP در `Installer.Tests.ps1` با Game Root مصنوعی و `TestDrive`.
- تست‌های سیستم/شبکه زیر باید روی VM تمیز و Snapshot اجرا شوند؛ هیچ تستی روی نصب اصلی کاربر انجام نشود.
- ماتریس: Windows 10 22H2 x64 و Windows 11 24H2 x64، PowerShell 5.1، 7-Zip نصب/حذف‌شده.

## سناریوهای پذیرش

| # | سناریو | روش و انتظار |
|---|---|---|
| 1 | دریافت catalog.json | HTTPS تستی → Schema/رکوردها معتبر و Source=github |
| 2 | Refresh | یک کلیک؛ دکمه قفل، نسخه/زمان جدید، Cache atomic |
| 3 | Cache آفلاین | شبکه قطع؛ آخرین Cache معتبر و پیام فارسی |
| 4 | لینک خراب | 404/500؛ status=failed، HTTP code در Log |
| 5 | ZIP | ZIP سالم استخراج و Plan صحیح |
| 6 | RAR | با 7-Zip استخراج و بدون اجرا |
| 7 | 7Z | با 7-Zip استخراج و بدون اجرا |
| 8 | آرشیو رمزدار | رمز Catalog درست؛ استخراج موفق، رمز در Log نیست |
| 9 | رمز اشتباه | یک خطای واضح، Staging پاک، Archive باقی |
| 10 | دانلود ناقص | اتصال قطع؛ `.part` و status failed/قابل Resume |
| 11 | Resume | سرور Range → درخواست offset و 206، Hash نهایی درست |
| 12 | Pause | Stream متوقف، speed=0، فایل حذف نمی‌شود |
| 13 | Cancel | Worker متوقف، `.part` حفظ؛ حذف فقط با تأیید |
| 14 | SHA اشتباه | Move/Install انجام نمی‌شود |
| 15 | Path Traversal | ZIP با `../`، مسیر مطلق و mixed slash همگی رد |
| 16 | نصب خودرو | `cars/car_id` به `content/cars/car_id`، بدون cars/cars |
| 17 | نصب پیست | `content/tracks/id` نگاشت صحیح |
| 18 | نصب اسکین | InstallRoot دقیق خودرو و Preview Overwrite |
| 19 | پک گرافیکی | extension/system/cfg تفکیک و Plan قبل از Copy |
| 20 | چند مود Queue | ترتیب ثابت، concurrency تنظیمی، خطای یکی مانع بعدی نیست |
| 21 | چند Steam Library | VDF مدرن و Legacy؛ همه مسیرها نمایش داده شوند |
| 22 | مسیر دستی | مسیر معتبر قبول، ناقص رد، Default ذخیره |
| 23 | نبود 7-Zip | پیام فارسی و عدم نصب خودکار |
| 24 | نبود Steam | UI هشدار و امکان مسیر دستی |
| 25 | نبود اینترنت | UI قابل استفاده با bundled/cache |
| 26 | Executable در آرشیو | در Preview فهرست، هرگز Start نشود |
| 27 | Command Injection | ID/Path/URL مخرب؛ آرگومان command ساخته نشود؛ بدون Invoke-Expression |
| 28 | Bridge بدون Token | 403؛ Token غلط و Origin دیگر نیز 403 |
| 29 | Windows 10 | Launch، Browse folder، Download/Install در VM |
| 30 | Windows 11 | همان ماتریس و بررسی Defender/SmartScreen |

## موارد تکمیلی

- Redirect HTTPS→HTTP باید block شود.
- پاسخ `text/html` باید `manualRequired` شود.
- دو نصب روی فایل مشترک: Mutex نصب دوم را متوقف کند.
- Overwrite جدید بین Preview و Confirm دوباره شناسایی شود.
- CSP پایین با `blockInstall=false` هشدار و با `true` توقف کند.
- بستن برگه: Bridge پس از timeout و دکمه خروج فوراً متوقف شود.
- متن Log برای `password`, `token`, `authorization` جست‌وجو و Redaction تأیید شود.
- بازی و Content Manager در Process list پس از نصب نباشند.

## داده تست شبکه

برای دانلود/Range از یک HTTPS server تحت کنترل تیم با فایل‌های کوچک و Hash معلوم استفاده کنید. از لینک مود واقعی یا عمومیِ بدون اجازه برای تست خودکار استفاده نکنید. CAPTCHA و Login با یک endpoint HTML مصنوعی شبیه‌سازی شوند؛ دور زدن آن‌ها نباید تست شود.

## معیار انتشار

JSON/Syntax/Unit در GitHub Actions سبز، ۳۰ سناریو روی هر دو VM ثبت، بررسی امنیت آرشیو توسط دو نفر، و کاتالوگ Production فاقد `example.com` باشد. نتیجه VMها در Release checklist پیوست شود.
