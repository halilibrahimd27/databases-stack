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
      <div class="plan-line"><span>İşletim sistemi payı</span><b>${mb(plan.os_reserve_mb)}</b></div>
      <div class="plan-line"><span>Açık veritabanlarına ayrılan</span><b>${mb(plan.committed_mb)}</b></div>
      <div class="plan-line"><span>Bu veritabanı için gereken en az</span><b>${mb(plan.min_mb + plan.overhead_mb)}</b></div>
      <p class="note"><b>Neden "boş bellek var" ama açılmıyor?</b>
      Ayrılan bellek, açık veritabanlarının <b>büyüyebileceği üst sınırdır</b> —
      şu anki gerçek kullanımları daha düşük olabilir. Bu sınırlar söz verilmiş
      olduğu için yeniden dağıtılamaz; aksi halde iki veritabanı aynı anda
      büyüdüğünde işletim sistemi birini öldürürdü.</p>
      <p class="note">Açık bir veritabanını kapatırsanız bu kart tekrar
      kullanılabilir hâle gelir.</p>`);
    return;
  }

  const t = plan ? plan.tuning : {};
  const rows = Object.keys(t).sort()
    .map((k) => `<div class="plan-line"><span>${esc(k)}</span><b>${esc(t[k])}</b></div>`)
    .join('');

  const lic = engine.license || {};
  const licWarn = lic.free_for_production === false
    ? `<div class="blocked-note" style="margin-bottom:12px">
         <b>⚠️ Lisans uyarısı — ${esc(lic.name)}</b><br>${esc(lic.note)}
         ${lic.alternative ? '<br><b>Alternatif:</b> ' + esc(lic.alternative) : ''}
       </div>` : '';

  const ok = await confirmBox(engine.name + ' açılsın mı?', `
    ${licWarn}
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

  // "tool" türü kayıtlar (izleme gibi) veritabanı değildir: istemcinin
  // bağlanacağı bir port, bağlantı bilgisi ya da yedek kopyası yoktur.
  // Kartta o düğmeleri göstermek, kullanıcıya olmayan bir şey vaat etmektir.
  const isTool = engine.kind === 'tool';
  const ports = (engine.client_ports || []).map((x) => x.port).join(', ');

  const facts = st.active ? `
    <dl class="facts">
      <dt>Ayrılan bellek</dt><dd>${mb(st.memory_mb)}</dd>
      ${ports ? `<dt>Bağlantı portu</dt><dd>${ports}</dd>` : ''}
      ${st.replication_active ? '<dt>Replika</dt><dd>çalışıyor</dd>' : ''}
    </dl>` : (blocked
      ? `<div class="blocked-note">${esc(plan.reason)}</div>`
      : `<dl class="facts">
           <dt>Tahmini bellek</dt><dd>${plan && plan.ok ? mb(plan.limit_mb) : '—'}</dd>
           <dt>Durum</dt><dd>Bu sunucuda açılabilir</dd>
         </dl>`);

  const panelBtn = (engine.panel && st.active)
    ? `<button class="btn" data-act="panel" data-id="${engine.id}">${esc(engine.panel.name)} aç</button>` : '';
  const connBtn = (st.active && !isTool)
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

  const lic = engine.license || {};
  const licClass = lic.free_for_production === false ? 'lic-warn'
                 : lic.free_for_production === 'copyleft' ? 'lic-note' : 'lic-ok';
  const licLine = lic.name
    ? `<div class="lic ${licClass}" title="${esc(lic.note || '')}">
         ${lic.free_for_production === false ? '⚠️' : '⚖️'} ${esc(lic.name)}
         ${lic.free_for_production === false ? ' — üretimde lisans gerekir' : ''}
       </div>` : '';

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
        <b>${esc(st.primary_service || '')}</b> ana kopya. Uygulamanız aynı
        adrese bağlanmaya devam eder. Rolleri normale döndürmek için
        "Eski kopyayı yeniden kur" deyin.</div>` : ''}
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
    // Üst barda AYRILAN belleği (tavanları) gösteriyoruz, gerçek kullanımı
    // değil: karar mekanizması tavanlara göre çalışır. Bir motorun limiti, o
    // motorun büyüyebileceği üst sınırdır ve o kadarı ona söz verilmiştir.
    // Gerçek kullanımı gösterip bütçeyi tavanlara göre reddetmek "14 GB boş
    // ama açılmıyor" gibi çelişkili görünüyordu; ikisini birlikte veriyoruz.
    //
    // PAYDA, sunucunun TOPLAM RAM'i DEĞİL "dağıtılabilir" belleğidir
    // (toplam − işletim sistemi payı − çekirdek servisler). Eskiden pay olarak
    // tavanlara işletim sistemi payı da eklenip toplam RAM'e bölünüyordu ve
    // ekranda "19 GB / 16 GB" gibi imkânsız görünen bir oran çıkıyordu —
    // sayı doğruydu ama okuyan haklı olarak ürünü bozuk sanıyordu. Şimdi
    // karşılaştırma anlamlı olan iki şey arasında: ne kadarını dağıtabilirim,
    // ne kadarını dağıttım.
    const alloc    = sys.stack_committed_mb || 0;
    const reserved = (sys.os_reserve_mb || 0) + (sys.core_reserve_mb || 0);
    const dagitilabilir = Math.max(0, (sys.mem_total_mb || 0) - reserved);
    const real = sys.mem_total_mb - (sys.mem_available_mb || 0);
    const pct  = dagitilabilir ? Math.round((alloc / dagitilabilir) * 100) : 0;
    const asim = pct > 100;

    $('#sys-mem').textContent = mb(alloc) + ' / ' + mb(dagitilabilir);
    const rel = $('#sys-mem-real');
    if (rel) {
      // Metin KISA tutuluyor: üst bar sabit genişlikli sütunlardan oluşuyor ve
      // uzun bir uyarı cümlesi bu sütunu şişirip diğerlerini (Disk, İşlemci)
      // kaydırıyordu. Ayrıntı title'da; burada yalnız oran ve gerçek kullanım.
      rel.textContent = (asim ? '⚠ %' + pct + ' · ' : '')
                      + 'gerçek kullanım ' + mb(real);
      rel.className = 'sys-sub' + (asim ? ' sys-sub-warn' : '');
    }
    // Tavan toplamının kapasiteyi aşması KENDİ BAŞINA arıza değildir: limitler
    // birer üst sınırdır, rezervasyon değil — nitekim gerçek kullanım çok daha
    // düşük. Riski hepsi aynı anda dolarsa doğar. Bu yüzden kırmızı gösterip
    // sebebini yazıyoruz ama "bozuk" demiyoruz.
    const item = document.querySelector('.sys-item-mem');
    if (item) {
      item.title = asim
        ? 'Açık motorlara söz verilen bellek tavanlarının toplamı ('
          + mb(alloc) + '), dağıtılabilir bellekten (' + mb(dagitilabilir)
          + ') fazla. Şu anki gerçek kullanım ' + mb(real) + ' olduğu için '
          + 'sorun görünmüyor; ama tüm motorlar aynı anda tavanına dayanırsa '
          + 'işletim sistemi süreçleri öldürmeye başlar. Bu duruma genelde bir '
          + 'motor panel dışından (docker start) elle başlatıldığında düşülür. '
          + 'Kullanmadığınız bir motoru kapatmak oranı düşürür.'
        : 'Toplam ' + mb(sys.mem_total_mb) + ' RAM\'in ' + mb(reserved)
          + ' kadarı işletim sistemine ve çekirdek servislere ayrıldı; kalan '
          + mb(dagitilabilir) + ' veritabanlarına dağıtılabilir.';
    }
    const bar = $('#sys-mem-bar');
    bar.style.width = Math.min(100, pct) + '%';
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
  // Araç kategorileri (izleme gibi) her zaman EN SONA. Sayfanın sorusu
  // "hangi veritabanına ihtiyacınız var" — araya veritabanı olmayan bir kart
  // sokmak o soruyu bulandırır. Buna karşılık en altta kaldığında kimsenin
  // görmediği de ortaya çıktı; onun için yukarıya kısayol koyuyoruz.
  const isToolCat = (cat) => {
    const list = CATALOG.engines.filter((e) => e.category === cat);
    return list.length > 0 && list.every((e) => e.kind === 'tool');
  };
  const keys = Object.keys(cats);
  const order = keys.filter((c) => !isToolCat(c)).concat(keys.filter(isToolCat));

  let html = '';
  const toolLinks = [];
  order.forEach((cat) => {
    const list = CATALOG.engines.filter((e) => e.category === cat);
    if (!list.length) return;
    html += `<h2 class="cat-title" id="cat-${esc(cat)}">${esc(cats[cat])}</h2>`;
    list.forEach((e) => {
      if (e.kind === 'tool') {
        toolLinks.push(`<a class="tool-link" href="#cat-${esc(cat)}"
          >${e.icon || ''} ${esc(e.name)}</a>`);
      }
      html += cardHtml(e, byId[e.id] || { active: false }, STATE.plans[e.id]);
    });
  });
  $('#grid').innerHTML = html;

  const tl = $('#tool-links');
  if (tl) {
    tl.innerHTML = toolLinks.length
      ? '<span class="legend-label">Araçlar</span>' + toolLinks.join('') : '';
    tl.hidden = !toolLinks.length;
  }
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
  let p;
  switch (b.dataset.act) {
    case 'on':      p = activate(engine); break;
    case 'off':     p = deactivate(engine); break;
    case 'conn':    p = showConnection(engine); break;
    case 'rep-on':  p = toggleReplication(engine, true); break;
    case 'rep-off': p = toggleReplication(engine, false); break;
    case 'fo-on':   p = toggleAutoFailover(engine, true); break;
    case 'fo-off':  p = toggleAutoFailover(engine, false); break;
    case 'rebuild': p = rebuildStandby(engine); break;
    case 'panel': {
      // Paneller gateway üzerinde kendi HTTPS portlarında durur.
      const url = 'https://' + location.hostname + ':' + engine.panel.port +
                  (engine.panel.path || '/');
      window.open(url, '_blank', 'noopener');
      return;
    }
  }
  /* Hata BURADA yakalanır: düğmeye basınca çalışan işlevlerin tek çağrı yeri
     burası. Bu dinleyici async değil, dallar eskiden "return activate(engine)"
     diyordu ve activate / deactivate / toggleReplication / toggleAutoFailover /
     rebuildStandby içindeki "await api(...)" hiçbir try içinde değildi. api()
     403/503/504'te throw ettiği için (yukarıda, r.ok kontrolü) hata yakalanmamış
     bir promise reddine dönüşüyordu: onay penceresi kapanıyor, ekranda HİÇBİR
     ŞEY olmuyordu. Yani gateway'in tam da bu durum için yazdığı düz metinler
     ("aynı işlemi tekrar başlatmayın", "bu istek panelin kendi sayfasından
     gelmediği için durduruldu") kullanıcıya hiç ulaşmıyordu — kullanıcı da
     düğmeye bir kez daha basıyordu. */
  if (p) p.catch((e) => infoBox('İşlem yapılamadı', '<p>' + esc(e.message) + '</p>'));
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
