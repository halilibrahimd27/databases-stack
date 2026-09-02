/* databases-stack dashboard — bağımlılıksız, tek dosya.
   Bütün karar mantığı controller'da; burası yalnız gösterim ve onay akışı.

   YÖN: “SAKİN”. Bu dosyada API çağrıları, onay akışları, 5 saniyelik yenileme
   ve hata yakalama mantığı ORİJİNALİYLE AYNIDIR. Değişen tek şey gösterim:

     • Açık motorlar KART, kapalı motorlar SATIR olarak çizilir (madde 2 ve 4).
     • Sorunlu motorlar açık bölümün en başına alınır (madde 3).
     • Kartın gündelik düğmeleri üstte; kapatma ve geri dönüşü zor işlemler
       kartın altında kapalı bir <details> içinde, her biri kendi açıklamasıyla
       (madde 1).
     • Izgara HTML'i yalnız GERÇEKTEN DEĞİŞTİĞİNDE yazılır; ayrıca açık
       <details> öğeleri ve odak, yeniden çizimde korunur. Böylece 5 saniyelik
       yenileme kullanıcının açtığı ayrıntıyı kapatmaz ve ekran okuyucuyu
       boşuna konuşturmaz.
*/
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
/* Pencerenin ipucu cümlesi index.html'de AKTİVASYON için yazılmış: “imaj
   indirileceği için birkaç dakika sürebilir”. Yedek alırken indirilen bir imaj
   yok; o cümle olduğu gibi kalınca bekleyişin sebebini YANLIŞ anlatıyordu.
   Üçüncü parametre boş bırakılırsa HTML'deki özgün metin geri konur — bir
   yedekten sonra açılan aktivasyon penceresi yedeğin cümlesiyle kalmasın. */
let JOB_HINT0 = null;

