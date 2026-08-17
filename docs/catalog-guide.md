# راهنمای مدیریت کاتالوگ UHM

## دامنه مسئولیت

GitHub فقط Metadata، JSON و تصاویر دارای مجوز را نگه می‌دارد. فایل مود، آرشیو پولی، Mirror و محتوای بدون اجازه نباید Commit شوند. هر مود دقیقاً یک `downloadUrl` دارد؛ UHM لینک جایگزین یا Mirror را پشتیبانی نمی‌کند.

## ساختار سطح اول

```json
{
  "schemaVersion": "1.0.0",
  "catalogVersion": "2026.08.17.1",
  "generatedAt": "2026-08-17T08:00:00Z",
  "noticeFa": "پیام اختیاری مدیر کاتالوگ",
  "mods": []
}
```

با هر انتشار داده، `catalogVersion` و `generatedAt` را تغییر دهید. `schemaVersion` فقط هنگام تغییر قرارداد Schema عوض می‌شود.

## رکورد مود

نمونه کامل در `catalog/catalog.json` و قواعد ماشین‌خوان در `catalog/schema.json` قرار دارد. نکات مهم:

| فیلد | قاعده |
|---|---|
| `id` | یکتا، پایدار، حروف کوچک لاتین/عدد/`.`/`_`/`-` |
| `category` | یکی از ده دسته `categories.json` |
| `pageUrl` | صفحه رسمی یا مجاز HTTPS |
| `downloadUrl` | تنها لینک مستقیم HTTPS؛ بدون Mirror |
| `archiveType` | `zip`، `rar`، `7z`، `tar` یا `tar.gz` |
| `sha256` | ترجیحاً ۶۴ رقم hex؛ خالی یعنی بررسی Hash کاتالوگ انجام نمی‌شود |
| `installRoot` | مسیر نسبی امن زیر ریشه بازی؛ هرگز Drive، `/` ابتدایی یا `..` |
| `enabled` | برای لینک خراب/مود نامعتبر `false` |
| `verified` | فقط پس از بررسی منبع، مجوز و ساختار `true` |

## دسته‌ها

`cars` خودرو، `tracks` پیست، `skins` اسکین، `graphics` گرافیک، `packs` پک کامل، `apps` اپلیکیشن، `sounds` صدا، `weather` آب‌وهوا، `ppfilters` فیلتر گرافیکی و `miscellaneous` متفرقه.

## تعیین Install Root

- خودرو: `content/cars`
- پیست: `content/tracks`
- اسکین: `content/cars/<car-id>/skins`
- صدای خاص خودرو: `content/cars/<car-id>/sfx`
- Lua App: `apps/lua`
- PP Filter: `system/cfg/ppfilters`

Installer ساختارهای زیر را تشخیص می‌دهد:

1. آرشیو با `content/cars/...`؛
2. آرشیو با `cars/...` و Install Root خودرو؛
3. آرشیو با پوشه مستقیم مود مانند `car_id/data.acd`؛
4. یک Wrapper مانند `package/content/...`؛
5. پک گرافیکی با `extension`، `system`، `cfg` یا `apps`.

پک گرافیکی هرگز مستقیماً در ریشه Extract نمی‌شود؛ ابتدا Plan فایل‌به‌فایل ساخته می‌شود.

## رمز

اگر سازنده رمز عمومی اعلام کرده است:

```json
"passwordRequired": true,
"password": "exact-public-password"
```

اگر رمز معلوم نیست، رکورد را فعال نکنید. حدس، رمز پیش‌فرض و brute force ممنوع است. رمز در Repository عمومی محرمانه نیست، ولی در Log و API UI حذف می‌شود.

## CSP و سازگاری

```json
"requiresCsp": true,
"minCspVersion": "0.2.4",
"cspPreviewRequired": false,
"blockInstall": false,
"compatibility": {
  "pure": "compatible",
  "sol": "incompatible",
  "contentManager": "required"
}
```

مقادیر سازگاری: `compatible`، `incompatible`، `required`، `recommended`، `unknown`. مقدار `blockInstall` را با احتیاط به کار ببرید؛ در حالت false فقط هشدار نمایش داده می‌شود.

برای پک‌ها، فایل‌های مورد تغییر را در توضیحات و مراحل فعال‌سازی Pure/Weather FX/Grass FX/VAO/Custom Lights را در `activationSteps` ثبت کنید.

## لینک‌های CAPTCHA، Login و مود پولی

- UHM CAPTCHA یا Login را دور نمی‌زند.
- برای فایل پولی، `pageUrl` و در صورت نبود دانلود مستقیم مجاز، `downloadUrl` باید فقط نشانی رسمی مجاز سازنده باشد؛ چنین لینکی معمولاً به وضعیت دانلود دستی می‌رسد.
- لینک صفحه HTML به‌عنوان دانلود موفق ثبت نمی‌شود.
- پارامترهای موقت، Cookie، Token و Credential را در JSON قرار ندهید.

## تصویر

تصاویر دارای مجوز را در پوشه متناظر `images/` قرار دهید. آدرس Raw عمومی HTTPS یا CDN رسمی قابل استفاده است. نام سازنده، تصویر یا لینک رسمی را بدون اجازه تغییر ندهید. برای دسترس‌پذیری، `nameFa` دقیق و تصویر اصلی مرتبط انتخاب شود.

## اعتبارسنجی قبل از Merge

```powershell
Get-Content -Raw .\catalog\catalog.json | ConvertFrom-Json | Out-Null
Invoke-Pester .\tests\Catalog.Tests.ps1
```

سپس Schema، یکتا بودن ID، HTTPS بودن هر دو URL، حجم، SHA-256، رمز، ساختار آرشیو، مجوز انتشار و نصب در یک Game Path آزمایشی را بررسی کنید. هر لینک خراب را فوراً `enabled: false` کنید.
