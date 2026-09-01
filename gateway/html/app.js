/* databases-stack dashboard — bağımlılıksız, tek dosya.
   Bütün karar mantığı controller'da; burası yalnız gösterim ve onay akışı. */
'use strict';

const API = '/api';
const $  = (s) => document.querySelector(s);

let CATALOG = null;
let STATE   = { engines: [], system: {}, plans: {} };
let timer   = null;

/* ---------------------------------------------------------------- yardımcı */
async function api(path, opts) {
  const r = await fetch(API + path, opts);
  if (!r.ok) throw new Error((await r.text()) || ('HTTP ' + r.status));
  return r.json();
}
const mb = (v) => (v == null ? '—'
  : v >= 1024 ? (v / 1024).toFixed(v >= 10240 ? 0 : 1) + ' GB' : Math.round(v) + ' MB');
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* ------------------------------------------------------------- pencereler */
function confirmBox(title, bodyHtml, okLabel = 'Devam') {
  return new Promise((resolve) => {
    $('#modal-title').textContent = title;
    $('#modal-body').innerHTML = bodyHtml;
    $('#modal-ok').textContent = okLabel;
    $('#modal-ok').hidden = false;
    $('#modal').hidden = false;
    const close = (v) => { $('#modal').hidden = true; resolve(v); };
    $('#modal-ok').onclick     = () => close(true);
    $('#modal-cancel').onclick = () => close(false);
  });
}
function infoBox(title, bodyHtml) {
  $('#modal-title').textContent = title;
  $('#modal-body').innerHTML = bodyHtml;
  $('#modal-ok').hidden = true;
  $('#modal').hidden = false;
  $('#modal-cancel').textContent = 'Kapat';
  $('#modal-cancel').onclick = () => {
    $('#modal').hidden = true;
    $('#modal-cancel').textContent = 'Vazgeç';
    $('#modal-ok').hidden = false;
  };
}

/* Aktivasyon uzun sürebilir (imaj indirme) — işi arka planda izleyip
   log'u canlı gösteriyoruz ki kullanıcı "takıldı mı?" diye merak etmesin. */
async function watchJob(jobId, title) {
  $('#job-title').textContent = title;
  $('#job-log').textContent = '';
  $('#job-close').disabled = true;
  $('#job').hidden = false;
  $('#job-close').onclick = () => { $('#job').hidden = true; };

  for (;;) {
    let job;
    try { job = await api('/jobs/' + jobId); }
    catch (e) { $('#job-log').textContent += '\nDurum alınamadı: ' + e.message; break; }

    $('#job-log').textContent = job.log.join('\n');
    $('#job-log').scrollTop = $('#job-log').scrollHeight;

    if (job.state !== 'running') {
      $('#job-title').textContent = job.state === 'done' ? '✅ Tamamlandı' : '⛔ Başarısız';
      if (job.reason) $('#job-log').textContent += '\n\n' + job.reason;
      break;
    }
    await new Promise((r) => setTimeout(r, 1200));
  }
  $('#job-close').disabled = false;
  refresh();
}

/* ------------------------------------------------------------------ eylem */
async function activate(engine) {
  const plan = STATE.plans[engine.id];

  if (plan && !plan.ok) {
    infoBox(engine.name + ' şu an açılamıyor', `
      <p>${esc(plan.reason)}</p>
      <div class="plan-line"><span>Sunucu toplam belleği</span><b>${mb(plan.host_total_mb)}</b></div>
      <div class="plan-line"><span>Zaten açık veritabanları</span><b>${mb(plan.committed_mb)}</b></div>
      <div class="plan-line"><span>Bu veritabanı için gereken en az</span><b>${mb(plan.min_mb + plan.overhead_mb)}</b></div>
      <p class="note">Açık bir veritabanını kapatırsanız bu kart tekrar
      kullanılabilir hâle gelir.</p>`);
    return;
  }

  const t = plan ? plan.tuning : {};
  const rows = Object.keys(t).sort()
    .map((k) => `<div class="plan-line"><span>${esc(k)}</span><b>${esc(t[k])}</b></div>`)
    .join('');

  const ok = await confirmBox(engine.name + ' açılsın mı?', `
    <p>Sistem sunucunuzu ölçtü ve bu veritabanı için aşağıdaki ayarları seçti.
       Elle bir şey girmeniz gerekmiyor.</p>
    <div class="plan-line"><span>Ayrılacak bellek</span><b>${mb(plan.limit_mb)}</b></div>
    <div class="plan-line"><span>İşlem sonrası boşta kalacak</span><b>${mb(plan.headroom_mb)}</b></div>
    <details style="margin-top:12px">
      <summary style="cursor:pointer;color:var(--muted);font-size:13px">
        Hesaplanan teknik ayarlar (bilgi amaçlı)</summary>
      <div style="margin-top:8px">${rows}</div>
    </details>
    <p class="note">İlk açılışta veritabanı imajı indirileceği için birkaç dakika sürebilir.</p>`,
    'Aktif Et');
  if (!ok) return;

  const r = await api('/engines/' + engine.id + '/activate', { method: 'POST' });
  watchJob(r.job, engine.name + ' açılıyor…');
}