async function watchJob(jobId, title, hint) {
  const ipucu = $('#job-hint');
  if (ipucu) {
    if (JOB_HINT0 == null) JOB_HINT0 = ipucu.textContent;
    ipucu.textContent = hint || JOB_HINT0;
  }
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

/* --------------------------------------------------------- yedek eylemi */

/* Zamanlama, dosya listesi ve geri yükleme artık AYRI BİR SAYFADA
   (/yedekler, yedekler.js). Panelde yalnız aşağıdaki tek eylem kaldı:
   motorla uğraşırken doğan "dokunmadan önce bir yedek alayım" isteği. */

/* Elle yedek, aktivasyonla AYNI iş mekanizmasını kullanır: uzun süren her
   işlem controller'da bir "job"a dönüşür, panel de log'u canlı gösterir.
   Ayrı bir bekleme akışı yazmak, kullanıcıya iki farklı "sürüyor" ekranı
   göstermek olurdu. */
async function takeBackup(engine) {
  const r = await api('/engines/' + engine.id + '/backup', { method: 'POST' });
  await watchJob(r.job, engine.name + ' yedekleniyor…',
    'Yedek, veritabanı çalışırken alınır. Büyük bir veritabanında birkaç ' +
    'dakika sürebilir; pencereyi kapatsanız da iş sunucuda devam eder.');
}

/* ================================================================== çizim */

/* Bir motorun “ne kadar dikkat istiyor” sırası. 0 en acil.
   Açık bölümü bu sıraya göre diziyoruz: sorunlu motor 13 kartın arasında
   kaybolmasın, en üstte dursun. */
/* Sıralama HİSTEREZİSLİ. attention() anlık durumu söyler; sağlık kontrolü
   salınan bir motor (starting ↔ healthy) her 5 saniyede listeyi yeniden
   diziyor, kullanıcının imlecinin altındaki düğme yer değiştiriyordu.
   Sıra ancak aynı sonuç ÜST ÜSTE İKİ KEZ görülünce değişir. */
const _rankMem = {};
function stableAttention(eid, st) {
  const now = attention(st);
  const m = _rankMem[eid];
  if (!m) { _rankMem[eid] = { rank: now, n: 0 }; return now; }
  if (now === m.rank) { m.n = 0; return m.rank; }
  if (++m.n >= 2) { m.rank = now; m.n = 0; }
  return m.rank;
}

function attention(st) {
  // Container'ı VAR ama çalışmıyor (restarting/paused): en acil durum.
  // Sürekli yeniden başlayan bir motor işlemci yakar ve kendiliğinden
  // düzelmez — kullanıcının onu görüp kapatması gerekir.
  if (st.present && !st.active) return 0;
  if (st.health === 'unhealthy' || st.failed_over) return 0;
  if (st.health === 'starting') return 1;
  return 2;
}

/* ---------------------------------------------------- AÇIK motorun kartı */
function cardHtml(engine, st) {
  const p    = engine.plain || {};
  const rep  = engine.replication || {};
  const fo   = engine.failover || {};
  const lic  = engine.license || {};
  const rank = attention(st);

  // "tool" türü kayıtlar (izleme gibi) veritabanı değildir: istemcinin
  // bağlanacağı bir port, bağlantı bilgisi ya da yedek kopyası yoktur.
  // Kartta o düğmeleri göstermek, kullanıcıya olmayan bir şey vaat etmektir.
  const isTool = engine.kind === 'tool';
  const ports  = (engine.client_ports || []).map((x) => x.port).join(', ');

  let badge = '<span class="badge on">Çalışıyor</span>';
  if (st.present && !st.active) badge = '<span class="badge err">Sorunlu</span>';
  else if (st.health === 'starting') badge = '<span class="badge busy">Başlatılıyor</span>';
  else if (st.health === 'unhealthy') badge = '<span class="badge err">Sorunlu</span>';

  // Kart bilgisi tek satıra indi: kutu içinde tanım listesi yerine
  // “512 MB · port 5432 · yedek kopya çalışıyor”.
  const facts = [];
  if (st.present && !st.active) facts.push('çalışmıyor (' + esc(st.primary_status || '') + ')');
  else if (st.memory_mb != null) facts.push(mb(st.memory_mb) + ' bellek');
  if (ports) facts.push('port ' + esc(ports));
  if (st.replication_active) facts.push('yedek kopya çalışıyor');
  if (st.auto_failover) facts.push('otomatik devir açık');

  // Sayfadaki tek renkli alan: gerçekten dikkat isteyen durum.
  let notice = '';
  if (st.present && !st.active) {
    const kac = (st.stray || []).length;
    notice = `<p class="card-notice is-err">Container'ı ayakta ama servis
      çalışmıyor (durum: <b>${esc(st.primary_status || '')}</b>). “Yeniden
      başlıyor” hâlinde işlemci harcar ve kendiliğinden düzelmez.
      ${kac ? `Bu motora ait <b>${kac}</b> container hâlâ duruyor. ` : ''}Aşağıdaki
      <b>Kapat</b> hepsini temizler; verileriniz silinmez.</p>`;
  } else if (st.failed_over) {
    notice = `<p class="card-notice is-warn">Devir yapıldı — şu an
      <b>${esc(st.primary_service || '')}</b> ana kopya. Uygulamanız <b>aynı
      adrese</b> bağlanmaya devam eder, bağlantı bilgisi değişmez. Şu an yedek
      kopya <b>yok</b>: aşağıdaki “Eski kopyayı yeniden kur” eski düğümü
      <b>yedek olarak</b> geri getirir. Ana kopya
      <b>${esc(st.primary_service || '')}</b> olarak kalır — rollerin yer
      değiştirmiş olması zararsızdır, geri takas etmek gereksiz ikinci bir
      kesinti demek olurdu.</p>`;
  } else if (st.health === 'unhealthy') {
    notice = `<p class="card-notice is-err">Çalışıyor ama sağlık kontrolüne
      yanıt vermiyor. Birkaç dakika beklemesine rağmen düzelmezse kapatıp
      yeniden açmayı deneyin.</p>`;
  } else if (st.health === 'starting') {
    notice = `<p class="card-notice">Başlatılıyor. İlk açılışta imaj
      indirileceği için birkaç dakika sürebilir.</p>`;
  }

  // Üretimde kullanılamayan lisans, kartta kalıcı olarak görünür.
  const licCard = lic.free_for_production === false
    ? `<p class="card-lic">⚠️ Lisans: ${esc(lic.name)}. Üretimde ayrı lisans gerekir.</p>` : '';

  /* --- GÜNDELİK eylemler: en fazla iki, ikisi de sessiz --------------- */
  const panelBtn = engine.panel
    ? `<button class="btn" data-act="panel" data-id="${esc(engine.id)}">${esc(engine.panel.name)} aç</button>` : '';
  const connBtn = !isTool
    ? `<button class="btn" data-act="conn" data-id="${esc(engine.id)}">Bağlantı bilgisi</button>` : '';
  const daily = panelBtn + connBtn;

  /* --- GERİ DÖNÜŞÜ ZOR eylemler: kapalı açılırda, her biri açıklamalı --- */
  let more = `
    <div class="act">
      <div class="act-txt"><b>Kapat</b>
        <span>Durur, belleği serbest kalır. Verileriniz silinmez.</span></div>
      <button class="btn btn-danger" data-act="off" data-id="${esc(engine.id)}"
        aria-label="${esc(engine.name)} veritabanını kapat">Kapat</button>
    </div>`;

  /* ŞİMDİ YEDEK AL — kartın kendi üstünde. Aynı düğme /yedekler sayfasında
     da var ama oraya GİTMEK gerekiyor; oysa "bu veritabanına dokunmadan önce
     bir yedek alayım" isteği tam da motorla uğraşırken, burada doğuyor.
     "Son yedek ne zaman alındı" cümlesi buradan KALKTI: o bilgi artık ayrı
     bir sayfadan geliyor ve panelin 5 saniyelik turunda yedek dizinini
     saydırmak, kart üstündeki tek cümle uğruna diski boşuna uyandırmak
     olurdu. Zamanlanmış gece yedeği bundan BAĞIMSIZ çalışır — bu düğme onun
     yerine geçmez, ek bir kurtarma noktası üretir. */
  if ((engine.backup || {}).supported) {
    more += `
    <div class="act">
      <div class="act-txt"><b>Şimdi yedek al</b>
        <span>Gece alınan zamanlanmış yedek ayrıca sürer; bu, ek bir kurtarma
          noktası oluşturur. Dosyalar, tarihler ve geri yükleme
          <a href="/yedekler">Yedekler</a> sayfasında.</span></div>
      <button class="btn" data-act="backup" data-id="${esc(engine.id)}"
        aria-label="${esc(engine.name)} için şimdi yedek al">Yedek al</button>
    </div>`;
  }

  if (st.failed_over) {
    more += `
    <div class="act">
      <div class="act-txt"><b>Eski kopyayı yeniden kur</b>
        <span>Eski kopyadaki veriler silinir, yeni ana kopyadan baştan kopyalanır.</span></div>
      <button class="btn" data-act="rebuild" data-id="${esc(engine.id)}">Yeniden kur</button>
    </div>`;
  }

  if (rep.mode === 'primary-replica' || rep.mode === 'replica-set') {
    more += st.replication_active
      ? `<div class="act">
           <div class="act-txt"><b>Yedek kopyayı kapat</b>
             <span>İkinci kopya durur, ana kopya etkilenmez.</span></div>
           <button class="btn" data-act="rep-off" data-id="${esc(engine.id)}"
                   aria-label="${esc(engine.name)} yedek kopyasını kapat">Kapat</button>
         </div>`
      : `<div class="act">
           <div class="act-txt"><b>Yedek kopya kur</b>
             <span>İkinci bir kopya tutulur; her değişiklik oraya da yazılır. Ek bellek ister.</span></div>
           <button class="btn" data-act="rep-on" data-id="${esc(engine.id)}"
                   aria-label="${esc(engine.name)} için yedek kopya kur">Kur</button>
         </div>`;
  }

  if (st.replication_active && fo.supported && fo.mode === 'supervised') {
    more += st.auto_failover
      ? `<div class="act">
           <div class="act-txt"><b>Otomatik devri kapat</b>
             <span>İzleme durur; ana kopya çökerse devir elle yapılır.</span></div>
           <button class="btn" data-act="fo-off" data-id="${esc(engine.id)}"
                   aria-label="${esc(engine.name)} otomatik devrini kapat">Kapat</button>
         </div>`
      : `<div class="act">
           <div class="act-txt"><b>Otomatik devri aç</b>
             <span>Ana kopya yanıt vermezse sistem yedeğe kendisi geçer.</span></div>
           <button class="btn" data-act="fo-on" data-id="${esc(engine.id)}"
                   aria-label="${esc(engine.name)} otomatik devrini aç">Aç</button>
         </div>`;
  }

  if (p.detail) {
    more += `<p class="more-what"><b>Ne işe yarar</b><br>${esc(p.detail)}</p>`;
  }
  if (lic.name) more += `<p class="more-lic">Lisans: ${esc(lic.name)}</p>`;

  const cls = rank === 0 ? ' is-err' : rank === 1 ? ' is-busy' : '';

  return `
  <article class="card${cls}" id="eng-${esc(engine.id)}">
    <div class="card-head">
      <span class="card-icon" aria-hidden="true">${esc(engine.icon)}</span>
      <div class="card-id">
        <h3>${esc(engine.name)}</h3>
        <p class="card-plain">${esc(p.title || engine.summary)}</p>
        ${p.badge ? `<span class="tag">${esc(p.badge)}</span>` : ''}
      </div>
      ${badge}
    </div>
    ${facts.length ? `<p class="card-facts">${facts.map((f) => '<span>' + f + '</span>').join('')}</p>` : ''}
    ${notice}
    ${licCard}
    ${daily ? `<div class="card-actions">${daily}</div>` : ''}
    <details class="more" data-key="${esc(engine.id)}:more">
      <summary class="sum"><span class="chev" aria-hidden="true"></span>Kapat ve diğer işlemler</summary>
      <div class="more-body">${more}</div>
    </details>
  </article>`;
}

/* ------------------------------------------------- KAPALI motorun satırı */
/* Kapalı bir motorun taşıdığı bilgi azdır; o yüzden kapladığı yer de azdır.
   Tek satır: ikon, ad, ne işe yaradığı, tahmini bellek, tek düğme.
   Uzun anlatım, port, panel ve lisans satıra tıklanınca açılır. */
function rowHtml(engine, plan, st) {
  const p       = engine.plain || {};
  const blocked = plan && !plan.ok;
  const ports   = (engine.client_ports || []).map((x) => x.port).join(', ');

  // Etiket SEBEBE göre. Öncesinde her ret "bellek yetmiyor" yazıyordu; AVX
  // desteği olmayan bir CPU yüzünden açılamayan MongoDB de öyle görünüyordu
  // ve kullanıcı haklı olarak "ama bolca boş bellek var" diyordu.
  const retAd = { bellek: 'bellek yetmiyor', disk: 'disk yetmiyor',
                  onkosul: 'bu sunucuda çalışmaz' };
  const mem = blocked
    ? `<span class="row-mem row-mem-block">${esc(retAd[plan.reason_kind] || 'açılamıyor')}</span>`
    : (plan && plan.ok ? `<span class="row-mem">~ ${mb(plan.limit_mb)}</span>` : '');

  const lic = engine.license || {};

  // Motor kapalı ama YARDIMCI servisleri (yönetim ekranı, exporter) hâlâ
  // ayakta olabilir — ana kopya yoksa satırda kalır. Sessizce bellek/işlemci
  // harcamasınlar diye satırda söylüyoruz ve tek düğmeyle temizletiyoruz.
  const kalan = ((st || {}).stray || []).length;
  const artik = kalan
    ? `<span class="row-mem row-mem-block" title="${esc(((st || {}).stray || []).map((x) => x.service + ' (' + x.status + ')').join(', '))}">${kalan} artık container</span>`
    : '';

  return `
  <li class="row${blocked ? ' is-blocked' : ''}" id="eng-${esc(engine.id)}">
    <details class="row-info" data-key="${esc(engine.id)}:info">
      <summary class="sum row-head">
        <span class="chev" aria-hidden="true"></span>
        <span class="row-icon" aria-hidden="true">${esc(engine.icon)}</span>
        <span class="row-name">${esc(engine.name)}</span>
        <span class="row-what">${esc(p.title || engine.summary)}</span>
        ${lic.free_for_production === false
          ? `<span class="row-lic" title="${esc(lic.note || '')}">üretimde lisans gerekir</span>` : ''}
      </summary>
      <div class="row-detail">
        <p>${esc(p.detail || engine.summary || '')}</p>
        ${p.badge ? `<p style="margin:0 0 10px"><span class="tag">${esc(p.badge)}</span></p>` : ''}
        <dl class="mini">
          <dt>Tahmini bellek</dt><dd>${plan && plan.ok ? mb(plan.limit_mb) : '—'}</dd>
          ${ports ? `<dt>Bağlantı portu</dt><dd>${esc(ports)}</dd>` : ''}
          ${engine.panel ? `<dt>Yönetim ekranı</dt><dd>${esc(engine.panel.name)}</dd>` : ''}
          ${lic.name ? `<dt>Lisans</dt><dd>${esc(lic.name)}${lic.free_for_production === false ? ' (üretimde ayrı lisans gerekir)' : ''}</dd>` : ''}
        </dl>
        ${blocked ? `<div class="blocked-note" style="margin-top:12px">${esc(plan.reason)}</div>` : ''}
      </div>
    </details>
    <div class="row-side">
      ${artik}
      ${mem}
      ${artik
        ? `<button class="btn btn-danger" data-act="off" data-id="${esc(engine.id)}"
             title="Bu motora ait çalışır durumda kalan container'ları kaldırır — veri silinmez">Temizle</button>`
        : ''}
      <button class="btn btn-open" data-act="on" data-id="${esc(engine.id)}"
        ${blocked ? 'title="Sunucuda yeterli bellek yok — sebebini görmek için tıklayın"' : ''}>Aktif Et</button>
    </div>
  </li>`;
}

/* --------------------------------------------- üst bar (sistem ölçüleri) */
function renderSystem() {
  const sys = STATE.system || {};
  $('#sys-host').textContent = location.hostname;
  $('#sys-cpu').textContent  = (sys.cpus || '—') + ' çekirdek';
  $('#sys-disk').textContent = mb(sys.disk_free_mb) + ' boş';

  if (!sys.mem_total_mb) return;

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
    // Sunucunun TOPLAM RAM'i burada yazılı olmak zorunda. Payda artık
    // "dağıtılabilir" bellek olduğu için (toplam − OS payı − çekirdek),
    // üst barda tek başına "12 GB / 12 GB" görünüyordu ve okuyan haklı
    // olarak "sunucunun belleği 16'dan 12'ye mi düştü?" diye soruyordu.
    // Metin KISA: sütun sabit genişlikte, uzun cümle diğer sütunları
    // kaydırıyordu. Tam açıklama title'da.
    rel.textContent = (asim ? '⚠ %' + pct + ' aşım · ' : mb(sys.mem_total_mb) + ' RAM · ')
                    + 'kullanım ' + mb(real);
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

/* -------------------------- ızgaranın durumunu koruyarak yeniden yazma ---
   #grid her 5 saniyede yeniden çiziliyor. Kullanıcının açtığı bir <details>
   ya da odaklandığı bir düğme bu yüzden kaybolmamalı; ayrıca içerik
   değişmediyse innerHTML'e hiç dokunmuyoruz (aria-live boşuna konuşmasın). */
function snapshotGrid(grid) {
  const open = [];
  grid.querySelectorAll('details[data-key]').forEach((d) => {
    if (d.open) open.push(d.dataset.key);
  });
  const a = document.activeElement;
  let focus = null;
  if (a && grid.contains(a)) {
    if (a.dataset && a.dataset.act) focus = { act: a.dataset.act, id: a.dataset.id };
    else if (a.tagName === 'SUMMARY' && a.parentElement && a.parentElement.dataset.key)
      focus = { key: a.parentElement.dataset.key };
  }
  return { open: open, focus: focus };
}

function restoreGrid(grid, snap) {
  grid.querySelectorAll('details[data-key]').forEach((d) => {
    if (snap.open.indexOf(d.dataset.key) !== -1) d.open = true;
  });
  if (!snap.focus) return;
  let el = null;
  if (snap.focus.act) {
    grid.querySelectorAll('[data-act]').forEach((n) => {
      if (!el && n.dataset.act === snap.focus.act && n.dataset.id === snap.focus.id) el = n;
    });
  } else {
    grid.querySelectorAll('details[data-key]').forEach((d) => {
      if (!el && d.dataset.key === snap.focus.key) el = d.querySelector('summary');
    });
  }
  if (el) el.focus({ preventScroll: true });
}

let lastGridHtml = '';

/* -------------------------------------------------------------- render() */
function render() {
  renderSystem();

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
  const keys  = Object.keys(cats);
  const order = keys.filter((c) => !isToolCat(c)).concat(keys.filter(isToolCat));

  // Katalog sırası (kategori sırasına göre düzleştirilmiş)
  const ordered = [];
  order.forEach((cat) => {
    CATALOG.engines.filter((e) => e.category === cat).forEach((e) => ordered.push(e));
  });

  // "Açık" = çalışıyor VEYA container'ı hâlâ ayakta. İkincisi eskiden
  // kapalılar arasında listeleniyordu: panel "kapalı" derken `docker ps`te
  // canlıydı ve kimse kapatmıyordu (bkz. status() içindeki `present`).
  const isOn  = (e) => { const s = byId[e.id] || {}; return !!(s.active || s.present); };
  const acik  = ordered.filter(isOn);
  const kapal = ordered.filter((e) => !isOn(e));

  // Dikkat isteyen motor en üstte. sort() ES2019'dan beri kararlıdır,
  // dolayısıyla aynı gruptakiler katalog sırasını korur.
  acik.sort((a, b) => stableAttention(a.id, byId[a.id] || {})
                    - stableAttention(b.id, byId[b.id] || {}));
  const sorunlu = acik.filter((e) => attention(byId[e.id] || {}) === 0).length;

  let html = '';

  /* --- BÖLGE 1: şu an açık olanlar --- */
  html += '<section class="zone">' +
    '<div class="zone-head">' +
      '<h2 class="zone-title">Şu an açık</h2>' +
      `<span class="zone-count">${acik.length}</span>` +
      (sorunlu
        ? `<p class="zone-note zone-note-err">${sorunlu} tanesi dikkat istiyor — en üstte.</p>`
        : '<p class="zone-note">Bellek ve işlemci kullanan motorlar.</p>') +
    '</div>';
  html += '<div class="zone-body">';
  html += acik.length
    ? '<div class="cards">' + acik.map((e) => cardHtml(e, byId[e.id] || {})).join('') + '</div>'
    : `<p class="empty">Henüz hiçbir veritabanı açık değil — sunucu boşta duruyor.
        Aşağıdaki listeden ihtiyacınız olanı seçip “Aç” deyin.</p>`;
  html += '</div></section>';

  /* --- BÖLGE 2: kapalı olanlar, kategorilere göre, satır satır --- */
  html += '<section class="zone">' +
    '<div class="zone-head">' +
      '<h2 class="zone-title">Kapalı</h2>' +
      `<span class="zone-count">${kapal.length}</span>` +
      '<p class="zone-note">Hiç kaynak harcamıyorlar. Ne işe yaradığını görmek için satıra tıklayın.</p>' +
    '</div>';
  html += '<div class="zone-body">';
  if (!kapal.length) {
    html += '<p class="empty">Katalogdaki her şey açık.</p>';
  } else {
    order.forEach((cat) => {
      const list = kapal.filter((e) => e.category === cat);
      if (!list.length) return;
      html += `<h3 class="cat-title" id="cat-${esc(cat)}">${esc(cats[cat])}</h3>`;
      html += `<ul class="rows" aria-labelledby="cat-${esc(cat)}">` +
        list.map((e) => rowHtml(e, STATE.plans[e.id], byId[e.id])).join('') + '</ul>';
    });
  }
  html += '</div></section>';

  const grid = $('#grid');
  if (html !== lastGridHtml) {
    const snap = snapshotGrid(grid);
    grid.innerHTML = html;
    lastGridHtml = html;
    restoreGrid(grid, snap);
  }

  /* --- araçlar kısayolu --- */
  const toolLinks = [];
  ordered.forEach((e) => {
    if (e.kind !== 'tool') return;
    // Araç AÇIKSA rozet doğrudan panelini açar. Kartına kaydırmak, zaten
    // çalışan bir aracı görmek isteyen kullanıcı için fazladan iki adım
    // demekti — "izleme ekranı yok" denmesinin sebebi buydu: kart en
    // altta duruyordu ve rozet oraya kaydırmakla yetiniyordu.
    const aktif = (byId[e.id] || {}).active;
    toolLinks.push(aktif && e.panel
      ? `<button class="tool-link is-on" data-act="panel" data-id="${esc(e.id)}"
           title="${esc(e.panel.name)} panelini yeni sekmede aç"
         >${esc(e.icon || '')} ${esc(e.name)} aç</button>`
      : `<a class="tool-link" href="#eng-${esc(e.id)}"
           title="Satırına git">${esc(e.icon || '')} ${esc(e.name)}</a>`);
  });

  /* Yedekler artık ayrı bir sayfa. Bağlantısı "Araçlar" satırında, izleme
     kısayolunun yanında duruyor: panelin içinden kaldırılan bir bölüm, yerine
     görünür bir kapı bırakmazsa kullanıcı için SİLİNMİŞ demektir. */
  toolLinks.push(`<a class="tool-link" href="/yedekler"
      title="Yedek dosyaları, zamanlama ve geri yükleme">💾 Yedekler</a>`);

  const tl = $('#tool-links');
  if (tl) {
    const th = toolLinks.length
      ? '<span class="legend-label">Araçlar</span>' + toolLinks.join('') : '';
    if (tl.innerHTML !== th) tl.innerHTML = th;
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

/* ------------------------------------------------------------------- tema */
/* Üç durum, iki değil: sistem → açık → koyu → sistem. "Sistem" bir durum
   olmak zorunda, çünkü kullanıcıların çoğu işletim sisteminde zaten bir
   tercih yapmış ve panelin ona uymasını bekliyor; sadece açık/koyu ikilisi
   sunmak o tercihi kalıcı olarak ezerdi. */
const TEMA_SIRA = ['sistem', 'light', 'dark'];
const TEMA_AD   = { sistem: 'Sistem', light: 'Açık', dark: 'Koyu' };
const TEMA_IKON = { sistem: '◐', light: '☀', dark: '☾' };

function temaOku() {
  try {
    const t = localStorage.getItem('dbstack-theme');
    return (t === 'light' || t === 'dark') ? t : 'sistem';
  } catch (e) { return 'sistem'; }
}

function temaUygula(t) {
  if (t === 'sistem') delete document.documentElement.dataset.theme;
  else document.documentElement.dataset.theme = t;
  try {
    if (t === 'sistem') localStorage.removeItem('dbstack-theme');
    else localStorage.setItem('dbstack-theme', t);
  } catch (e) {}      // gizli pencerede yazma hata verir; tema yine çalışsın
  const ico = $('#theme-ico'), txt = $('#theme-txt');
  if (ico) ico.textContent = TEMA_IKON[t];
  if (txt) txt.textContent = TEMA_AD[t];
}

(function temaBaslat() {
  temaUygula(temaOku());
  const b = $('#theme-toggle');
  if (!b) return;
  b.addEventListener('click', () => {
    const s = TEMA_SIRA[(TEMA_SIRA.indexOf(temaOku()) + 1) % TEMA_SIRA.length];
    temaUygula(s);
  });
})();

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
    case 'backup':  p = takeBackup(engine); break;
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
