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

/* i18n.js yüklenmemişse panel yine çalışsın: metni olduğu gibi döndür. */
const T = (x) => (typeof t === 'function' ? t(x) : x);

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

/* Pencerelerdeki "etiket … değer" satırı. Tek yerde durması, aynı
   satırın üç ayrı pencerede üç ayrı biçimde yazılmasını engelliyor. */
const planSatir = (ad, deger) =>
  `<div class="plan-line"><span>${esc(ad)}</span><b>${esc(deger)}</b></div>`;

/* ------------------------------------------------------------- pencereler */
function confirmBox(title, bodyHtml, okLabel = 'Devam') {
  return new Promise((resolve) => {
    $('#modal-title').textContent = title;
    $('#modal-body').innerHTML = bodyHtml;
    $('#modal-ok').textContent = okLabel;
    $('#modal-ok').hidden = false;
    /* infoBox iptal düğmesinin yazısını "Kapat"a çeviriyor ve geri
       almıyordu. Bilgi penceresinden onay penceresine geçen bir akışta
       (bkz. "Yeniden dengele") kullanıcıya "Kapat / Yeniden dengele"
       diye sorulurdu; onay penceresi kendi etiketini kendisi kurar. */
    $('#modal-cancel').textContent = 'Vazgeç';
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
  /* Bir önceki onayın işleyicisi ÜSTÜNDE kalmasın: düğme yeniden
     görünür olduğunda eski işi tetiklemeye çalışırdı. */
  $('#modal-ok').onclick = null;
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
    /* Buradaki eski metin YANLIŞTI: "bu sınırlar söz verilmiş olduğu için
       yeniden dağıtılamaz" diyordu. Tavan bir söz değil, izin verilen en
       fazladır ve docker update ile yeniden hesaplanabilir — /api/rebalance
       tam bunu yapıyor. Yanlış açıklama kullanıcıya tek bir çıkış yolu
       bırakıyordu: çalışan bir veritabanını kapatmak. */
    const m = bellekModeli(STATE.system || {});
    const bellekmi = plan.reason_kind === 'bellek';
    infoBox(engine.name + ' şu an açılamıyor', `
      <p>${esc(plan.reason)}</p>
      ${planSatir('Sunucu toplam belleği', mb(m.toplam))}
      ${planSatir('Şu anki gerçek kullanım', mb(m.kullanilan))}
      ${planSatir('Dağıtılabilir bellek', mb(m.dagitilabilir))}
      ${m.rezerve != null
        ? planSatir('Açık motorların baştan ayırdığı', mb(m.rezerve)) : ''}
      ${planSatir('Açık motorlara verilen üst sınırlar', mb(m.tavan))}
      ${planSatir('Bu veritabanı için gereken en az',
                  mb(plan.min_mb + plan.overhead_mb))}
      ${bellekmi ? kuralHtml(plan) : ''}
      ${bellekmi ? neYapmali(plan, m) : ''}`);
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
    <details style="margin-top:12px">
      <summary style="cursor:pointer;color:var(--muted);font-size:13px">
        Belleği kendim vereyim (isteğe bağlı)</summary>
      <p class="note" style="margin-top:8px">Boş bırakırsanız yukarıdaki
         ölçülmüş değer kullanılır. Bir sayı girerseniz sunucu onu kendi
         bütçesinden geçirir; sığmazsa sebebini sayılarla söyler.
         En az ${mb(plan.min_mb)}, en çok ${mb(plan.max_mb)}.</p>
      <label class="plan-line" style="gap:10px">
        <span>Üst sınır (MB)</span>
        <input type="number" id="istek-mb" class="mem-input"
               min="${esc(String(plan.min_mb))}"
               max="${esc(String(plan.max_mb))}" step="64"
               placeholder="${esc(String(plan.limit_mb))}">
      </label>
    </details>
    <p class="note">İlk açılışta veritabanı imajı indirileceği için birkaç dakika sürebilir.</p>`,
    'Aktif Et');
  /* Kutunun değeri onay penceresi KAPANMADAN okunmalı: kapanınca eleman
     DOM'dan gidiyor ve sonradan okumaya kalkmak her seferinde boş verirdi. */
  const istekEl = document.getElementById('istek-mb');
  const istek = istekEl && istekEl.value.trim() !== ''
    ? parseInt(istekEl.value, 10) : null;
  if (!ok) return;

  /* Sayıyı DOĞRULAMIYORUZ: sunucunun kendi kapıları (sert kural, yumuşak
     kural, çekirdek kemeri) zaten doğruluyor ve reddederse ölçülen sayılarla
     sebebini söylüyor. Panelde ikinci bir sınır uydurmak, iki ayrı doğrulama
     demekti ve biri diğerini yalanlardı. */
  const govde = (istek && istek > 0)
    ? { method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ memory_mb: istek }) }
    : { method: 'POST' };
  const r = await api('/engines/' + engine.id + '/activate', govde);
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
/* BAKIM. Varsayılan güvenli yol: tabloyu kilitlemez, onay istemiyoruz.
   Agresif bakım (yeri gerçekten geri veren) tabloyu KİLİTLER; onu panelden
   sunmuyoruz çünkü kilit süresi tahmini komut satırında gösteriliyor ve o
   kararı ekranda tek tıkla vermek doğru değil. */
async function runMaintenance(engine) {
  const r = await api('/engines/' + engine.id + '/maintenance',
                      { method: 'POST' });
  await watchJob(r.job, engine.name + ' bakımı…',
    'Güvenli bakım tabloyu kilitlemez; veritabanı çalışmaya devam eder. '
    + 'Ölçülen boşluğun tamamı geri gelmeyebilir — yeri diske geri vermek '
    + 'tabloyu kilitleyen agresif bakım ister.');
  bakimSonCagri = 0;      // ölçümü hemen tazele
  await refreshBakim();
  render();
}

async function takeBackup(engine) {
  const r = await api('/engines/' + engine.id + '/backup', { method: 'POST' });
  await watchJob(r.job, engine.name + ' yedekleniyor…',
    'Yedek, veritabanı çalışırken alınır. Büyük bir veritabanında birkaç ' +
    'dakika sürebilir; pencereyi kapatsanız da iş sunucuda devam eder.');
}

/* ------------------------------------------------- yeniden dengeleme */

/* Aşırı taahhüt genelde panelin DIŞINDAN doğuyor: bir motor `docker start`
   ile elle kaldırılmış ya da makinenin RAM'i değişmiş oluyor. O anda panelin
   tek önerisi "çalışan bir veritabanını kapat" olmak zorunda değil —
   tavanlar rezervasyon olmadığı için yeniden hesaplanabilir.
   CONTAINER YENİDEN BAŞLATILMAZ: docker update cgroup sınırını canlı
   değiştirir. Bunu açıkça yazıyoruz, çünkü "belleğe dokunuyorum" cümlesi
   kullanıcının aklına ilk olarak kesintiyi getiriyor. */
async function rebalance() {
  const m = bellekModeli(STATE.system || {});
  const ok = await confirmBox('Üst sınırlar yeniden hesaplansın mı?', `
    <p>Açık veritabanlarının bellek <b>üst sınırları</b> bugünkü koşullara
       göre yeniden hesaplanır ve <code>docker update</code> ile
       uygulanır.</p>
    ${planSatir('Şu anki tavan toplamı', mb(m.tavan))}
    ${planSatir('Dağıtılabilir bellek', mb(m.dagitilabilir))}
    ${planSatir('Politika sınırı',
                m.sinir.toFixed(1) + '× · ' + mb(m.tavanButce))}
    ${planSatir('Şu anki gerçek kullanım', mb(m.kullanilan))}
    <p class="note"><b>Veritabanları yeniden başlatılmaz.</b> Bağlantılarınız
       kopmaz, veri kaybı olmaz; değişen tek şey cgroup'un izin verdiği en
       fazla bellektir.</p>
    <p class="note">Motorların <b>baştan ayırdığı</b> bellek (rezerve) bu
       işlemle değişmez: o, motorun kendi ayarından gelir ve ancak yeniden
       başlatmayla değişirdi.</p>`, 'Yeniden dengele');
  if (!ok) return;
  const r = await api('/rebalance', { method: 'POST' });
  await watchJob(r.job, 'Üst sınırlar yeniden hesaplanıyor…',
    'Açık motorların bellek üst sınırları güncelleniyor. Container\'lar ' +
    'yeniden başlatılmadığı için işlem birkaç saniye sürer.');
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
  if (st.present && !st.active) {
    facts.push('çalışmıyor (' + esc(st.primary_status || '') + ')');
  } else {
    /* "3.1 GB bellek" bu kartın küçük ama aynı kategoriden hatasıydı:
       gösterilen sayı docker limitidir, yani motorun BÜYÜYEBİLECEĞİ en
       fazla — kullandığı değil. Ölçülen olayda mariadb 3196 MB'lık
       limitinin 213 MB'ını kullanırken kartta "3.1 GB bellek" yazıyordu.
       Artık ikisi de adıyla anılıyor. */
    if (st.reserved_mb != null) {
      facts.push(mb(st.reserved_mb) + ' baştan ayrılan');
    }
    if (st.memory_mb != null) facts.push(mb(st.memory_mb) + ' üst sınır');
  }
  if (ports) facts.push('port ' + esc(ports));
  /* "Çalışıyor" ile "akıyor" AYRI ŞEYLER. Eskiden burada yalnız replika
     container'ının ayakta olduğuna bakılıyordu: akış kopmuş olsa bile panel
     "yedek kopya çalışıyor" diyordu — yani ölçülmemiş bir güvence. Akışın
     koptuğu bir yedek kopya, devirde işe YARAMAZ; kullanıcının bunu felaket
     anında değil şimdi görmesi gerekiyor. */
  if (st.replication_active) {
    if (st.replication_flowing === false) {
      facts.push('<span class="fact-err">yedek kopya AKMIYOR</span>');
    } else if (st.replication_flowing === true) {
      facts.push('yedek kopya akıyor');
    } else {
      /* ÜÇÜNCÜ DEĞER "İYİ" DEĞİL. Burada eskiden "yedek kopya çalışıyor"
         yazıyordu; oysa null "henüz ölçemedim" demek. Ölçülmemiş bir
         güvenceyi olumlu bir cümleyle sunmak, bu panelin engellemeye
         çalıştığı hatanın ta kendisi — "bilmiyorum" ile "iyi" aynı şey
         değil. Ölçüm gelene kadar dürüst olan cümle bu. */
      facts.push('yedek kopya durumu ölçülmedi');
    }
  }
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

  /* BAKIM. Şişkinlik ölçülmüşse ve bu motorda varsa gösteriyoruz. Sayı
     YOKSA satırı hiç çizmiyoruz: "0 bayt şişkinlik" demek, ölçüm yapılmamış
     bir motorda yanlış bir güvence verirdi (bkz. ok=None ayrımı). */
  const bkm = (BAKIM && Array.isArray(BAKIM.tables))
    ? BAKIM.tables.filter((t) => String(t.name || '').startsWith(engine.id + ':')
                                 || (BAKIM.engine === engine.id))
    : [];
  const bkmBayt = bkm.reduce((a, t) => a + (t.bloat_bytes || 0), 0);
  if (bkmBayt > 0) {
    more += `
    <div class="act">
      <div class="act-txt"><b>Bakım — ${esc(mb(Math.round(bkmBayt / 1048576)))} boşa gidiyor</b>
        <span>Sil-yaz döngüsü tabloları şişirir; bu alan diskte duruyor ama
          kullanılmıyor. Güvenli bakım tabloyu <b>kilitlemez</b>.
          En şişkin: ${esc((bkm[0] && bkm[0].name) || '?')}.</span></div>
      <button class="btn" data-act="maintenance" data-id="${esc(engine.id)}"
        aria-label="${esc(engine.name)} için bakım yap">Bakım yap</button>
    </div>`;
  }

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

/* --------------------------------------- reddin arkasındaki sayılar --- */

/* Ret etiketi SEBEBE göre yazılır. İki ayrı düzeltme birikti:

   (1) Öncesinde her ret "bellek yetmiyor" diyordu; AVX desteği olmayan bir
       CPU yüzünden açılamayan MongoDB de öyle görünüyordu ve kullanıcı haklı
       olarak "ama bolca boş bellek var" diyordu — reason_kind bunu çözdü.
   (2) "bellek" reddinin KENDİSİ de iki ayrı şey: taban kuralı (motorun
       açılışta gerçekten ayıracağı bellek) ile tavan kuralı (docker
       limitlerinin toplamı). Ölçülen olayda makinenin %91'i boştu, çekirdek
       sıfır baskı bildiriyordu ve çiğnenen kural tavan bütçesiydi; ama etiket
       kullanıcıya RAM'in dolduğunu söylüyordu. */
const RET_AD = { disk: 'disk yetmiyor', onkosul: 'bu sunucuda çalışmaz' };

function retEtiketi(plan) {
  if (!plan) return 'açılamıyor';
  if (plan.reason_kind !== 'bellek') {
    return RET_AD[plan.reason_kind] || 'açılamıyor';
  }
  if (plan.reserve_ok === false) return 'baştan ayrılacak bellek kalmadı';
  if (plan.ceiling_ok === false) return 'üst sınır bütçesi doldu';
  return 'bellek yetmiyor';      // ayrımı bildirmeyen eski controller
}

function tahminTitle(plan) {
  const t = 'Açılırsa izin verilecek üst sınır (docker --memory).';
  return plan.reserved_mb != null
    ? t + ' Baştan ayıracağı: ' + mb(plan.reserved_mb) + '.'
    : t;
}

/* "bellek yetmiyor" tek başına SINANAMAZ bir iddiaydı: kullanıcı `free -m`e
   bakıp 13987 MB available görüyor ve panele güvenmeyi bırakıyordu. Hangi
   kuralın çiğnendiğini ve ölçülen değerleri yazıyoruz ki iddia sınanabilsin.
   Alan gelmiyorsa o satır hiç çizilmez — uydurulmuş bir "geçti" en kötüsü
   olurdu. */
function kuralSatir(ad, hesap, gecti) {
  const im = gecti === false ? '✗ kaldı' : gecti === true ? '✓ geçti' : '—';
  return `<div class="kural-satir">
      <span class="kural-ad">${esc(ad)}</span>
      <span class="kural-hesap ${gecti === false ? 'kural-no' : 'kural-ok'}"
        >${esc(hesap)} · ${esc(im)}</span>
    </div>`;
}

function kuralHtml(plan) {
  const m  = bellekModeli(STATE.system || {});
  const en = (plan.min_mb || 0) + (plan.overhead_mb || 0);
  let h = '';

  if (plan.reserve_ok != null && plan.reserved_mb != null
      && m.rezerve != null) {
    h += kuralSatir('Taban — baştan ayrılanların toplamı',
      mb(m.rezerve) + ' + ' + mb(plan.reserved_mb) + ' ≤ '
      + mb(m.dagitilabilir), plan.reserve_ok);
  }
  if (plan.ceiling_ok != null) {
    h += kuralSatir('Tavan — üst sınırların toplamı',
      mb(m.tavan) + ' + en az ' + mb(en) + ' ≤ ' + mb(m.tavanButce)
      + ' (' + mb(m.dagitilabilir) + ' × ' + m.sinir.toFixed(1) + ')',
      plan.ceiling_ok);
  }
  /* Çekirdeğin ölçüsü HER HÂLÜKÂRDA yazılır: defter ne derse desin bağlayıcı
     olan odur ve "ama makine boş" itirazını sınayacak sayı budur. */
  h += kuralSatir('Çekirdek — boş bellek ve baskı',
    mb(m.bos) + ' boş · baskı ' + BASKI_AD[m.seviye], null);

  return `<div class="kural"><p class="kural-bas">Ölçülen değerler</p>`
       + h + `</div>`;
}

/* NE YAPACAĞINI SÖYLE. Kullanıcının elindeki çare çiğnenen kurala göre
   DEĞİŞİYOR: taban dolduysa gerçekten bir motoru kapatmak gerekir, tavan
   bütçesi dolduysa sınırları yeniden hesaplamak yeter. İkisine birden
   "bellek yetmiyor" demek, ikinci durumda kullanıcıyı gereksiz yere
   çalışan bir veritabanını kapatmaya itiyordu. */
function neYapmali(plan, m) {
  if (plan.reserve_ok === false) {
    return `<p class="note"><b>Çiğnenen kural: taban.</b> Motorların açılışta
      GERÇEKTEN ayırdığı bellek (PostgreSQL shared_buffers, MariaDB innodb
      buffer pool, JVM motorlarında -Xms) toplandığında yer kalmıyor. Bu
      bellek gerçekten tutulur; yeniden dağıtılamaz.</p>
      <p class="note">Yapılacak şey: kullanmadığınız bir veritabanını kapatın
      ya da sunucuya RAM ekleyin.</p>`;
  }
  if (plan.ceiling_ok === false) {
    return `<p class="note"><b>Çiğnenen kural: tavan bütçesi.</b> Makine
      dolmuş değil — ${esc(mb(m.kullanilan))} kullanımda ve çekirdek baskısı
      ${esc(BASKI_AD[m.seviye])}. Dolan şey, açık motorlara verilmiş <b>üst
      sınırların</b> toplamı; tavan bir rezervasyon değildir ve bugünkü
      koşullara göre yeniden hesaplanabilir.</p>
      <p class="note">Aşağıdaki düğme açık motorların sınırlarını
      <code>docker update</code> ile günceller. <b>Veritabanları yeniden
      başlatılmaz.</b></p>
      <div class="mem-advice-act">
        <button class="btn" data-act="rebalance">Yeniden dengele</button>
      </div>`;
  }
  return `<p class="note">Açık bir veritabanını kapatırsanız bu satır tekrar
    kullanılabilir hâle gelir.</p>`;
}

/* ------------------------------------------------- KAPALI motorun satırı */
/* Kapalı bir motorun taşıdığı bilgi azdır; o yüzden kapladığı yer de azdır.
   Tek satır: ikon, ad, ne işe yaradığı, tahmini bellek, tek düğme.
   Uzun anlatım, port, panel ve lisans satıra tıklanınca açılır. */
function rowHtml(engine, plan, st) {
  const p       = engine.plain || {};
  const blocked = plan && !plan.ok;
  const ports   = (engine.client_ports || []).map((x) => x.port).join(', ');

  // Etiket SEBEBE göre — hangi kuralın çiğnendiği dahil (bkz. retEtiketi).
  const mem = blocked
    ? `<span class="row-mem row-mem-block" title="${esc(plan.reason || '')}"
         >${esc(retEtiketi(plan))}</span>`
    : (plan && plan.ok
        ? `<span class="row-mem" title="${esc(tahminTitle(plan))}"
             >~ ${mb(plan.limit_mb)}</span>`
        : '');

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
          ${plan && plan.reserved_mb != null
            ? `<dt>Baştan ayıracağı</dt><dd>${mb(plan.reserved_mb)}</dd>` : ''}
          <dt>İzin verilecek üst sınır</dt><dd>${
            plan && plan.ok ? mb(plan.limit_mb) : '—'}</dd>
          ${ports ? `<dt>Bağlantı portu</dt><dd>${esc(ports)}</dd>` : ''}
          ${engine.panel ? `<dt>Yönetim ekranı</dt><dd>${esc(engine.panel.name)}</dd>` : ''}
          ${lic.name ? `<dt>Lisans</dt><dd>${esc(lic.name)}${lic.free_for_production === false ? ' (üretimde ayrı lisans gerekir)' : ''}</dd>` : ''}
        </dl>
        ${blocked ? `<div class="blocked-note" style="margin-top:12px">${esc(plan.reason)}</div>` : ''}
        ${blocked && plan.reason_kind === 'bellek' ? kuralHtml(plan) : ''}
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
        ${blocked ? 'title="' + esc(retEtiketi(plan))
          + ' — ölçülen sayılar ve ne yapılacağı için tıklayın"' : ''
        }>Aktif Et</button>
    </div>
  </li>`;
}

/* --------------------------------------------- üst bar (sistem ölçüleri) */

/* ÜST BARIN CEVAPLADIĞI SORU DEĞİŞTİ — ve değişmesi gerekiyordu.

   ÖLÇÜLEN OLAY (16 GB'lık test sunucusu): free -m 1508 MB kullanım
   gösteriyor, /proc/pressure/memory bütün pencerelerinde 0.00 bildiriyor,
   mariadb 3196 MB'lık tavanının yalnız 213 MB'ını (%6) kullanıyor. Üst bar
   ise "AYRILAN BELLEK 15 GB / 12 GB · %122 aşım" yazıyor, kapalı motorların
   hepsinde de "bellek yetmiyor" çıkıyordu. Makinenin %91'i boşken ürün "yer
   yok" diyordu; kullanıcı ürünü bozuk sandı ve haklıydı.

   HATA SAYIDA DEĞİL MODELDE: docker --memory bir TAVANDIR, rezervasyon
   değil. Tavanları toplayıp RAM ile kıyaslamak kategori hatasıdır — yolda
   giden arabaların azami hızlarını toplayıp "yol kapasitesi aşıldı" demek
   gibi.

   Bu yüzden BİRİNCİL sayı artık GERÇEK kullanım (toplam − MemAvailable):
   "sunucum doldu mu" sorusunun cevabı odur. Baştan ayrılan (rezerve) ve
   izin verilen üst sınır (tavan) ikincil satırda, ne oldukları YAZILI
   olarak duruyor. Kırmızı yalnız iki durumda çıkar: çekirdek gerçekten
   baskı bildiriyorsa, ya da baştan ayrılanların toplamı dağıtılabilirin
   üstüne çıkmışsa. Tavan toplamının büyük olması TEK BAŞINA arıza
   değildir — bilgilendirici bir rozettir. */

const BASKI_AD = {
  yok: 'yok', orta: 'orta', yuksek: 'YÜKSEK', bilinmiyor: 'ölçülemedi'
};

/* Sözleşmenin YENİ alanları (stack_reserved_mb, allocatable_mb,
   overcommit_ratio/limit, pressure) yoksa eski hesaba düşülür: panel, bu
   alanları henüz göndermeyen bir controller sürümüyle de açılabilmeli.
   Eksik alanı "0" sayıp ekrana basmak, ölçmediğimiz bir şeye kefil olmak
   olurdu; null taşıyoruz ve o satırı hiç yazmıyoruz. */
function bellekModeli(sys) {
  const toplam = sys.mem_total_mb || 0;
  const bos    = sys.mem_available_mb || 0;
  const kullanilan = Math.max(0, toplam - bos);

  const dagitilabilir = sys.allocatable_mb != null
    ? sys.allocatable_mb
    : Math.max(0, toplam - (sys.os_reserve_mb || 0)
                 - (sys.core_reserve_mb || 0));
  const tavan   = sys.stack_committed_mb || 0;
  const rezerve = sys.stack_reserved_mb != null ? sys.stack_reserved_mb : null;
  const sinir   = typeof sys.overcommit_limit === 'number'
    ? sys.overcommit_limit : 1.5;
  const oran = typeof sys.overcommit_ratio === 'number'
    ? sys.overcommit_ratio
    : (dagitilabilir ? tavan / dagitilabilir : 0);

  const bs = sys.pressure || {};
  const seviye = BASKI_AD[bs.seviye] ? bs.seviye : 'bilinmiyor';

  /* SERT KURAL burada: rezerve bir TABANDIR, motor o belleği açılışta
     gerçekten ayırır (shared_buffers, innodb buffer pool, JVM -Xms). Bunun
     aşılması, defterin borcunu ödeyememesi demektir — tavan aşımının
     aksine gerçek bir arızadır. */
  const rezerveAsim = rezerve != null && dagitilabilir > 0
                   && rezerve > dagitilabilir;

  return {
    toplam: toplam, bos: bos, kullanilan: kullanilan,
    dagitilabilir: dagitilabilir, tavan: tavan, rezerve: rezerve,
    oran: oran, sinir: sinir, seviye: seviye, baski: bs,
    rezerveAsim: rezerveAsim,
    kullanimYuzde: toplam ? Math.round((kullanilan / toplam) * 100) : 0,
    tavanYuzde: Math.round(oran * 100),
    tavanButce: Math.round(dagitilabilir * sinir),
    kritik: rezerveAsim || seviye === 'yuksek',
    politikaAsim: oran > sinir
  };
}

const bsSayi = (v) => (typeof v === 'number' ? v.toFixed(2) : '—');

/* Çekirdeğin ölçüsü BAĞLAYICIDIR: defter "yer yok" dese de baskı sıfırsa
   sistemde bellek darlığı yoktur. Rozetin arkasındaki ham sayıları title'da
   veriyoruz ki iddia sınanabilsin — kullanıcı aynı dosyaya kendisi de
   bakabilir. */
function baskiTitle(m) {
  if (m.seviye === 'bilinmiyor') {
    return 'Çekirdeğin bellek baskısı ölçümü (/proc/pressure/memory) '
         + 'okunamadı: bu çekirdekte yok ya da erişilemiyor.';
  }
  return 'Çekirdek ölçümü (/proc/pressure/memory) — süreçlerin bellek '
       + 'beklerken geçirdiği zaman payı: son 10 sn %'
       + bsSayi(m.baski.some10) + ', son 60 sn %' + bsSayi(m.baski.some60)
       + '. Sıfıra yakınsa sistemde bellek darlığı yoktur.';
}

/* Rozet şeridi ve öğüt kutusu HTML'de DEĞİL burada üretiliyor. Aynı üst bar
   iki sayfada (index.html ve yedekler.html) birebir kopya duruyor; ikisini
   ayrı ayrı elle güncellemek, er geç birinin diğerinden farklı bir bellek
   tablosu göstermesi demekti. Tek üretim yeri olsun diye DOM'a buradan
   ekleniyor. */
function bayrakSeridi() {
  const item = document.querySelector('.sys-item-mem');
  if (!item) return null;
  let k = item.querySelector('.sys-flags');
  if (!k) {
    k = document.createElement('div');
    k.className = 'sys-flags';
    item.appendChild(k);
  }
  return k;
}

function ogutKutusu() {
  let el = document.getElementById('mem-advice');
  if (el) return el;
  const ana = document.querySelector('main');
  if (!ana || !ana.parentNode) return null;
  el = document.createElement('section');
  el.id = 'mem-advice';
  el.className = 'mem-advice';
  el.hidden = true;
  ana.parentNode.insertBefore(el, ana);
  return el;
}

/* Kutu 5 saniyede bir yeniden yazılırsa içindeki düğmenin odağı kaybolur ve
   klavyeyle gezen kullanıcı düğmeye bir türlü basamaz. İçerik gerçekten
   değişmedikçe innerHTML'e dokunmuyoruz — ızgarada da aynı desen var. */
let sonOgutHtml = '';

function renderSystem() {
  const sys = STATE.system || {};
  $('#sys-host').textContent = location.hostname;
  $('#sys-cpu').textContent  = (sys.cpus || '—') + ' çekirdek';
  $('#sys-disk').textContent = mb(sys.disk_free_mb) + ' boş';

  if (!sys.mem_total_mb) return;
  const m = bellekModeli(sys);

  /* Etiket de değişmek zorunda: HTML'de "Ayrılan bellek" yazıyor, oysa
     büyük sayı artık ayrılanı değil KULLANILANI gösteriyor. Yanlış başlıkla
     doğru sayı, yanlış sayıdan daha kötüdür. */
  const et = document.querySelector('.sys-item-mem .sys-label');
  if (et) et.textContent = 'Bellek kullanımı';
  const olcek = document.querySelector('.sys-item-mem .meter');
  if (olcek) olcek.setAttribute('aria-label', 'Bellek kullanımı');

  $('#sys-mem').textContent = mb(m.kullanilan) + ' / ' + mb(m.toplam);

  /* İkincil satır: ayrılanların İKİSİ DE, ne oldukları söylenerek. Tek bir
     "ayrılan" sayısı, tabanla tavanı aynı kefeye koyduğu için bu ekranın
     ilk hatasıydı. */
  const rel = $('#sys-mem-real');
  if (rel) {
    const parca = [];
    if (m.rezerve != null) parca.push('baştan ayrılan ' + mb(m.rezerve));
    parca.push('üst sınır ' + mb(m.tavan));
    rel.textContent = parca.join(' · ');
    rel.className = 'sys-sub' + (m.kritik ? ' sys-sub-warn' : '');
  }

  const item = document.querySelector('.sys-item-mem');
  if (item) {
    item.title =
      'Gerçek kullanım: ' + mb(m.kullanilan) + ' / ' + mb(m.toplam) + ' RAM.'
      + (m.rezerve != null
          ? '\nBaştan ayrılan (rezerve): ' + mb(m.rezerve)
            + ' — motorların açılışta gerçekten ayırdığı bellek.'
          : '')
      + '\nİzin verilen üst sınır (tavan): ' + mb(m.tavan)
      + ' — docker limitlerinin toplamı, rezervasyon değil.'
      + '\nDağıtılabilir: ' + mb(m.dagitilabilir)
      + ' (toplam − işletim sistemi payı − çekirdek servisler).'
      + '\nÇekirdek bellek baskısı: ' + BASKI_AD[m.seviye] + '.';
  }

  const bar = $('#sys-mem-bar');
  if (bar) {
    /* Çubuk GERÇEK kullanımı gösteriyor. Tavan oranını gösterseydi %122'de
       sürekli dolu bir kırmızı çubuk olurdu — hem de makine boşken. */
    bar.style.width = Math.min(100, m.kullanimYuzde) + '%';
    bar.className = 'meter-fill'
      + (m.kritik || m.kullanimYuzde > 90 ? ' crit'
         : m.kullanimYuzde > 75 ? ' hot' : '');
  }

  /* --- rozetler: baskı her zaman, aşırı taahhüt yalnız varsa --- */
  const ser = bayrakSeridi();
  if (ser) {
    const bay = [];
    bay.push('<span class="sys-flag'
      + (m.seviye === 'yuksek' ? ' is-err'
         : m.seviye === 'orta' ? ' is-warn' : '')
      + '" title="' + esc(baskiTitle(m)) + '">bellek baskısı: '
      + esc(BASKI_AD[m.seviye]) + '</span>');

    if (m.rezerveAsim) {
      bay.push('<span class="sys-flag is-err" title="'
        + esc('Açık motorların baştan ayırdığı toplam ' + mb(m.rezerve)
              + ', dağıtılabilir bellekten (' + mb(m.dagitilabilir)
              + ') fazla. Bu bellek gerçekten tutulur; tavanların aksine '
              + 'yeniden dağıtılamaz.')
        + '">baştan ayrılanlar dağıtılabiliri aştı</span>');
    }
    /* Tavan toplamının kapasiteyi aşması BİLGİDİR, arıza değil: limitler
       birer üst sınırdır ve hepsi aynı anda dolmaz. Bunu kırmızıya boyamak,
       kullanıcıyı olmayan bir arızanın peşine düşüren eski davranıştı. */
    if (m.tavanYuzde > 100) {
      bay.push('<span class="sys-flag' + (m.politikaAsim ? ' is-warn' : '')
        + '" title="' + esc('Açık motorların docker üst sınırları toplamı '
              + mb(m.tavan) + '; dağıtılabilir bellek '
              + mb(m.dagitilabilir) + '. Politika ' + m.sinir.toFixed(1)
              + ' katına kadar izin veriyor (' + mb(m.tavanButce) + ').')
        + '">tavan toplamı %' + m.tavanYuzde
        + ' — tavanlar aynı anda dolmaz</span>');
    }
    const bh = bay.join('');
    if (ser.innerHTML !== bh) ser.innerHTML = bh;
  }

  /* --- ne yapmalı: yalnız gerçekten yapılacak bir şey varsa --- */
  const kutu = ogutKutusu();
  if (!kutu) return;
  let h = '';
  if (m.rezerveAsim) {
    h = '<p class="mem-advice-t"><b>Baştan ayrılan bellek dağıtılabilirin '
      + 'üstünde.</b> Açık motorların açılışta gerçekten ayırdığı toplam '
      + mb(m.rezerve) + ', dağıtılabilir bellek ise ' + mb(m.dagitilabilir)
      + '. Tavanların aksine bu bellek gerçekten tutulur.</p>'
      + '<p class="mem-advice-n">Yapılacak şey: kullanmadığınız bir '
      + 'veritabanını kapatın. Üst sınırları yeniden hesaplamak burada işe '
      + 'yaramaz — taban, motorun kendi ayarından gelir ve ancak yeniden '
      + 'başlatmayla değişir.</p>';
  } else if (m.politikaAsim) {
    h = '<p class="mem-advice-t"><b>Üst sınırların toplamı politika sınırını '
      + 'aştı.</b> Açık motorlara verilen tavanlar toplamı ' + mb(m.tavan)
      + '; politika, dağıtılabilir belleğin (' + mb(m.dagitilabilir) + ') '
      + m.sinir.toFixed(1) + ' katına — yani ' + mb(m.tavanButce)
      + ' — kadar izin veriyor. Şu an bir sorun görünmüyor (gerçek kullanım '
      + mb(m.kullanilan) + ', çekirdek baskısı ' + esc(BASKI_AD[m.seviye])
      + '); ama motorların hepsi aynı anda tavanına dayanırsa cgroup OOM '
      + 'killer devreye girer ve birini öldürür.</p>'
      + '<p class="mem-advice-n"><b>Yeniden dengele</b>: açık motorların üst '
      + 'sınırları bugünkü koşullara göre yeniden hesaplanır ve '
      + '<code>docker update</code> ile uygulanır. <b>Veritabanları yeniden '
      + 'başlatılmaz</b>, bağlantılarınız kopmaz.</p>'
      + '<div class="mem-advice-act">'
      + '<button class="btn" data-act="rebalance">Yeniden dengele</button>'
      + '</div>';
  }
  if (h !== sonOgutHtml) {
    kutu.innerHTML = h;
    sonOgutHtml = h;
  }
  kutu.className = 'mem-advice' + (m.rezerveAsim ? ' is-err' : '');
  kutu.hidden = !h;
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
         ><span class="tool-ico">${esc(e.icon || '')}</span> ${esc(e.name)} aç</button>`
      : `<a class="tool-link" href="#eng-${esc(e.id)}"
           title="Satırına git"><span class="tool-ico">${esc(e.icon || '')}</span> ${esc(e.name)}</a>`);
  });

  /* Yedekler artık ayrı bir sayfa. Bağlantısı "Araçlar" satırında, izleme
     kısayolunun yanında duruyor: panelin içinden kaldırılan bir bölüm, yerine
     görünür bir kapı bırakmazsa kullanıcı için SİLİNMİŞ demektir. */
  toolLinks.push(`<a class="tool-link" href="/yedekler"
      title="Yedek dosyaları, zamanlama ve geri yükleme"><span class="tool-ico">💾</span> Yedekler</a>`);

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
      <span class="event-time">${new Date(e.ts * 1000).toLocaleString(T('tr-TR'))}</span>
      <span>${icon[e.level] || '•'} <b>${esc(e.engine)}</b> — <span
        class="event-msg">${esc(e.message)}</span></span>
    </div>`).join('');
}

/* BAKIM (şişkinlik). Ayrı bir uçtan ve SEYREK okunuyor: şişkinlik günler
   içinde birikir, 5 saniyede bir sormanın anlamı yok. Controller da zaten
   önbellekten cevap veriyor. */
let BAKIM = null;
let bakimSonCagri = 0;

async function refreshBakim() {
  if (Date.now() - bakimSonCagri < 300000) return;   // 5 dakika
  bakimSonCagri = Date.now();
  try { BAKIM = await api('/maintenance'); } catch (e) { /* sessiz: bakım
    bilgisi olmadan da panel çalışır, hata basmak paniğe değmez */ }
}

/* SON BİR SAAT — veritabanının İÇİ.
   Olay günlüğü yığının kendi işlerini yazar; bu bölüm veritabanının içini
   yazar. "Dün gece dondu, sabah baktım normal" sorusunun cevabı burada.

   KAPSAMA ÖNCE GELİYOR, bilerek: %10 kapsamalı bir aralıktan çıkarılan
   "en çok bekleten sorgu" hiçbir şey kanıtlamaz ve kanıtladığını sanmak
   daha kötüdür. Ölçülemeyen saniyeleri ayrıca yazıyoruz — ölçüm yokluğunu
   "sistem boştu" diye göstermek bu panelin engellemeye çalıştığı hata. */
async function refreshAsh() {
  const bolum = document.getElementById('ash-section');
  const kutu = document.getElementById('ash');
  if (!bolum || !kutu) return;
  let d;
  try { d = await api('/ash'); } catch (e) { bolum.hidden = true; return; }
  const motorlar = Object.entries(d.engines || {}).filter(([, v]) => v.aktif);
  if (!motorlar.length) { bolum.hidden = true; return; }
  bolum.hidden = false;

  kutu.innerHTML = motorlar.map(([eid, v]) => {
    const k = v.son_saat || {};
    const o = v.ozet || {};
    const ad = (CATALOG && (CATALOG.engines.find((e) => e.id === eid) || {}).name) || eid;
    if (!v.ornekleniyor) {
      return `<div class="ash-eng"><b>${esc(ad)}</b>
        <span class="fact-err">örnekleme durdu</span>
        ${v.hata ? '<span class="card-detail">' + esc(v.hata) + '</span>' : ''}</div>`;
    }
    const oran = Math.round((k.oran || 0) * 100);
    const eksik = (k.aralik_sn || 0) - (k.olculen_sn || 0);
    const kaps = `<span class="ash-cov" title="son bir saatin ${oran}%'i örneklendi"
        >kapsama %${oran}${eksik > 0 ? ' · ' + eksik + ' sn ölçülemedi' : ''}</span>`;
    const bek = (o.beklemeler || []).map((b) =>
      `<li>${esc(b.ad)} <span class="card-detail">${b.ornek} örnekte</span></li>`).join('');
    const eng = (o.bekletenler || []).map((b) =>
      `<li>pid ${b.pid} <span class="card-detail">${b.ornek} örnekte bekletti</span></li>`).join('');
    /* Yığının kendi işleri: bir donmanın en olası sebebi ÜRÜNÜN KENDİSİDİR.
       Bunu söyleyebilen tek yer burası — hem motorları hem işleri aynı
       ürün yönetiyor. */
    const isler = (o.yigin_isleri || []).map((i) =>
      `<li>${esc(i.kind)}${i.engine ? ' (' + esc(i.engine) + ')' : ''}
         <span class="card-detail">${i.suruyor ? T('sürüyor') : i.sure_sn + ' ' + T('sn')}</span></li>`).join('');
    const en = (o.en_cok_oturum || {}).n || 0;
    return `<div class="ash-eng">
      <b>${esc(ad)}</b> ${kaps}
      <span class="card-detail">en çok ${en} eşzamanlı oturum</span>
      <div class="ash-cols">
        <div><h4>Beklemeler</h4>${bek ? '<ul>' + bek + '</ul>'
          : '<p class="card-detail">bekleme görülmedi</p>'}</div>
        <div><h4>Bekletenler</h4>${eng ? '<ul>' + eng + '</ul>'
          : '<p class="card-detail">kimse kimseyi bekletmedi</p>'}</div>
        <div><h4>Bu saatte yığının işleri</h4>${isler ? '<ul>' + isler + '</ul>'
          : '<p class="card-detail">yığın kendi işini çalıştırmadı</p>'}</div>
      </div>
    </div>`;
  }).join('');
}

async function refresh() {
  refreshBakim();
  refreshAsh();
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
    case 'maintenance': p = runMaintenance(engine); break;
    // Motora bağlı değil: dataset.id yok, engine undefined kalır.
    case 'rebalance': p = rebalance(); break;
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

/* Dil değişince kartları yeniden çiziyoruz: sözlük DOM'a uygulanıyor ama
   "3 saat önce" gibi birleştirilmiş metinler ancak yeniden çizimle düzelir. */
document.addEventListener('dbstack:dil', function () { refresh(); });