async function deactivate(engine) {
  const ok = await confirmBox(engine.name + ' kapatılsın mı?', `
    <p>Veritabanı durdurulur ve belleği serbest kalır.</p>
    <p class="note"><b>Verileriniz silinmez.</b> Diskte kalır; tekrar
    “Aktif Et” dediğinizde her şey yerinde olur.</p>`, 'Kapat');
  if (!ok) return;
  const r = await api('/engines/' + engine.id + '/deactivate', { method: 'POST' });
  watchJob(r.job, engine.name + ' kapatılıyor…');
}

async function toggleReplication(engine, on) {
  const rep = engine.replication || {};
  const ok = await confirmBox(
    on ? 'Yedek kopya (replika) açılsın mı?' : 'Replika kapatılsın mı?',
    on ? `<p>${esc(engine.name)} için ikinci bir kopya kurulur ve ana kopyadaki
             her değişiklik otomatik olarak buraya da yazılır.</p>
          <p class="note">${esc(rep.note || '')}</p>
          <p class="note">Bu ek bellek tüketir; sistem yer olup olmadığını kontrol eder.</p>`
       : `<p>Replika durdurulur. Ana kopya etkilenmez.</p>`,
    on ? 'Replika Kur' : 'Kapat');
  if (!ok) return;
  const act = on ? 'replication-enable' : 'replication-disable';
  const r = await api('/engines/' + engine.id + '/' + act, { method: 'POST' });
  watchJob(r.job, 'Replikasyon güncelleniyor…');
}

async function toggleAutoFailover(engine, on) {
  const fo = engine.failover || {};
  const ok = await confirmBox(
    on ? 'Otomatik devir açılsın mı?' : 'Otomatik devir kapatılsın mı?',
    on ? `<p>Sistem ana kopyayı sürekli izler. Üst üste birkaç kez yanıt
             vermezse <b>otomatik olarak</b> yedek kopyayı devreye alır ve
             uygulamalarınızın bağlantısını oraya yönlendirir.</p>
          <p class="note">Bağlantı adresiniz değişmez — yönlendirmeyi sistem yapar.</p>
          <p class="note">${esc(fo.note || '')}</p>
          <p class="note"><b>Önemli:</b> devir sırasında ana kopya durdurulur.
             Bu, iki kopyanın aynı anda yazı kabul edip verilerin ayrışmasını
             (split-brain) önlemek için zorunludur.</p>`
       : `<p>İzleme durur. Ana kopya çökerse devir <b>elle</b> yapılır.</p>`,
    on ? 'Aç' : 'Kapat');
  if (!ok) return;
  await api('/engines/' + engine.id + '/failover-auto',
            { method: 'POST', headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ enabled: on }) });
  refresh();
}

async function rebuildStandby(engine) {
  const ok = await confirmBox('Eski kopya yeniden kurulsun mu?', `
    <p>Devirden sonra durdurulan eski kopya, yeni ana kopyanın <b>yedeği</b>
       olarak baştan kurulur.</p>
    <p class="note"><b>Eski kopyadaki veriler silinir</b> ve yeni ana kopyadan
       baştan kopyalanır. Bu bilinçlidir: iki kopyanın geçmişi devir anında
       ayrıştığı için eski veriyi korumak tutarsızlık yaratırdı.</p>`,
    'Yeniden Kur');
  if (!ok) return;
  const r = await api('/engines/' + engine.id + '/rebuild-standby', { method: 'POST' });
  watchJob(r.job, 'Yedek kopya yeniden kuruluyor…');
}

