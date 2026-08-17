(() => {
  'use strict';

  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
  const main = $('#app-main');
  const modalRoot = $('#modal-root');
  const toastRoot = $('#toast-root');
  const categoryNames = {
    cars: 'خودرو', tracks: 'پیست', skins: 'اسکین', graphics: 'گرافیک', packs: 'پک کامل',
    apps: 'اپلیکیشن', sounds: 'صدا', weather: 'آب‌وهوا', ppfilters: 'فیلتر گرافیکی', miscellaneous: 'متفرقه'
  };
  const statusNames = {
    queued: 'در صف', starting: 'در حال شروع', connecting: 'در حال اتصال', downloading: 'در حال دانلود', paused: 'مکث‌شده',
    canceling: 'در حال لغو', canceled: 'لغوشده', failed: 'خطا', manualRequired: 'نیازمند دانلود دستی', downloaded: 'آماده نصب',
    preparingInstall: 'آماده‌سازی نصب', awaitingConfirmation: 'نیازمند تأیید نصب', installed: 'نصب‌شده', installFailed: 'خطای نصب'
  };

  const state = {
    token: '', page: 'dashboard', catalog: { mods: [] }, catalogSource: 'bundled', offline: true,
    settings: { gamePaths: [] }, steam: {}, queue: [], installed: [], stats: {}, appVersion: '0.1.0',
    selected: new Set(), view: 'grid', refreshing: false,
    filters: { query: '', category: 'all', version: 'all', csp: 'all', password: 'all', installed: 'all', sort: 'newest' }
  };

  function e(value) {
    return String(value ?? '').replace(/[&<>'"]/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' })[char]);
  }
  function safeUrl(value) {
    const text = String(value || '');
    if (/^\/media\/[a-z0-9._-]+$/i.test(text)) return e(text);
    try { const url = new URL(text); return url.protocol === 'https:' ? e(url.href) : '#'; } catch { return '#'; }
  }
  function faNumber(value) { return Number(value || 0).toLocaleString('fa-IR'); }
  function formatBytes(value) {
    const bytes = Number(value || 0); if (!bytes) return '۰ B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB']; const index = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
    return `${(bytes / (1024 ** index)).toLocaleString('fa-IR', { maximumFractionDigits: 1 })} ${units[index]}`;
  }
  function formatDate(value) {
    if (!value) return 'ثبت نشده';
    try { return new Intl.DateTimeFormat('fa-IR', { year: 'numeric', month: 'short', day: 'numeric' }).format(new Date(value)); } catch { return e(value); }
  }
  function eta(value) {
    const seconds = Number(value); if (!Number.isFinite(seconds) || seconds < 0) return '—';
    if (seconds < 60) return `${faNumber(Math.ceil(seconds))} ثانیه`;
    if (seconds < 3600) return `${faNumber(Math.ceil(seconds / 60))} دقیقه`;
    return `${faNumber(Math.floor(seconds / 3600))} ساعت`;
  }
  function toast(message, type = 'success', duration = 4800) {
    const node = document.createElement('div'); node.className = `toast ${type}`;
    node.innerHTML = `<p>${e(message)}</p><button aria-label="بستن">×</button>`;
    node.querySelector('button').addEventListener('click', () => node.remove()); toastRoot.append(node);
    setTimeout(() => node.remove(), duration);
  }
  async function api(path, options = {}) {
    const config = { method: options.method || 'GET', headers: { 'X-UHM-Token': state.token } };
    if (options.body !== undefined) { config.headers['Content-Type'] = 'application/json'; config.body = JSON.stringify(options.body); }
    const response = await fetch(path, config);
    let payload; try { payload = await response.json(); } catch { payload = { success: false, message: 'پاسخ Bridge قابل خواندن نیست.' }; }
    if (!response.ok) throw new Error(payload.message || `خطای Bridge (${response.status})`);
    return payload;
  }
  function getToken() {
    const hash = new URLSearchParams(location.hash.slice(1));
    const fragmentToken = hash.get('token') || '';
    if (fragmentToken) {
      sessionStorage.setItem('uhm-bridge-token', fragmentToken);
      history.replaceState(null, '', location.pathname);
      return fragmentToken;
    }
    return sessionStorage.getItem('uhm-bridge-token') || '';
  }
  function modById(id) { return state.catalog.mods.find(mod => mod.id === id); }
  function isInstalled(id) { return state.installed.some(item => item.modId === id); }
  function validPaths() { return (state.settings.gamePaths || []).filter(item => item.isValid); }
  function targetOptions(selected) {
    const paths = validPaths();
    if (!paths.length) return '<option value="">مسیر معتبر پیدا نشد</option>';
    return paths.map(item => `<option value="${e(item.id)}" ${item.id === (selected || state.settings.defaultGamePathId) ? 'selected' : ''}>${e(item.name)} — ${e(item.path)}</option>`).join('');
  }
  function pageHead(eyebrow, title, description, actions = '') {
    return `<div class="page-head"><div><span class="eyebrow">${e(eyebrow)}</span><h1>${e(title)}</h1><p>${e(description)}</p></div>${actions ? `<div class="head-actions">${actions}</div>` : ''}</div>`;
  }
  function emptyState(icon, title, text, action = '') {
    return `<div class="empty-state"><div><span class="empty-icon">${icon}</span><h3>${e(title)}</h3><p>${e(text)}</p>${action ? `<div class="modal-actions">${action}</div>` : ''}</div></div>`;
  }

  function updateChrome() {
    $$('.nav-item').forEach(button => button.classList.toggle('active', button.dataset.page === state.page));
    const active = state.queue.filter(item => ['queued', 'starting', 'connecting', 'downloading', 'paused', 'preparingInstall', 'awaitingConfirmation'].includes(item.status)).length;
    const badge = $('#queue-badge'); badge.textContent = faNumber(active); badge.classList.toggle('hidden', active === 0);
    $('#side-version').textContent = state.appVersion;
    const pill = $('#connection-pill'); pill.classList.toggle('online', !state.offline); pill.classList.toggle('offline', state.offline);
    $('small', pill).textContent = state.offline ? 'حالت آفلاین' : 'متصل';
  }

  function renderDashboard() {
    const enabled = state.catalog.mods.filter(mod => mod.enabled);
    const featured = enabled.filter(mod => mod.featured).slice(0, 4);
    const newest = [...enabled].sort((a, b) => new Date(b.updatedAt) - new Date(a.updatedAt)).slice(0, 2);
    const active = state.queue.filter(item => ['starting', 'connecting', 'downloading', 'paused'].includes(item.status)).length;
    const defaultPath = validPaths().find(path => path.id === state.settings.defaultGamePathId);
    main.innerHTML = pageHead('مرکز کنترل', 'داشبورد راننده', 'وضعیت کاتالوگ، بازی و دانلودها را از یک نمای سریع کنترل کنید.', `<button class="primary-button" data-page-jump="catalog">مشاهده کاتالوگ <span>←</span></button>`) + `
      <section class="stats-grid">
        ${statCard('▦', 'کل مودهای فعال', enabled.length, `نسخه کاتالوگ ${state.catalog.catalogVersion || '—'}`)}
        ${statCard('✓', 'مودهای نصب‌شده', state.installed.length, 'ثبت‌شده توسط UHM Launcher')}
        ${statCard('⇩', 'دانلودهای فعال', active, `${state.queue.length.toLocaleString('fa-IR')} آیتم در تاریخچه صف`)}
        ${statCard('↻', 'آخرین به‌روزرسانی', state.settings.lastCatalogRefresh ? formatDate(state.settings.lastCatalogRefresh) : '—', state.offline ? 'در حال استفاده از Cache' : 'اتصال کاتالوگ برقرار است')}
      </section>
      <section class="dashboard-grid">
        <div>
          <article class="panel"><header class="panel-head"><h2>مودهای منتخب</h2><button class="text-button" data-page-jump="catalog">نمایش همه ←</button></header>
            <div class="panel-body"><div class="featured-strip">${featured.length ? featured.map(miniMod).join('') : '<p class="muted">مود Featured وجود ندارد.</p>'}</div></div>
          </article>
          <article class="panel" style="margin-top:18px"><header class="panel-head"><h2>تازه‌های کاتالوگ</h2><small>${faNumber(newest.length)} مورد اخیر</small></header>
            <div class="panel-body"><div class="featured-strip">${newest.map(miniMod).join('')}</div></div>
          </article>
        </div>
        <aside class="panel"><header class="panel-head"><h2>سلامت سیستم</h2><small>بررسی خودکار</small></header><div class="panel-body health-list">
          ${healthItem('G', 'اتصال GitHub', state.offline ? 'Cache محلی فعال است' : 'کاتالوگ آنلاین', state.offline ? 'آفلاین' : 'متصل', state.offline ? 'warn' : '')}
          ${healthItem('S', 'Steam', state.steam.steamFound ? `${(state.steam.libraries || []).length} Library شناسایی شد` : 'در Registry پیدا نشد', state.steam.steamFound ? 'شناسایی شد' : 'پیدا نشد', state.steam.steamFound ? '' : 'warn')}
          ${healthItem('AC', 'Assetto Corsa', defaultPath ? defaultPath.path : 'یک مسیر دستی معتبر اضافه کنید', defaultPath ? 'آماده' : 'بدون مسیر', defaultPath ? '' : 'bad')}
          ${healthItem('7z', 'استخراج RAR / 7Z', 'از بخش تنظیمات تست کنید', 'نیاز به تست', 'warn')}
          ${healthItem('B', 'Local Bridge', 'فقط روی localhost / Loopback', 'امن و فعال', '')}
        </div></aside>
      </section>`;
  }
  function statCard(icon, label, value, meta) { return `<article class="stat-card"><div class="stat-top"><span>${e(label)}</span><i class="stat-icon">${icon}</i></div><strong class="stat-value">${typeof value === 'number' ? faNumber(value) : e(value)}</strong><small class="stat-meta">${e(meta)}</small></article>`; }
  function healthItem(icon, title, text, status, cls) { return `<div class="health-item"><span class="health-icon">${e(icon)}</span><div><b>${e(title)}</b><small title="${e(text)}">${e(text)}</small></div><span class="health-state ${cls}">${e(status)}</span></div>`; }
  function miniMod(mod) { return `<article class="mini-mod" data-open-mod="${e(mod.id)}" tabindex="0"><span class="category-chip">${e(categoryNames[mod.category] || mod.category)}</span><h3>${e(mod.nameFa)}</h3><p>${e(mod.author)} · v${e(mod.version)}</p><span class="arrow">←</span></article>`; }

  function filteredMods() {
    const f = state.filters; const query = f.query.trim().toLocaleLowerCase('fa');
    let mods = state.catalog.mods.filter(mod => mod.enabled).filter(mod => {
      const haystack = `${mod.name} ${mod.nameFa} ${mod.author} ${mod.description} ${categoryNames[mod.category] || mod.category}`.toLocaleLowerCase('fa');
      return (!query || haystack.includes(query)) && (f.category === 'all' || mod.category === f.category) &&
        (f.version === 'all' || mod.version === f.version) &&
        (f.csp === 'all' || (f.csp === 'required' ? mod.requiresCsp : !mod.requiresCsp)) &&
        (f.password === 'all' || (f.password === 'yes' ? mod.passwordRequired : !mod.passwordRequired)) &&
        (f.installed === 'all' || (f.installed === 'yes' ? isInstalled(mod.id) : !isInstalled(mod.id)));
    });
    const compareName = (a, b) => a.nameFa.localeCompare(b.nameFa, 'fa');
    const sorts = {
      newest: (a, b) => new Date(b.releaseDate) - new Date(a.releaseDate), popular: (a, b) => (b.popularity || 0) - (a.popularity || 0),
      name: compareName, size: (a, b) => b.sizeBytes - a.sizeBytes, updated: (a, b) => new Date(b.updatedAt) - new Date(a.updatedAt)
    };
    return mods.sort(sorts[f.sort] || sorts.newest);
  }
  function renderCatalog() {
    const mods = filteredMods(); const versions = [...new Set(state.catalog.mods.filter(m => m.enabled).map(m => m.version))].sort();
    main.innerHTML = pageHead('Mod Library', 'کاتالوگ مودها', 'مودهای تأییدشده را جست‌وجو، مقایسه و به صف دانلود اضافه کنید.', `<button class="secondary-button" id="catalog-refresh">↻ تازه‌سازی</button>`) + `
      <div class="catalog-toolbar">
        <label class="local-search"><span>⌕</span><input id="catalog-query" type="search" value="${e(state.filters.query)}" placeholder="نام مود یا سازنده…"></label>
        <select id="category-filter" class="select-control" aria-label="دسته‌بندی"><option value="all">همه دسته‌ها</option>${Object.entries(categoryNames).map(([id, name]) => `<option value="${id}" ${state.filters.category === id ? 'selected' : ''}>${name}</option>`).join('')}</select>
        <select id="sort-filter" class="select-control" aria-label="مرتب‌سازی"><option value="newest" ${state.filters.sort === 'newest' ? 'selected' : ''}>جدیدترین</option><option value="popular" ${state.filters.sort === 'popular' ? 'selected' : ''}>محبوب‌ترین</option><option value="name" ${state.filters.sort === 'name' ? 'selected' : ''}>نام</option><option value="size" ${state.filters.sort === 'size' ? 'selected' : ''}>حجم</option><option value="updated" ${state.filters.sort === 'updated' ? 'selected' : ''}>آخرین به‌روزرسانی</option></select>
        <div class="view-switch"><button data-view="list" class="${state.view === 'list' ? 'active' : ''}" title="نمای فهرست">☷</button><button data-view="grid" class="${state.view === 'grid' ? 'active' : ''}" title="نمای شبکه">▦</button></div>
      </div>
      <div class="filter-row">
        <label class="filter-chip">نسخه <select id="version-filter"><option value="all">همه</option>${versions.map(v => `<option ${state.filters.version === v ? 'selected' : ''}>${e(v)}</option>`).join('')}</select></label>
        <label class="filter-chip">CSP <select id="csp-filter"><option value="all" ${state.filters.csp === 'all' ? 'selected' : ''}>همه</option><option value="required" ${state.filters.csp === 'required' ? 'selected' : ''}>نیاز دارد</option><option value="none" ${state.filters.csp === 'none' ? 'selected' : ''}>نیاز ندارد</option></select></label>
        <label class="filter-chip">رمز <select id="password-filter"><option value="all" ${state.filters.password === 'all' ? 'selected' : ''}>همه</option><option value="yes" ${state.filters.password === 'yes' ? 'selected' : ''}>رمزدار</option><option value="no" ${state.filters.password === 'no' ? 'selected' : ''}>بدون رمز</option></select></label>
        <label class="filter-chip">نصب <select id="installed-filter"><option value="all" ${state.filters.installed === 'all' ? 'selected' : ''}>همه</option><option value="yes" ${state.filters.installed === 'yes' ? 'selected' : ''}>نصب‌شده</option><option value="no" ${state.filters.installed === 'no' ? 'selected' : ''}>نصب‌نشده</option></select></label>
        <span class="result-count">${faNumber(mods.length)} مود</span>
      </div>
      ${mods.length ? `<section class="mod-grid ${state.view === 'list' ? 'list-view' : ''}">${mods.map(modCard).join('')}</section>` : emptyState('⌕', 'نتیجه‌ای پیدا نشد', 'فیلترها یا عبارت جست‌وجو را تغییر دهید.')}
      ${state.selected.size ? `<div class="selection-bar"><span><b>${faNumber(state.selected.size)}</b> مود انتخاب شده</span><label class="filter-chip"><input id="selected-auto-install" type="checkbox" ${validPaths().length ? '' : 'disabled'}> نصب پس از دانلود</label><div><button class="text-button" id="clear-selection">لغو انتخاب</button><button class="primary-button" id="add-selected">افزودن به صف</button></div></div>` : ''}`;
  }
  function modCard(mod) {
    const selected = state.selected.has(mod.id); const installed = isInstalled(mod.id);
    return `<article class="mod-card ${selected ? 'selected' : ''}">
      <div class="mod-cover"><div class="cover-fallback">UHM</div>${safeUrl(mod.image) !== '#' ? `<img src="${safeUrl(mod.image)}" alt="" loading="lazy">` : ''}
        <label class="mod-select" title="انتخاب"><input type="checkbox" data-select-mod="${e(mod.id)}" ${selected ? 'checked' : ''}></label>
        <div class="card-flags">${mod.featured ? '<span class="flag">منتخب</span>' : ''}${mod.verified ? '<span class="flag verified">تأییدشده</span>' : ''}${installed ? '<span class="flag verified">نصب‌شده</span>' : ''}</div>
      </div><div class="mod-card-body"><div class="card-meta"><span class="category">${e(categoryNames[mod.category] || mod.category)}</span><span>${formatDate(mod.updatedAt)}</span></div>
        <h3 title="${e(mod.nameFa)}">${e(mod.nameFa)}</h3><p>${e(mod.shortDescription)}</p>
        <div class="card-footer"><div class="card-specs"><span>${e(mod.sizeText)}</span><span>v${e(mod.version)}</span><span>${e(mod.archiveType.toUpperCase())}</span></div><button class="card-action" data-open-mod="${e(mod.id)}" aria-label="جزئیات">←</button></div>
      </div></article>`;
  }

  function queueClass(status) {
    if (['failed', 'installFailed', 'manualRequired', 'canceled'].includes(status)) return 'failed';
    if (status === 'paused') return 'paused'; if (status === 'awaitingConfirmation') return 'awaiting';
    if (['downloaded', 'installed'].includes(status)) return 'done'; return '';
  }
  function queueActions(item) {
    if (['starting', 'connecting', 'downloading'].includes(item.status)) return `<button data-queue-action="pause" data-id="${item.id}" title="مکث">Ⅱ</button><button data-queue-action="cancel" data-id="${item.id}" title="لغو">■</button>`;
    if (item.status === 'paused') return `<button data-queue-action="resume" data-id="${item.id}" title="ادامه">▶</button><button data-queue-action="cancel" data-id="${item.id}" title="لغو">■</button>`;
    if (item.status === 'manualRequired') return `<button data-open-mod="${e(item.modId)}" title="صفحه رسمی و جزئیات">صفحه رسمی</button><button data-queue-action="remove" data-id="${item.id}" title="حذف از صف">×</button>`;
    if (['failed', 'canceled'].includes(item.status)) return `<button data-queue-action="retry" data-id="${item.id}" title="تلاش مجدد">↻</button><button data-queue-action="remove" data-id="${item.id}" title="حذف از صف">×</button>`;
    if (['downloaded', 'installFailed'].includes(item.status)) return `<button class="install" data-install-preview="${item.id}">${item.status === 'installFailed' ? 'تلاش دوباره نصب' : 'نصب'}</button><button data-queue-action="remove" data-id="${item.id}" title="حذف از صف">×</button>`;
    if (item.status === 'awaitingConfirmation') return `<button class="install" data-confirm-existing="${item.id}">بررسی و تأیید</button>`;
    if (item.status === 'installed') return `<button data-open-mod="${e(item.modId)}">جزئیات</button><button data-queue-action="remove" data-id="${item.id}">پاک‌کردن رکورد صف</button>`;
    if (item.status === 'queued') return `<button data-queue-action="cancel" data-id="${item.id}">لغو</button>`;
    return '';
  }
  function renderQueue() {
    const active = state.queue.filter(item => ['queued', 'starting', 'connecting', 'downloading', 'paused'].includes(item.status)).length;
    main.innerHTML = pageHead('Transfer Center', 'صف دانلود و نصب', 'هر دانلود مستقل است؛ فایل ناقص پس از لغو نگه‌داری می‌شود تا خودتان درباره حذف آن تصمیم بگیرید.', `<span class="tag">${faNumber(active)} عملیات فعال</span>`) +
      (state.queue.length ? `<section class="queue-list">${state.queue.map(item => {
        const progress = Math.max(0, Math.min(100, Number(item.progress || 0))); const status = statusNames[item.status] || item.status;
        return `<article class="queue-item"><div class="queue-thumb">${e((item.name || 'U').slice(0, 2).toUpperCase())}</div><div class="queue-title"><b>${e(item.nameFa || item.name)}</b><small>v${e(item.version)} · ${e(item.targetPath || 'بدون مقصد نصب')}</small></div>
          <div class="queue-progress"><div class="progress-head"><span class="status-label ${queueClass(item.status)}">● ${e(status)}${item.installAfterDownload ? ' · نصب پس از دانلود' : ''}</span><span>${faNumber(progress)}٪</span></div><div class="progress-track"><i style="width:${progress}%"></i></div><div class="progress-meta"><span>${formatBytes(item.bytesReceived)} / ${formatBytes(item.totalBytes)}</span><span>${item.speedBytes ? `${formatBytes(item.speedBytes)}/s` : '—'}</span><span>ETA ${eta(item.etaSeconds)}</span></div>${item.error ? `<div class="warning-box">${e(item.error)}</div>` : ''}</div><div class="queue-actions">${queueActions(item)}</div></article>`;
      }).join('')}</section>` : emptyState('⇩', 'صف دانلود خالی است', 'از کاتالوگ، یک یا چند مود را انتخاب و به صف اضافه کنید.', '<button class="primary-button" data-page-jump="catalog">رفتن به کاتالوگ</button>'));
  }

  function renderInstalled() {
    main.innerHTML = pageHead('Local Library', 'مودهای نصب‌شده', 'این فهرست فقط نصب‌های انجام‌شده توسط UHM Launcher را ثبت می‌کند. حذف مود عمداً در این نسخه پیاده‌سازی نشده است.', `<span class="tag">${faNumber(state.installed.length)} مود</span>`) +
      (state.installed.length ? `<div class="installed-table"><div class="table-row header"><span>مود</span><span>نسخه</span><span>مسیر نصب</span><span>تاریخ نصب</span><span>سازگاری CSP</span></div>${state.installed.map(item => `<div class="table-row"><div><b>${e(item.nameFa || item.modId)}</b><br><small>${faNumber(item.fileCount)} فایل ثبت‌شده</small></div><span dir="ltr">v${e(item.installedVersion)}</span><span class="path-text" title="${e(item.gamePath)}">${e(item.gamePath)}</span><small>${formatDate(item.installedAt)}</small><button class="text-button ${item.csp && item.csp.compatible ? 'compatible' : 'incompatible'}" data-open-mod="${e(item.modId)}">${item.csp && item.csp.compatible ? 'سازگار' : 'بررسی جزئیات'}</button></div>`).join('')}</div>` : emptyState('✓', 'هنوز مودی ثبت نشده است', 'پس از دانلود و تأیید نصب، اطلاعات مود و Manifest فایل‌ها در این بخش نمایش داده می‌شود.'));
  }

  function renderSettings() {
    const paths = state.settings.gamePaths || [];
    main.innerHTML = pageHead('Configuration', 'تنظیمات لانچر', 'مسیرهای بازی و رفتار دانلود را کنترل کنید. حذف یک مسیر از این فهرست هیچ فایل بازی را حذف نمی‌کند.', `<button class="primary-button" id="save-settings">ذخیره تنظیمات</button>`) + `
      <div class="settings-grid"><div>
        <section class="settings-section"><header class="settings-title"><h2>مسیرهای Assetto Corsa</h2><p>UHM مسیرهای Steam را شناسایی می‌کند؛ مسیر دستی باید شامل AssettoCorsa.exe و پوشه‌های content/cars و content/tracks باشد.</p></header><div class="settings-content">
          ${paths.length ? paths.map(path => `<label class="path-card"><input type="radio" name="default-path" value="${e(path.id)}" ${path.id === state.settings.defaultGamePathId ? 'checked' : ''} ${!path.isValid ? 'disabled' : ''}><span><b>${e(path.name)} ${path.source === 'steam' ? '<span class="tag">Steam</span>' : ''}</b><small class="${path.isValid ? '' : 'invalid'}">${e(path.path)}${path.isValid ? '' : ' — مسیر نامعتبر'}</small></span><button type="button" class="text-button" data-remove-path="${e(path.id)}">حذف از فهرست</button></label>`).join('') : '<div class="warning-box">مسیر Assetto Corsa پیدا نشد. یک مسیر دستی معتبر اضافه کنید.</div>'}
          <div class="form-grid" style="margin-top:15px"><div class="field"><label for="path-name">نام مسیر</label><input id="path-name" placeholder="مثلاً نصب اصلی"></div><div class="field"><label for="path-value">آدرس پوشه بازی</label><div class="input-with-button"><input id="path-value" dir="ltr" placeholder="D:\\SteamLibrary\\steamapps\\common\\assettocorsa"><button class="secondary-button" type="button" id="browse-game">انتخاب</button></div></div><div class="field full"><button class="secondary-button" id="add-game-path">+ افزودن و اعتبارسنجی مسیر</button></div></div>
        </div></section>
        <section class="settings-section"><header class="settings-title"><h2>دانلود و Cache</h2><p>حداکثر چهار دانلود هم‌زمان مجاز است. نصب‌ها همیشه برای جلوگیری از تداخل فایل به‌صورت قفل‌شده اجرا می‌شوند.</p></header><div class="settings-content"><div class="form-grid"><div class="field full"><label>پوشه دانلود</label><div class="input-with-button"><input id="download-directory" dir="ltr" value="${e(state.settings.downloadDirectory)}"><button class="secondary-button" id="browse-download">انتخاب</button></div></div><div class="field"><label>حداکثر دانلود هم‌زمان</label><select id="max-downloads">${[1,2,3,4].map(n => `<option value="${n}" ${Number(state.settings.maxConcurrentDownloads) === n ? 'selected' : ''}>${faNumber(n)}</option>`).join('')}</select></div></div>
          <div class="toggle-row"><div class="toggle-copy"><b>Cache کاتالوگ و تصاویر</b><small>در نبود اینترنت از آخرین نسخه معتبر استفاده می‌شود.</small></div><label class="switch"><input id="cache-enabled" type="checkbox" ${state.settings.cacheEnabled ? 'checked' : ''}><i></i></label></div>
          <button class="danger-button" id="clear-cache" style="margin-top:13px">پاک‌کردن Cache با تأیید</button>
        </div></section>
      </div><aside>
        <section class="settings-section"><header class="settings-title"><h2>آزمایش پیش‌نیازها</h2><p>نتیجه هر تست بدون تغییر خودکار سیستم نمایش داده می‌شود.</p></header><div class="settings-content diag-list"><button class="diag-button" data-diagnostic="connection"><span>تست اتصال GitHub</span><span>←</span></button><button class="diag-button" data-diagnostic="7zip"><span>تست 7-Zip</span><span>←</span></button><button class="diag-button" data-diagnostic="steam"><span>تست Steam و Libraryها</span><span>←</span></button></div></section>
        <section class="settings-section about-lockup"><span class="brand-mark"><i></i><i></i><i></i></span><h3>UHM LAUNCHER</h3><p>لانچر محلی و متن‌باز مدیریت مود Assetto Corsa<br>Windows 10 / 11</p><div class="version-pairs"><div><span>نسخه برنامه</span><b>${e(state.appVersion)}</b></div><div><span>نسخه کاتالوگ</span><b>${e(state.catalog.catalogVersion || '—')}</b></div><div><span>منبع کاتالوگ</span><b>${e(state.catalogSource)}</b></div></div></section>
      </aside></div>`;
  }

  function render() {
    updateChrome();
    ({ dashboard: renderDashboard, catalog: renderCatalog, queue: renderQueue, installed: renderInstalled, settings: renderSettings }[state.page] || renderDashboard)();
    main.focus({ preventScroll: true });
  }

  function openMod(id) {
    const mod = modById(id); if (!mod) { toast('اطلاعات این مود در کاتالوگ فعال وجود ندارد.', 'warn'); return; }
    const gallery = (mod.gallery || []).filter(url => safeUrl(url) !== '#');
    const compatibility = mod.compatibility || {};
    modalRoot.className = 'modal-root open';
    modalRoot.innerHTML = `<article class="modal" role="dialog" aria-modal="true" aria-labelledby="mod-title"><button class="modal-close" data-close-modal>×</button>
      <header class="detail-hero">${safeUrl(mod.image) !== '#' ? `<img src="${safeUrl(mod.image)}" alt="">` : ''}<div class="detail-copy"><div class="tags"><span class="category-chip">${e(categoryNames[mod.category] || mod.category)}</span>${mod.verified ? '<span class="category-chip">✓ تأییدشده</span>' : ''}${mod.passwordRequired ? '<span class="category-chip">رمزدار</span>' : ''}</div><h2 id="mod-title">${e(mod.nameFa)}</h2><p>${e(mod.name)} · ${e(mod.author)}</p></div></header>
      <div class="detail-body"><div><section class="detail-section"><h3>درباره مود</h3><p>${e(mod.description)}</p></section>
        ${gallery.length ? `<section class="detail-section"><h3>گالری</h3><div class="gallery-row">${gallery.map(url => `<div><img src="${safeUrl(url)}" alt="تصویر ${e(mod.nameFa)}" loading="lazy"></div>`).join('')}</div></section>` : ''}
        ${mod.dependencies?.length ? `<section class="detail-section"><h3>وابستگی‌ها</h3><div class="tags">${mod.dependencies.map(dep => `<span class="tag">${e(dep)}</span>`).join('')}</div></section>` : ''}
        ${mod.installInstructions?.length ? `<section class="detail-section"><h3>دستورالعمل نصب</h3><ol class="instruction-list">${mod.installInstructions.map(text => `<li>${e(text)}</li>`).join('')}</ol></section>` : ''}
        ${mod.activationSteps?.length ? `<section class="detail-section"><h3>فعال‌سازی پس از نصب</h3><ol class="instruction-list">${mod.activationSteps.map(text => `<li>${e(text)}</li>`).join('')}</ol></section>` : ''}
      </div><aside><div class="spec-list"><div><span>نسخه</span><b>${e(mod.version)}</b></div><div><span>حجم</span><b>${e(mod.sizeText)}</b></div><div><span>آرشیو</span><b>${e(mod.archiveType.toUpperCase())}</b></div><div><span>رمز</span><b>${mod.passwordRequired ? 'دارد' : 'ندارد'}</b></div><div><span>CSP</span><b>${mod.requiresCsp ? `حداقل ${e(mod.minCspVersion || 'نامشخص')}${mod.cspPreviewRequired ? ' Preview' : ''}` : 'نیاز ندارد'}</b></div><div><span>Pure</span><b>${e(compatibility.pure || 'unknown')}</b></div><div><span>Sol</span><b>${e(compatibility.sol || 'unknown')}</b></div><div><span>نوع نصب</span><b>${e(mod.installType)}</b></div><div><span>مسیر نصب</span><b>${e(mod.installRoot)}</b></div><div><span>به‌روزرسانی</span><b>${formatDate(mod.updatedAt)}</b></div></div>
        ${state.catalog.noticeFa ? `<div class="info-box">${e(state.catalog.noticeFa)}</div>` : ''}
        <div class="field" style="margin-top:13px"><label>مقصد نصب</label><select id="detail-target">${targetOptions()}</select></div>
        <div class="modal-actions"><button class="secondary-button" data-queue-mod="${e(mod.id)}" data-install="false">فقط دانلود</button><button class="primary-button" data-queue-mod="${e(mod.id)}" data-install="true" ${validPaths().length ? '' : 'disabled'}>دانلود و نصب</button></div>
        <div class="modal-actions"><a class="text-button" href="${safeUrl(mod.pageUrl)}" target="_blank" rel="noopener noreferrer">صفحه رسمی ↗</a><a class="text-button" href="${safeUrl(mod.downloadUrl)}" target="_blank" rel="noopener noreferrer">لینک دانلود ↗</a></div>
      </aside></div></article>`;
  }
  function closeModal() { modalRoot.className = 'modal-root'; modalRoot.innerHTML = ''; }

  async function addToQueue(modId, installAfter, targetId) {
    const response = await api('/api/queue', { method: 'POST', body: { modId, targetId: targetId || state.settings.defaultGamePathId || '', installAfterDownload: !!installAfter } });
    state.queue.push(response.item); toast(response.message); updateChrome();
  }
  async function refreshCatalog() {
    if (state.refreshing) return; state.refreshing = true; $('#refresh-button')?.classList.add('loading'); $('#catalog-refresh')?.setAttribute('disabled', '');
    try {
      const result = await api('/api/catalog/refresh', { method: 'POST', body: {} });
      state.catalog = result.catalog; state.catalogSource = result.source; state.offline = result.offline; state.settings.lastCatalogRefresh = result.refreshedAt;
      toast(result.message, result.success ? 'success' : 'warn'); render();
    } catch (error) { toast(error.message, 'error'); }
    finally { state.refreshing = false; $('#refresh-button')?.classList.remove('loading'); }
  }

  async function queueCommand(id, action) {
    try {
      let body = {};
      if (action === 'remove') {
        if (!confirm('آیا این رکورد از صف حذف شود؟ فایل بازی حذف نخواهد شد.')) return;
        const deletePartial = confirm('آیا فایل دانلود ناقص/دانلودشده هم حذف شود؟ «لغو» آن را نگه می‌دارد.');
        body = { confirmed: true, deletePartial };
      }
      const result = await api(`/api/queue/${id}/${action}`, { method: 'POST', body }); state.queue = result.queue || state.queue; render();
    } catch (error) { toast(error.message, 'error'); }
  }
  async function requestInstallPreview(id, confirmReinstall = false) {
    const targetId = state.settings.defaultGamePathId || '';
    try {
      const result = await api(`/api/queue/${id}/install-preview`, { method: 'POST', body: { targetId, confirmReinstall } });
      const item = state.queue.find(row => row.id === id); if (item) { item.status = 'awaitingConfirmation'; item.previewId = result.preview.id; item.overwrites = result.preview.overwrites; item.executableFiles = result.preview.executableFiles; item.csp = result.preview.csp; }
      showInstallConfirmation(id, result.preview);
    } catch (error) {
      if (!confirmReinstall && error.message.includes('قبلاً نصب')) {
        if (confirm('این مود قبلاً نصب شده است. آیا پیش‌نمایش نصب مجدد ساخته شود؟')) return requestInstallPreview(id, true);
      }
      toast(error.message, 'error');
    }
  }
  function showInstallConfirmation(id, preview) {
    const overwrites = preview.overwrites || []; const executables = preview.executableFiles || []; const csp = preview.csp || {};
    modalRoot.className = 'modal-root open'; modalRoot.innerHTML = `<article class="modal small" role="dialog" aria-modal="true"><button class="modal-close" data-close-modal>×</button><div class="detail-body" style="display:block"><h2>تأیید نهایی نصب</h2><p class="muted">${faNumber(preview.fileCount || 0)} فایل با حجم ${formatBytes(preview.totalBytes || 0)} آماده نصب است.</p>
      ${!csp.compatible ? `<div class="warning-box">${e(csp.message || 'نسخه CSP شما با این مود سازگار نیست.')} نصب فقط در صورت blockInstall متوقف می‌شود.</div>` : '<div class="info-box">بررسی CSP بدون هشدار جدی انجام شد.</div>'}
      ${executables.length ? `<div class="warning-box">${faNumber(executables.length)} فایل اجرایی یا اسکریپت شناسایی شد. UHM هیچ‌کدام را اجرا نمی‌کند؛ فقط در صورت تأیید شما کپی می‌شوند.<div class="overwrite-list">${executables.map(e).join('\n')}</div></div>` : ''}
      ${overwrites.length ? `<div class="warning-box"><b>فایل‌های زیر جایگزین خواهند شد.</b><div class="overwrite-list">${overwrites.map(e).join('\n')}</div><label class="filter-chip"><input id="approve-overwrite" type="checkbox"> جایگزینی این فایل‌ها را تأیید می‌کنم</label></div>` : '<div class="info-box">در زمان ساخت پیش‌نمایش، فایل موجودی برای جایگزینی پیدا نشد.</div>'}
      <div class="info-box">بازی و Content Manager پس از نصب اجرا نمی‌شوند. UHM هیچ فایل بازی را حذف نمی‌کند.</div><div class="modal-actions"><button class="secondary-button" data-close-modal>لغو</button><button class="primary-button" data-final-install="${e(id)}">تأیید و نصب</button></div></div></article>`;
  }
  async function confirmInstall(id) {
    const item = state.queue.find(row => row.id === id); const hasOverwrites = (item?.overwrites || []).length > 0; const checkbox = $('#approve-overwrite');
    if (hasOverwrites && !checkbox?.checked) { toast('ابتدا تأیید جایگزینی فایل‌ها را فعال کنید.', 'warn'); return; }
    try { const result = await api(`/api/queue/${id}/install-confirm`, { method: 'POST', body: { confirmed: true, approveOverwrite: hasOverwrites } }); closeModal(); toast(result.result.message); await pollInstalled(); }
    catch (error) { toast(error.message, 'error'); }
  }

  async function saveSettings() {
    try {
      const checked = $('input[name="default-path"]:checked'); const body = { maxConcurrentDownloads: Number($('#max-downloads').value), cacheEnabled: $('#cache-enabled').checked, downloadDirectory: $('#download-directory').value.trim() };
      if (checked) body.defaultGamePathId = checked.value;
      const result = await api('/api/settings', { method: 'POST', body }); state.settings = result.settings; toast(result.message); renderSettings();
    } catch (error) { toast(error.message, 'error'); }
  }
  async function selectFolder(inputId) {
    try { const result = await api('/api/settings/select-folder', { method: 'POST', body: {} }); if (result.path) $(inputId).value = result.path; }
    catch (error) { toast(error.message, 'error'); }
  }
  async function diagnostic(kind) {
    try { const result = await api('/api/diagnostics', { method: 'POST', body: { kind } }); toast(result.message || (result.success ? 'تست موفق بود.' : 'تست ناموفق بود.'), result.success ? 'success' : 'warn'); }
    catch (error) { toast(error.message, 'error'); }
  }

  function navigate(page) {
    if (!['dashboard', 'catalog', 'queue', 'installed', 'settings'].includes(page)) return;
    state.page = page; history.replaceState(null, '', `#${page}`); render(); window.scrollTo({ top: 0, behavior: 'smooth' });
  }

  document.addEventListener('click', async event => {
    const target = event.target.closest('button, a, [data-open-mod]'); if (!target) return;
    if (target.dataset.page) navigate(target.dataset.page);
    if (target.dataset.pageJump) navigate(target.dataset.pageJump);
    if (target.dataset.openMod) openMod(target.dataset.openMod);
    if (target.matches('[data-close-modal]') || target === modalRoot) closeModal();
    if (target.id === 'refresh-button' || target.id === 'catalog-refresh') refreshCatalog();
    if (target.dataset.view) { state.view = target.dataset.view; renderCatalog(); }
    if (target.id === 'clear-selection') { state.selected.clear(); renderCatalog(); }
    if (target.id === 'add-selected') {
      const installAfter = !!$('#selected-auto-install')?.checked;
      target.disabled = true; let added = 0;
      for (const id of state.selected) { try { await addToQueue(id, installAfter, state.settings.defaultGamePathId); added++; } catch (error) { toast(`${modById(id)?.nameFa || id}: ${error.message}`, 'error'); } }
      state.selected.clear(); toast(`${faNumber(added)} مود به صف اضافه شد.`); navigate('queue');
    }
    if (target.dataset.queueMod) {
      try { await addToQueue(target.dataset.queueMod, target.dataset.install === 'true', $('#detail-target')?.value); closeModal(); navigate('queue'); }
      catch (error) { toast(error.message, 'error'); }
    }
    if (target.dataset.queueAction) queueCommand(target.dataset.id, target.dataset.queueAction);
    if (target.dataset.installPreview) requestInstallPreview(target.dataset.installPreview);
    if (target.dataset.confirmExisting) {
      const item = state.queue.find(row => row.id === target.dataset.confirmExisting);
      showInstallConfirmation(item.id, { fileCount: item.fileCount || 0, totalBytes: item.installBytes || 0, overwrites: item.overwrites || [], executableFiles: item.executableFiles || [], csp: item.csp || {} });
    }
    if (target.dataset.finalInstall) confirmInstall(target.dataset.finalInstall);
    if (target.id === 'save-settings') saveSettings();
    if (target.id === 'browse-game') selectFolder('#path-value');
    if (target.id === 'browse-download') selectFolder('#download-directory');
    if (target.id === 'add-game-path') {
      try { const result = await api('/api/settings/paths', { method: 'POST', body: { name: $('#path-name').value.trim(), path: $('#path-value').value.trim() } }); state.settings = result.settings; toast(result.message); renderSettings(); }
      catch (error) { toast(error.message, 'error'); }
    }
    if (target.dataset.removePath) {
      if (!confirm('این مسیر فقط از فهرست حذف شود؟ هیچ فایل بازی حذف نخواهد شد.')) return;
      try { const result = await api(`/api/settings/paths/${encodeURIComponent(target.dataset.removePath)}`, { method: 'DELETE', body: { confirmed: true } }); state.settings = result.settings; toast(result.message); renderSettings(); }
      catch (error) { toast(error.message, 'error'); }
    }
    if (target.id === 'clear-cache') {
      if (!confirm('Cache کاتالوگ و تصاویر پاک شود؟ فایل‌های بازی و دانلودها حذف نمی‌شوند.')) return;
      try { const result = await api('/api/settings/cache/clear', { method: 'POST', body: { confirmed: true } }); toast(result.message); }
      catch (error) { toast(error.message, 'error'); }
    }
    if (target.dataset.diagnostic) diagnostic(target.dataset.diagnostic);
    if (target.id === 'exit-button') {
      if (!confirm('Bridge محلی بسته شود؟ دانلودهای فعال متوقف می‌شوند اما فایل ناقص باقی می‌ماند.')) return;
      try { await api('/api/shutdown', { method: 'POST', body: {} }); sessionStorage.removeItem('uhm-bridge-token'); main.innerHTML = emptyState('⏻', 'UHM Launcher بسته شد', 'اکنون می‌توانید این برگه را ببندید. دانلود ناقص برای ادامه بعدی نگه‌داری شده است.'); }
      catch (error) { toast(error.message, 'error'); }
    }
  });

  document.addEventListener('change', event => {
    const input = event.target;
    if (input.dataset.selectMod) { input.checked ? state.selected.add(input.dataset.selectMod) : state.selected.delete(input.dataset.selectMod); renderCatalog(); }
    const filterMap = { 'category-filter': 'category', 'sort-filter': 'sort', 'version-filter': 'version', 'csp-filter': 'csp', 'password-filter': 'password', 'installed-filter': 'installed' };
    if (filterMap[input.id]) { state.filters[filterMap[input.id]] = input.value; renderCatalog(); }
  });
  document.addEventListener('input', event => {
    if (event.target.id === 'catalog-query') { state.filters.query = event.target.value; const position = event.target.selectionStart; renderCatalog(); const next = $('#catalog-query'); next.focus(); next.setSelectionRange(position, position); }
    if (event.target.id === 'global-search') { state.filters.query = event.target.value; if (state.page !== 'catalog') navigate('catalog'); else renderCatalog(); }
  });
  document.addEventListener('keydown', event => {
    if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === 'k') { event.preventDefault(); $('#global-search').focus(); }
    if (event.key === 'Escape' && modalRoot.classList.contains('open')) closeModal();
    if (event.key === 'Enter' && event.target.dataset.openMod) openMod(event.target.dataset.openMod);
  });
  document.addEventListener('error', event => { if (event.target instanceof HTMLImageElement) event.target.style.display = 'none'; }, true);

  async function pollQueue() {
    try {
      const result = await api('/api/queue'); state.queue = result.queue || [];
      if (state.page === 'queue') renderQueue(); updateChrome();
    } catch { $('#bridge-dot').className = 'status-dot offline'; $('#bridge-label').textContent = 'قطع'; }
  }
  async function pollInstalled() {
    try { const result = await api('/api/installed'); state.installed = result.installed || []; if (state.page === 'installed' || state.page === 'queue') render(); }
    catch { /* heartbeat handles connection state */ }
  }
  async function heartbeat() {
    try { await api('/api/heartbeat', { method: 'POST', body: {} }); $('#bridge-dot').className = 'status-dot online'; $('#bridge-label').textContent = 'متصل'; }
    catch { $('#bridge-dot').className = 'status-dot offline'; $('#bridge-label').textContent = 'قطع'; }
  }

  async function boot() {
    state.token = getToken();
    if (!state.token) { main.innerHTML = emptyState('!', 'توکن اجرای محلی پیدا نشد', 'برنامه را فقط با فایل UHM-Launcher.cmd اجرا کنید. بازکردن مستقیم index.html پشتیبانی نمی‌شود.'); return; }
    try {
      const data = await api('/api/bootstrap');
      Object.assign(state, { catalog: data.catalog, catalogSource: data.catalogSource, offline: data.offline, settings: data.settings, steam: data.steam, queue: data.queue, installed: data.installed, stats: data.stats, appVersion: data.appVersion });
      const hashPage = location.hash.slice(1); state.page = ['dashboard', 'catalog', 'queue', 'installed', 'settings'].includes(hashPage) ? hashPage : 'dashboard';
      $('#side-version').textContent = state.appVersion; render();
      setInterval(pollQueue, 1200); setInterval(pollInstalled, 12000); setInterval(heartbeat, 10000);
    } catch (error) {
      main.innerHTML = emptyState('!', 'ارتباط با Local Bridge برقرار نشد', `${error.message} برنامه را دوباره از طریق UHM-Launcher.cmd اجرا کنید.`);
      $('#bridge-dot').className = 'status-dot offline'; $('#bridge-label').textContent = 'قطع';
    }
  }
  boot();
})();