async function showConnection(engine) {
  let c;
  try { c = await api('/engines/' + engine.id + '/connection'); }
  catch (e) { return infoBox('Bağlantı bilgisi alınamadı', '<p>' + esc(e.message) + '</p>'); }

  const field = (label, value) => `
    <p style="margin:12px 0 0;font-size:13px;color:var(--muted)">${esc(label)}</p>
    <div class="copy-row">
      <input readonly value="${esc(value)}">
      <button class="btn" onclick="navigator.clipboard.writeText(this.previousElementSibling.value);this.textContent='Kopyalandı'">Kopyala</button>
    </div>`;

  infoBox(engine.name + ' bağlantı bilgileri',
    `<p>Uygulamanızın bu veritabanına bağlanmak için kullanacağı bilgiler:</p>
     ${c.uri ? field('Bağlantı adresi (connection string)', c.uri) : ''}
     ${field('Sunucu', c.host)}
     ${field('Port', c.port)}
     ${c.username ? field('Kullanıcı', c.username) : ''}
     ${c.password ? field('Parola', c.password) : ''}
     ${c.database ? field('Veritabanı', c.database) : ''}
     <p class="note">Bu bilgiler yönetici parolasına aittir. Uygulamalarınız için
     yetkisi kısıtlı ayrı bir kullanıcı oluşturmanız önerilir:
     <code>./stack.sh app-user</code></p>`);
}

/* ------------------------------------------------------------------ çizim */
function cardHtml(engine, st, plan) {
  const p = engine.plain || {};
  const rep = engine.replication || {};
  const blocked = !st.active && plan && !plan.ok;

  let badge = '<span class="badge off">Kapalı</span>';
  if (st.active && st.health === 'starting') badge = '<span class="badge busy">Başlatılıyor</span>';
  else if (st.active && st.health === 'unhealthy') badge = '<span class="badge err">Sorunlu</span>';
  else if (st.active) badge = '<span class="badge on">Çalışıyor</span>';

  const facts = st.active ? `
    <dl class="facts">
      <dt>Ayrılan bellek</dt><dd>${mb(st.memory_mb)}</dd>
      <dt>Bağlantı portu</dt><dd>${engine.client_ports.map((x) => x.port).join(', ')}</dd>
      ${st.replication_active ? '<dt>Replika</dt><dd>çalışıyor</dd>' : ''}
    </dl>` : (blocked
      ? `<div class="blocked-note">${esc(plan.reason)}</div>`
      : `<dl class="facts">
           <dt>Tahmini bellek</dt><dd>${plan && plan.ok ? mb(plan.limit_mb) : '—'}</dd>
           <dt>Durum</dt><dd>Bu sunucuda açılabilir</dd>
         </dl>`);

  const panelBtn = (engine.panel && st.active)
    ? `<button class="btn" data-act="panel" data-id="${engine.id}">${esc(engine.panel.name)} aç</button>` : '';
  const connBtn = st.active
    ? `<button class="btn" data-act="conn" data-id="${engine.id}">Bağlantı bilgisi</button>` : '';

  let repBtn = '';
  if (st.active && (rep.mode === 'primary-replica' || rep.mode === 'replica-set')) {
    repBtn = st.replication_active
      ? `<button class="btn btn-link" data-act="rep-off" data-id="${engine.id}">Replikayı kapat</button>`
      : `<button class="btn btn-link" data-act="rep-on"  data-id="${engine.id}">Replika kur</button>`;
  }

  // --- otomatik failover ---
  const fo = engine.failover || {};
  let foBtn = '';
  if (st.active && st.replication_active && fo.supported && fo.mode === 'supervised') {
    foBtn = st.auto_failover
      ? `<button class="btn btn-link" data-act="fo-off" data-id="${engine.id}">Otomatik devri kapat</button>`
      : `<button class="btn btn-link" data-act="fo-on"  data-id="${engine.id}">Otomatik devri aç</button>`;
  }
  // Failover yaşanmışsa: eski kopyayı yeniden replika yapma seçeneği
  const rebuildBtn = st.failed_over
    ? `<button class="btn" data-act="rebuild" data-id="${engine.id}">Eski kopyayı yeniden kur</button>`
    : '';

  const main = st.active
    ? `<button class="btn btn-danger" data-act="off" data-id="${engine.id}">Kapat</button>`
    : `<button class="btn btn-primary" data-act="on" data-id="${engine.id}"
         ${blocked ? 'title="Sunucuda yeterli bellek yok"' : ''}>Aktif Et</button>`;

  return `
  <article class="card ${st.active ? 'is-active' : ''} ${blocked ? 'is-blocked' : ''}">
    <div class="card-head">
      <span class="card-icon">${engine.icon}</span>
      <div>
        <h3>${esc(engine.name)}</h3>
        <p class="card-plain">${esc(p.title || engine.summary)}</p>
      </div>
      ${badge}
    </div>
    ${p.badge ? `<div><span class="tag">${esc(p.badge)}</span></div>` : ''}
    <p class="card-detail">${esc(p.detail || '')}</p>
    ${facts}
    ${st.failed_over ? `<div class="blocked-note">⚠ Devir yapıldı — şu an
        <b>${esc(st.primary_service || '')}</b> ana kopya. Eski kopya durduruldu;
        yeniden yedek olarak kurabilirsiniz.</div>` : ''}
    ${st.auto_failover ? '<div><span class="tag">Otomatik devir açık</span></div>' : ''}
    <div class="card-actions">${main}${panelBtn}${connBtn}${rebuildBtn}${repBtn}${foBtn}</div>
  </article>`;
}

function render() {
  const sys = STATE.system || {};
  $('#sys-host').textContent = location.hostname;
  $('#sys-cpu').textContent  = (sys.cpus || '—') + ' çekirdek';
  $('#sys-disk').textContent = mb(sys.disk_free_mb) + ' boş';

  if (sys.mem_total_mb) {
    const used = sys.mem_total_mb - (sys.mem_available_mb || 0);
    const pct  = Math.min(100, Math.round((used / sys.mem_total_mb) * 100));
    $('#sys-mem').textContent = mb(used) + ' / ' + mb(sys.mem_total_mb);
    const bar = $('#sys-mem-bar');
    bar.style.width = pct + '%';
    bar.className = 'meter-fill' + (pct > 90 ? ' crit' : pct > 75 ? ' hot' : '');
  }

  const banner = $('#banner');
  if (STATE.preflight_error) {
    banner.textContent = 'Kurulum eksik: ' + STATE.preflight_error;
    banner.hidden = false;
  } else banner.hidden = true;

  const byId = {};
  (STATE.engines || []).forEach((e) => { byId[e.id] = e; });

  const cats = CATALOG.categories || {};
  const order = Object.keys(cats);
  let html = '';
  order.forEach((cat) => {
    const list = CATALOG.engines.filter((e) => e.category === cat);
    if (!list.length) return;
    html += `<h2 class="cat-title">${esc(cats[cat])}</h2>`;
    list.forEach((e) => {
      html += cardHtml(e, byId[e.id] || { active: false }, STATE.plans[e.id]);
    });
  });
  $('#grid').innerHTML = html;
}

/* ------------------------------------------------------------------ döngü */
function renderEvents(events) {
  const box = document.getElementById('events');
  if (!box) return;
  if (!events.length) { box.innerHTML = '<p class="card-detail">Henüz olay yok.</p>'; return; }
  const icon = { info: 'ℹ️', warning: '⚠️', critical: '🚨' };
  box.innerHTML = events.slice().reverse().slice(0, 25).map((e) => `
    <div class="event event-${esc(e.level)}">
      <span class="event-time">${new Date(e.ts * 1000).toLocaleString('tr-TR')}</span>
      <span>${icon[e.level] || '•'} <b>${esc(e.engine)}</b> — ${esc(e.message)}</span>
    </div>`).join('');
}

async function refresh() {
  try {
    const [st, plans, ev] = await Promise.all([
      api('/status'), api('/plans'), api('/events').catch(() => ({ events: [] }))]);
    STATE = Object.assign({}, st, { plans: plans.plans || {} });
    render();
    renderEvents(ev.events || []);
  } catch (e) {
    $('#banner').textContent = 'Kontrol servisine ulaşılamıyor: ' + e.message;
    $('#banner').hidden = false;
  }
}

document.addEventListener('click', (ev) => {
  const b = ev.target.closest('[data-act]');
  if (!b) return;
  const engine = CATALOG.engines.find((e) => e.id === b.dataset.id);
  const st = (STATE.engines || []).find((e) => e.id === b.dataset.id) || {};
  switch (b.dataset.act) {
    case 'on':      return activate(engine);
    case 'off':     return deactivate(engine);
    case 'conn':    return showConnection(engine);
    case 'rep-on':  return toggleReplication(engine, true);
    case 'rep-off': return toggleReplication(engine, false);
    case 'fo-on':   return toggleAutoFailover(engine, true);
    case 'fo-off':  return toggleAutoFailover(engine, false);
    case 'rebuild': return rebuildStandby(engine);
    case 'panel': {
      // Paneller gateway üzerinde kendi HTTPS portlarında durur.
      const url = 'https://' + location.hostname + ':' + engine.panel.port +
                  (engine.panel.path || '/');
      return window.open(url, '_blank', 'noopener');
    }
  }
});

(async function init() {
  try {
    CATALOG = await api('/catalog');
  } catch (e) {
    // Controller kapalıysa dashboard yine de motor listesini gösterebilsin.
    CATALOG = await (await fetch('catalog.json')).json();
  }
  await refresh();
  timer = setInterval(refresh, 5000);
})();
