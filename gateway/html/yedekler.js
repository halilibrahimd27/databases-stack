/* Yedekler sayfası (/yedekler) — bağımlılıksız, tek dosya.

   NEDEN AYRI SAYFA: yedekler panelin içindeyken “Şu an açık” ve “Kapalı”
   bölümlerinin altında, sayfanın üçte ikisi aşağıda duruyordu; üstelik panel
   5 saniyede bir kendini yeniden çizdiği için orada bir dosya listesi açıp
   incelemek huzursuzdu. Yedek listesine bakan insan başka bir soru soruyor
   (“dün gece kopya alındı mı, alınmadıysa neden”) ve o soru kendi ekranını
   hak ediyor. Panelde artık yalnız kartın üstündeki “Şimdi yedek al” düğmesi
   kaldı — o düğme motorla uğraşırken doğan bir isteğin cevabı.

   Bu dosya app.js'in kardeşi, kopyası değil: ortak olan şey ölçüler
   (api/esc/mb, üst bar hesabı, watchJob deseni), farklı olan şey sayfanın
   kendi mantığı. İkisini tek dosyada tutmak, panelin her turunda yedek
   çizim kodunu da yüklemek demekti.
*/
'use strict';

/* i18n.js yüklenmemişse panel yine çalışsın: metni olduğu gibi döndür. */
const T = (x, b) => (typeof t === 'function' ? t(x, b) : x);

/* Şifreli yedek, anahtarı olmayan bir kurulumda kurtarma noktası DEĞİLDİR.
   Aynı cümleyi üç yerde kullanıyoruz (rozet, iki düğmenin balonu); tek yerde
   durması, birinin güncellenip diğerlerinin eskimesini engelliyor. */

/* "Bu dosya hangi şemayı geri getirir" — yedek alınırken kaydedilen parmak
   izi. Kısa biçim GÖSTERİM için; karşılaştırmayı prova tam parmak iziyle
   yapıyor. '?' işareti, yedek alınırken şemanın değiştiğini söyler: o
   dosyanın hangi şemayı taşıdığı kesin değildir. */
function SEMA_BALON(s) {
  const o = s.objects || {};
  const p = [];
  if (o.table != null) p.push(o.table + ' tablo');
  if (o.index != null) p.push(o.index + ' indeks');
  if (o.constraint != null) p.push(o.constraint + ' kısıt');
  if (o.view) p.push(o.view + ' view');
  if (o.trigger) p.push(o.trigger + ' trigger');
  if (o.routine) p.push(o.routine + ' rutin');
  const kuyruk = s.stable === false
    ? ' — yedek alınırken şema DEĞİŞTİ, bu bağlantı kesin değil' : '';
  return 'Yedek alınırken kaydedilen şema: ' + p.join(' · ') + kuyruk;
}
const ACILMAZ = 'Bu yedek şifreli ve bu kurulumda BACKUP_ENCRYPT_KEY tanımlı '
  + 'değil — içi okunamaz ve geri yüklenemez. Yedeği alan kurulumun '
  + 'anahtarını .env dosyasına ekleyin.';

const API = '/api';
const $   = (s) => document.querySelector(s);

let CATALOG = null;
let STATUS  = { engines: [], system: {} };

/* GET /api/backups'ın son yanıtı. null = uç hiç cevap vermedi (controller
   kapalı ya da bu ucu tanımayan eski bir sürüm). Panelde bu durumda bölüm
   sessizce kayboluyordu; BURADA kaybolamaz — sayfanın tamamı bu veriyle
   ilgili, boş bir ekran “yedeğim yok” diye okunurdu. Sebebini yazıyoruz. */
let BACKUPS = null;

/* Geri yükleme, backup.sh'ta motor motor yazılmış bir iştir: her motorun
   dump biçimi ve yükleme aracı başka. Karar controller'da ve doğru yerde —
   backup_script_can_restore() betikte `restore_<motor>()` var mı diye BAKAR,
   yoksa uç 400 döner. Ama o cevap ancak istek gittikten sonra gelir; düğmeyi
   tıklanır bırakmak, kullanıcıya motor adını harf harf yazdırıp saniyesinde
   “bu motorda otomatik geri yükleme yok” demek olurdu.
   BU LİSTE BİR KOPYADIR ve kopya olduğu için yanılabilir: yeni bir restore_*
   eklendiği gün burada düğme çıkmaz. O yüzden yalnız KAPATMAK için, hem de
   sebebi title'da yazılı olarak kullanılıyor; controller bir gün “geri
   yüklenebilir mi”yi yanıtına koyarsa ona uyuluyor (bkz. rowHtml). */
const GERI_YUKLENEBILIR = ['mariadb', 'postgresql', 'mongodb', 'redis',
                           'mssql'];

/* ---------------------------------------------------------------- yardımcı */
async function api(path, opts) {
  const r = await fetch(API + path, opts);
  if (!r.ok) throw new Error((await r.text()) || ('HTTP ' + r.status));
  return r.json();
}
/* Ham içerik JSON DEĞİL, düz metin gelir: 50 KB'lık SQL'i JSON dizgesine
   gömmek hem boyutu şişirir hem okunmaz hâle getirir. */
async function apiText(path) {
  const r = await fetch(API + path);
  if (!r.ok) throw new Error((await r.text()) || ('HTTP ' + r.status));
  return r.text();
}
const mb = (v) => (v == null ? '—'
  : v >= 1024 ? (v / 1024).toFixed(v >= 10240 ? 0 : 1) + ' GB' : Math.round(v) + ' MB');
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

/* Pencerelerdeki "etiket … değer" satırı — app.js'tekiyle aynı biçim.
   İki sayfada iki farklı görünen aynı satır, kullanıcıya iki farklı
   ürüne bakıyormuş hissi veriyordu. */
const planSatir = (ad, deger) =>
  `<div class="plan-line"><span>${esc(ad)}</span><b>${esc(deger)}</b></div>`;

/* mb() MEGABAYT alır; yedek boyutları ise BAYT gelir ve bu ölçekte küçük
   dosyalar kayboluyordu: 40 KB'lık taze bir Redis rdb'si “0 MB” görünüyor,
   kullanıcı da dosyanın boş olduğunu sanıyordu. Ayrı bir birim gerekiyor. */
const bayt = (n) => {
  if (n == null) return '—';
  if (n < 1024) return Math.round(n) + ' B';
  if (n < 1048576) return Math.round(n / 1024) + ' KB';
  if (n < 1073741824) return (n / 1048576).toFixed(n < 10485760 ? 1 : 0) + ' MB';
  return (n / 1073741824).toFixed(1) + ' GB';
};

/* “1772412000” kimseye bir şey anlatmıyor, “2 saat önce” anlatıyor: yedeğin
   TAZE olup olmadığı bu sayfadaki tek gerçek soru. Mutlak tarih kaybolmuyor,
   title'da duruyor (bkz. tamTarih). Gelecek zamanı da aynı işlev veriyor;
   “sıradaki yedek” için ikinci bir işlev yazmak ikisinin ayrışması demekti. */
function bagilZaman(ep) {
  if (!ep) return '';
  const fark = Math.round(Date.now() / 1000) - ep;
  const gecmis = fark >= 0;
  const s = Math.abs(fark);
  let n, ad;
  if (s < 90) return gecmis ? T('az önce') : T('birazdan');
  if (s < 5400)        { n = Math.round(s / 60);    ad = 'dakika'; }
  else if (s < 129600) { n = Math.round(s / 3600);  ad = 'saat'; }
  else                 { n = Math.round(s / 86400); ad = 'gün'; }
  /* Kalıp olarak çevriliyor: İngilizcede "in 3 minutes" öne geçiyor,
     Türkçede "3 dakika sonra" sona kalıyor. */
  return T(gecmis ? '%s önce' : '%s sonra').replace('%s', n + ' ' + birim(n, ad));
}

/* Türkçede çoğul eki yok ("3 dakika"), İngilizcede var ("3 minutes").
   Üç birim de düzenli çoğul aldığı için tek 's' yetiyor. */
function birim(n, ad) {
  const c = T(ad, 'zaman');
  return (n === 1 || c === ad) ? c : c + 's';
}

const tamTarih = (ep) => (ep
  ? new Date(ep * 1000).toLocaleString(T('tr-TR'))
  : '');

/* ------------------------------------------------------------- pencereler */

/* Dördüncü parametre (dogrula) bu sayfa için var: verilirse pencere gövdesine
   konmuş #onay-inp kutusuna O METİN yazılana kadar onay düğmesi kapalı kalır.
   Geri yükleme tek tıkla başlayamaz — “Devam” demenin bedeli, o motordaki
   bugünkü verinin tamamı. */
function confirmBox(title, bodyHtml, okLabel = 'Devam', dogrula) {
  return new Promise((resolve) => {
    const ok = $('#modal-ok');
    $('#modal-title').textContent = title;
    $('#modal-body').innerHTML = bodyHtml;
    ok.textContent = okLabel;
    ok.hidden = false;
    ok.disabled = false;
    $('#modal-cancel').textContent = 'Vazgeç';
    $('#modal').hidden = false;

    if (dogrula) {
      const inp = $('#onay-inp');
      ok.disabled = true;
      if (inp) {
        /* Karşılaştırma tr yerine DEĞİŞMEZ küçük harfle: Türkçe kurallarda
           "MARIADB".toLocaleLowerCase('tr') → "marıadb" olur ve caps lock'lu
           kullanıcı doğru yazdığı hâlde düğmeyi hiç açamazdı. Aranan şey
           dikkat, imla sınavı değil. */
        const esittir = () => inp.value.trim().toLowerCase()
                            === String(dogrula).trim().toLowerCase();
        inp.addEventListener('input', () => { ok.disabled = !esittir(); });
        setTimeout(() => inp.focus(), 0);
      }
    }

    const close = (v) => {
      $('#modal').hidden = true;
      ok.disabled = false;      // pencere bir sonraki iş için temiz kalsın
      resolve(v);
    };
    ok.onclick = () => { if (!ok.disabled) close(true); };
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

/* Yedekleme ve geri yükleme uzun sürer; controller ikisini de bir "job"a
   çeviriyor, biz de log'u canlı gösteriyoruz ki kullanıcı “takıldı mı?” diye
   merak etmesin. Pencerenin ipucu cümlesi işe göre değişiyor: HTML'deki
   varsayılan metin geri yüklemenin ne yaptığını anlatmıyor. */
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
      /* Başarısızlığın SEBEBİ pencerede kalır. Yalnız “⛔ Başarısız” yazıp
         kapatmak, geri yükleme gibi bir işte kullanıcıyı verisinin ne
         durumda olduğunu bilmeden bırakırdı. */
      if (job.reason) $('#job-log').textContent += '\n\n' + job.reason;
      // Ertelenen iş BAŞARISIZ DEĞİLDİR: kilit görevini yapmış, veriye
      // dokunulmamıştır. Başlıkta da öyle yazsın — kullanıcı yedeğinin
      // bozulduğunu sanmasın. (Ölçülen olay: 'Yedek al'a basıldı, o an
      // sunucuda başka bir yedekleme sürüyordu.)
      if (job.deferred) {
        $('#job-title').textContent = '⏳ Ertelendi';
        $('#job-log').textContent += SATIR_SONU + SATIR_SONU
          + 'Veriye dokunulmadı. Sunucuda o an başka bir yedekleme ya da '
          + 'geri yükleme sürüyordu; o iş bitince tekrar deneyebilirsiniz.';
      }
      $('#job-close').disabled = false;
      return job;
    }
    await new Promise((r) => setTimeout(r, 1200));
  }
  $('#job-close').disabled = false;
  return null;
}

/* ------------------------------------------------------------------ eylem */

/* Zamanlama TEK uçtan, gövdenin TAMAMIYLA gider. Sözleşme kısmi güncelleme
   tanımıyor: yalnız değişen alanı yollasaydık, saati düzelten kullanıcı
   aynı istekle otomatik yedeği de kapatmış olurdu. Bu yüzden eksik alanlar
   ekrandaki son duruma göre tamamlanıyor. */
async function saveSchedule(patch) {
  const s = (BACKUPS && BACKUPS.schedule) || {};
  await api('/backup/schedule', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      enabled: patch.enabled != null ? !!patch.enabled : !!s.enabled,
      time: patch.time || s.time || '02:00',
      retention_days: patch.retention_days != null
        ? patch.retention_days : (s.retention_days || 7)
    })
  });
  await refreshBackups(true);
}

/* Açmak sessizce olur, KAPATMAK sorulur. Tek tıkla kapanan bir zamanlama,
   kapandığını yalnız o an ekranda yazar; sonuç ise haftalar sonra, veri
   kaybının olduğu gün anlaşılır. Onay penceresi bunun bedelini bir cümleyle
   söylüyor. */
async function toggleSchedule(on) {
  if (!on) {
    const ok = await confirmBox('Otomatik yedek kapatılsın mı?', `
      <p>Bundan sonra <b>hiçbir yedek alınmaz</b>. Var olan dosyalar silinmez
         ama yaşlanır: bugünden sonraki veriler hiçbir kopyada bulunmaz.</p>
      <p class="note">İstediğiniz zaman aynı düğmeyle geri açabilirsiniz.</p>`,
      'Kapat');
    if (!ok) return;
  }
  await saveSchedule({ enabled: on });
}

/* Elle yedek, aktivasyonla AYNI iş mekanizmasını kullanır: uzun süren her
   işlem controller'da bir "job"a dönüşür, sayfa da log'u canlı gösterir. */
/* Elle başlatılan işin SONUCU, pencere kapandıktan sonra da görünsün.
   Ölçülen olay: kullanıcı "Yedek al"a bastı, o sırada sunucuda başka bir
   yedekleme sürüyordu, iş kilide takılıp ertelendi — pencere kapanınca
   ekranda hiçbir iz kalmadı ve kullanıcı haklı olarak "hata vermedi ama
   yedek de alınmamış" dedi. Not, o motorun satırında durur; yeni bir yedek
   alınınca ya da sayfa yenilenince kalkar. */
const SATIR_SONU = String.fromCharCode(10);
const SON_DENEME = {};

/* YEDEĞİN İÇİ — geri yüklemeden.
   "Yedek var" cümlesi iki soruyu cevaplar sanılır ama yalnız birini
   cevaplar: dosya duruyor mu. İkincisi — içinde ne var — bugüne kadar ancak
   üretimi riske atıp geri yükleyerek öğrenilebiliyordu. Oysa sabah sorulan
   soru genelde şu: "dün silinen 'siparisler' tablosu bu yedekte VAR MI?"

   SATIR VERİSİ GÖSTERMİYORUZ, bilerek: paneli açabilen herkesin müşteri
   satırlarını tarayıcıda okuyabildiği bir görüntüleyici, şifreli yedek
   özelliğini kendi eliyle iptal ederdi. Adlar ve sayılar yeter. */
async function inspectBackup(engine, dosya) {
  // infoBox başlığı textContent ile yazılıyor; esc() burada İKİ KEZ
  // kaçış yapıp dosya adını bozardı.
  infoBox(dosya,
    '<p class="card-detail">Yedek okunuyor — geri yükleme YAPILMIYOR, dosya '
    + 'yalnız akıtılarak taranıyor…</p>');
  let d;
  try {
    d = await api('/backups/' + engine.id + '/inspect?file='
                  + encodeURIComponent(dosya));
  } catch (e) {
    infoBox(dosya, '<p class="bk-warn">Okunamadı: ' + esc(e.message) + '</p>');
    return;
  }
  if (d.kapsam === false) {
    infoBox(dosya, '<p>Bu motorun yedek biçimi okunamıyor.</p>'
      + '<p class="card-detail">' + esc(d.detail || '') + '</p>');
    return;
  }
  if (!d.ok) {
    infoBox(dosya, '<p class="bk-warn">' + esc(d.detail || 'okunamadı') + '</p>');
    return;
  }
  const satirlar = (d.tablolar || []).map((t) => `
    <tr><td>${esc(t.ad)}</td>
        <td class="num">${t.satir}${t.satir_kesin ? '' : '<span title="INSERT sayısından tahmin — kesin sayı ancak geri yükleyerek bulunur">~</span>'}</td></tr>`).join('');
  const kesik = d.kesildi
    ? '<p class="bk-warn">Dosya çok büyük olduğu için tamamı taranmadı — '
      + 'liste EKSİK olabilir.</p>' : '';
  const gor = (d.gorunumler || []).length
    ? '<p class="card-detail">Görünümler: ' + esc(d.gorunumler.join(', ')) + '</p>' : '';
  infoBox(dosya,
    `<p>${d.tablo_sayisi} tablo · ${d.gorunum_sayisi} görünüm · `
    + `${d.rutin_sayisi} rutin · ${d.indeks_sayisi} indeks`
    + `${d.encrypted ? ' · <b>şifreli</b>' : ''}</p>`
    + kesik
    + (satirlar
        ? `<table class="bk-inspect"><thead><tr><th>Tablo</th>
             <th class="num">Satır</th></tr></thead><tbody>${satirlar}</tbody></table>
           <p class="card-detail">“~” işaretli sayılar TAHMİNDİR (INSERT
             satırlarından sayıldı); işaretsizler dökümdeki veri bloğundan
             birebir sayılmıştır.</p>`
        : '<p>Tablo bulunamadı.</p>')
    + gor
    + `<p class="card-detail">Bu liste yalnız ad ve sayı verir.
         Dosyanın kendisini görmek için:
         <button class="btn btn-sm" data-act="inspect-raw"
           data-id="${esc(engine.id)}" data-file="${esc(dosya)}"
           >SQL'i göster</button></p>`);
}

/* DÖKÜMÜN KENDİSİ — ilk N KB, olduğu gibi.
   Yapı özeti "hangi tablolar var" der; bu "dosyanın içinde ne yazıyor" der.
   İkisi ayrı sorular: dökümün başında motor sürümü, karakter seti, dump
   seçenekleri ve şema tanımı yazar; bir geri yüklemenin neden tutmayacağı
   çoğu zaman orada görünür.

   ⚠ GERÇEK VERİ İÇEREBİLİR. Yapı özetinin aksine burada satırlar da
   görünebilir (dökümün ileri kısımlarında INSERT'ler var). Bu yüzden AYRI
   bir düğme ve ekranda AÇIK bir uyarı: kullanıcı ne istediğini bilerek
   istiyor. */
async function inspectRaw(engine, dosya, kb) {
  const n = kb || 50;
  infoBox(dosya, `<p class="card-detail">Dökümün ilk ${n} KB'ı okunuyor…</p>`);
  let metin;
  try {
    metin = await apiText('/backups/' + engine.id + '/inspect?ham=1&kb=' + n
                          + '&file=' + encodeURIComponent(dosya));
  } catch (e) {
    infoBox(dosya, '<p class="bk-warn">Okunamadı: ' + esc(e.message) + '</p>');
    return;
  }
  const bayt = new TextEncoder().encode(metin).length;
  const kirpik = bayt >= n * 1024;
  infoBox(dosya,
    `<p class="card-detail">Dökümün ilk ${n} KB'ı${kirpik ? ' (kırpıldı)' : ''}
       — geri yükleme YAPILMADI.</p>`
    + '<p class="bk-warn">Bu görünüm gerçek veri içerebilir; yedeğin '
    + 'kendisini gösteriyor.</p>'
    + '<pre class="bk-raw">' + esc(metin) + '</pre>'
    + (kirpik
       ? `<p class="card-detail">Daha fazlası:
            <button class="btn btn-sm" data-act="inspect-raw"
              data-id="${esc(engine.id)}" data-file="${esc(dosya)}"
              data-kb="${n * 4}">${n * 4} KB göster</button></p>`
       : ''));
}

async function takeBackup(engine) {
  const r = await api('/engines/' + engine.id + '/backup', { method: 'POST' });
  const bitti = await watchJob(r.job, engine.name + ' yedekleniyor…',
    'Yedek, veritabanı çalışırken alınır. Büyük bir veritabanında birkaç ' +
    'dakika sürebilir; pencereyi kapatsanız da iş sunucuda devam eder.');
  if (bitti && bitti.state !== 'done') {
    SON_DENEME[engine.id] = bitti.deferred
      ? { tur: 'ertelendi',
          metin: 'son deneme ertelendi — sunucuda başka bir yedekleme ya da '
               + 'geri yükleme sürüyordu; birkaç dakika sonra tekrar deneyin' }
      : { tur: 'hata',
          metin: 'son deneme başarısız: '
               + (String(bitti.reason || '').split(SATIR_SONU)[0]
                  || 'sebep bilinmiyor') };
  } else {
    delete SON_DENEME[engine.id];
  }
  // Liste normalde 30 saniyede bir tazeleniyor; işi kendi başlatan kullanıcı
  // ise yeni dosyayı HEMEN görmeli, yoksa "yedek alındı ama listede yok".
  await refreshBackups(true);
}

/* KURTARMA PROVASI — bu sayfadaki tek "yıkıcı görünüp yıkıcı olmayan" iş.
   Onay istemiyoruz: prova tek kullanımlık bir kopyada çalışır, üretime
   dokunmaz. Ama uzun sürebilir (yedek boyutuna göre dakikalar), o yüzden
   iş penceresi bunu söylüyor. */
async function runDrill(engine) {
  const r = await api('/engines/' + engine.id + '/drill', { method: 'POST' });
  const bitti = await watchJob(r.job, engine.name + ' kurtarma provası…',
    'Yedek, TEK KULLANIMLIK bir kopyada geri yükleniyor. Üretim '
    + 'veritabanınıza dokunulmaz. Büyük bir yedekte birkaç dakika sürebilir.');
  if (bitti && bitti.state !== 'done') {
    SON_DENEME[engine.id] = bitti.deferred
      ? { tur: 'ertelendi',
          metin: 'prova ertelendi — sunucuda başka bir yedekleme ya da geri '
               + 'yükleme sürüyordu' }
      : { tur: 'hata',
          metin: 'prova başarısız: '
               + (String(bitti.reason || '').split(SATIR_SONU)[0]
                  || 'sebep bilinmiyor') };
  } else {
    delete SON_DENEME[engine.id];
  }
  await refreshBackups(true);
}

/* GERİ YÜKLEME — bu sayfadaki tek geri dönüşsüz iş.
   Onay penceresi üç şeyi birden söylemek zorunda: ne olacağı, hangi dosyaya
   dönüleceği ve o dosyanın tarihi. Dosya adını göstermeden onay istemek,
   kullanıcıya “bir yedeğe dön” dedirtmek olurdu — hangisine döndüğünü ancak
   iş bittikten sonra öğrenirdi. Motor adını yazdırmak da bilerek: yanlışlıkla
   basılan tek bir düğme burada günün verisini siler. */
/* GÖLGE GERİ YÜKLEME — bu ürünün tek "iki yönlü" yıkıcı işlemi.
   Klasik geri yükleme üretimin verisini siler ve geri yükleme SÜRESİ boyunca
   motor kullanılamaz. Gölge yolu yedeği yeni bir kopyaya yükler, üretim bu
   sırada çalışmaya devam eder, sonra işaretçi çevrilir. Kullanıcıya iki sayıyı
   birbirinden ayırarak sunuyoruz: geri yükleme ne kadar sürer, KESİNTİ ne
   kadar sürer. Bunları karıştırmak, vaadi olduğundan büyük göstermek olurdu.
   Bedelini de saklamıyoruz: takas anına kadar üretim ESKİ veriyi servis
   etmeye devam eder ve diskte bir kopyalık fazladan yer gider. */
async function shadowRestore(engine, f) {
  const ok = await confirmBox(engine.name + ' yeni kopyaya geçsin mi?', `
    <p>Yedek <b>yeni bir kopyaya</b> geri yüklenir; ${esc(engine.name)}
       bu sırada <b>çalışmaya devam eder</b>. Kopya açılıp satırları
       doğrulandıktan sonra üretim ona geçer.</p>
    <div class="plan-line"><span>Yüklenecek dosya</span><b>${esc(f.file)}</b></div>
    <div class="plan-line"><span>Yedeğin tarihi</span><b>${esc(tamTarih(f.epoch))}</b></div>
    <div class="plan-line"><span>Dosya boyutu</span><b>${esc(bayt(f.bytes))}</b></div>
    <p class="note"><b>Kesinti yalnız geçiş anındadır</b> — geri yükleme
       süresi kadar değil. Geri yükleme dakikalar sürebilir; motor o süre
       boyunca açık kalır.</p>
    <p class="note">Bunun bedeli: geçişe kadar ${esc(engine.name)}
       <b>bugünkü (belki bozuk) veriyi</b> servis etmeye devam eder, ve
       diskte bir kopyalık fazladan yer gerekir. Yer yetmezse işlem
       başlamadan sayıyla söylenir.</p>
    <p class="note">Geçişten sonra <b>eski veri 24 saat saklanır</b>: karar
       yanlışsa tek düğmeyle geri dönülür. Klasik geri yüklemede bu düğme
       yoktur.</p>`,
    'Yeni kopyaya geç');
  if (!ok) return;

  const r = await api('/engines/' + engine.id + '/shadow-restore', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: f.file, onayla: true })
  });
  await watchJob(r.job, engine.name + ' yeni kopyaya hazırlanıyor…',
    'Yedek ayrı bir kopyaya yükleniyor; üretim çalışmaya devam ediyor. ' +
    'Geçiş, kopya doğrulandıktan sonra ve saniyeler içinde olur.');
  await refreshBackups(true);
  await refreshStatus();
}

/* Bilet: takas öncesine dönüş. Bu düğmenin varlığı, gölge yolunun asıl
   vaadi — klasik geri yüklemede dönülecek bir yer kalmaz. */
async function useTicket(engine, bilet) {
  const ok = await confirmBox(engine.name + ' takas öncesine dönsün mü?', `
    <p>${esc(engine.name)} <b>geçişten önceki veriye</b> döner.</p>
    <div class="plan-line"><span>Dönülecek kopya</span><b>${esc(bilet.old_volume)}</b></div>
    <div class="plan-line"><span>Geçişte yüklenen</span><b>${esc(bilet.file || '—')}</b></div>
    <div class="plan-line"><span>Geçiş zamanı</span><b>${esc(tamTarih(bilet.at))}</b></div>
    <p class="note">Kesinti yalnız container yeniden yaratılırken — saniyeler.</p>
    <p class="note">Geçişten <b>sonra</b> yazılan veriler o kopyada
       bulunmaz; geri dönmek onları geride bırakır.</p>`,
    'Geri dön');
  if (!ok) return;
  const r = await api('/engines/' + engine.id + '/rollback', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ onayla: true })
  });
  await watchJob(r.job, engine.name + ' takas öncesine dönüyor…',
    'Container önceki kopyayla yeniden yaratılıyor.');
  await refreshBackups(true);
  await refreshStatus();
}


/* KURTARMA NOKTASI SETLERİ
   Bir uygulama çoğu zaman tek veritabanı kullanmaz. Yedekler motor motor ve
   dakikalar arayla alındığı için "dün geceye dön" demek, elde birbirinden
   dakikalarca uzak birkaç an bırakır. Burada vaat edilen şey "hepsi aynı
   ana geldi" DEĞİL — ölçüm: pencerenin genişliği ve motor motor ne kadar
   geride kalındığı. Zamanda geri dönmesi açık olanlar hedefe tam oturur. */
function setSatiri(s) {
  const motorlar = Object.entries(s.engines || {});
  const eksik = motorlar.filter(([, k]) => !k.present).length;
  const rozet = motorlar.map(([eid, k]) => {
    const e = (CATALOG.engines || []).find((x) => x.id === eid) || { name: eid };
    if (!k.present) {
      return `<span class="set-eng is-yok" title="${esc(k.file || '')}"
        >${esc(e.name)} — dosya yok</span>`;
    }
    if (k.pitr === 'acik') {
      return `<span class="set-eng is-tam"
        title="Zamanda geri dönme açık: bu motor hedef ana tam oturur"
        >${esc(e.name)} — tam</span>`;
    }
    return `<span class="set-eng"
      title="${esc(k.file || '')} · hedefin ${k.behind_seconds} saniye öncesi"
      >${esc(e.name)} — ${k.behind_seconds} sn geride</span>`;
  }).join('');

  return `
    <li class="set-row">
      <div class="set-bas">
        <b>${esc(s.name || '')}</b>
        <span class="card-detail">${esc(tamTarih(s.finished))}</span>
        <span class="set-pencere"
          title="Setteki en eski ve en yeni dosya arasındaki fark. Sıfır değilse bu bir AN değil bir aralıktır."
          >pencere ${s.window_seconds} sn</span>
        ${eksik ? `<span class="bk-none">${eksik} dosya artık yok</span>` : ''}
      </div>
      <div class="set-engs">${rozet}</div>
      <div class="set-acts">
        <button class="btn btn-sm btn-danger" data-act="set-restore"
          data-set="${esc(s.id)}" ${eksik ? 'disabled' : ''}
          title="${eksik ? 'Setteki bazı dosyalar silinmiş; bu noktaya dönülemez'
                         : 'Setteki BÜTÜN motorları bu noktaya döndürür'}"
          >Bu noktaya dön</button>
      </div>
    </li>`;
}

function renderSets() {
  const zone = $('#bk-set-zone');
  const govde = $('#bk-sets');
  if (!zone || !govde) return;
  const setler = (BACKUPS && BACKUPS.recovery_sets) || [];
  zone.hidden = false;
  const yedeklenebilir = (CATALOG.engines || [])
    .filter((e) => ((BACKUPS.engines || {})[e.id] || {}).supported);
  govde.innerHTML = `
    <div class="set-yeni">
      <button class="btn" data-act="set-new"
        ${yedeklenebilir.length ? '' : 'disabled'}
        >Yeni kurtarma noktası al</button>
      <span class="card-detail">Seçtiğiniz motorların yedeği tek tur olarak alınır.</span>
    </div>
    ${setler.length
      ? `<ul class="set-list">${setler.map(setSatiri).join('')}</ul>`
      : '<p class="card-detail">Henüz kurtarma noktası alınmadı.</p>'}`;
}

async function yeniSet() {
  const secilebilir = (CATALOG.engines || [])
    .filter((e) => ((BACKUPS.engines || {})[e.id] || {}).supported);
  const kutular = secilebilir.map((e) => `
    <label class="set-sec">
      <input type="checkbox" class="set-eng-cb" value="${esc(e.id)}" checked>
      <span>${esc(e.icon || '')} ${esc(e.name)}</span>
      <span class="card-detail">${((BACKUPS.engines || {})[e.id] || {}).drill
        ? '' : ''}</span>
    </label>`).join('');
  const ok = await confirmBox('Yeni kurtarma noktası', `
    <p>Seçilen motorların yedeği <b>tek tur</b> olarak alınır ve tek bir
       kurtarma noktası olarak kaydedilir.</p>
    <p class="note">Tur SIRAYLA koşar; iki ağır yedeği aynı anda çalıştırmak
       aynı sunucuda belleği iki kez zorlar. Bu yüzden nokta bir AN değil bir
       PENCEREDİR — genişliği listede yazacak.</p>
    <div class="set-secim">${kutular}</div>`, 'Kurtarma noktası al');
  if (!ok) return;
  const secili = Array.from(document.querySelectorAll('.set-eng-cb'))
    .filter((c) => c.checked).map((c) => c.value);
  if (!secili.length) {
    infoBox('Motor seçilmedi', '<p>Kurtarma noktası için en az bir motor seçin.</p>');
    return;
  }
  const r = await api('/recovery-set', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ engines: secili })
  });
  await watchJob(r.job, 'Kurtarma noktası alınıyor…',
    'Seçilen motorların yedeği sırayla alınıyor; pencere sonunda ölçülüp yazılacak.');
  await refreshBackups(true);
}

async function setGeriYukle(sid) {
  const s = ((BACKUPS && BACKUPS.recovery_sets) || []).find((x) => x.id === sid);
  if (!s) {
    infoBox('Kurtarma noktası yok', '<p>Bu nokta listede artık yok. Sayfayı tazeleyin.</p>');
    return;
  }
  const satir = Object.entries(s.engines || {}).map(([eid, k]) => {
    const e = (CATALOG.engines || []).find((x) => x.id === eid) || { name: eid };
    const ne = k.pitr === 'acik'
      ? 'hedef ana tam oturur'
      : k.behind_seconds + ' sn geride kalır';
    return `<div class="plan-line"><span>${esc(e.name)}</span><b>${esc(ne)}</b></div>`;
  }).join('');
  const ok = await confirmBox('Bu noktaya dönülsün mü?', `
    <p><b>Setteki bütün motorların şu anki verileri SİLİNİR</b> ve bu
       noktadaki hâllerine döner.</p>
    <div class="plan-line"><span>Nokta</span><b>${esc(s.name || '')}</b></div>
    <div class="plan-line"><span>Zaman</span><b>${esc(tamTarih(s.finished))}</b></div>
    <div class="plan-line"><span>Pencere</span><b>${s.window_seconds} sn</b></div>
    ${satir}
    <p class="note">Varsayılan olarak her motor <b>kendi yedek dosyasından</b>
       geri yüklenir ve yukarıda yazan kadar geride kalır.</p>
    <label class="set-sec">
      <input type="checkbox" id="ileri-sar-cb">
      <span>Zamanda geri dönmeyi kullan — hedef ana tam otur</span>
    </label>
    <p class="note">Bu seçenek arşivdeki kayıtlarla hedefe ileri sarar.
       Ölçülen risk: PostgreSQL'de kümeyi açılamaz hâlde bırakabiliyor —
       küme daha önce bir dosyadan kurulduysa arşiv o soya ait değildir.
       Kapalı bırakırsanız geri yükleme dosyadan yapılır ve bu risk yoktur.</p>
    <p class="note">Onaylamak için noktanın adını yazın:
       <b>${esc(s.name || '')}</b></p>
    <div class="bk-onay">
      <input id="onay-inp" class="bk-onay-inp" type="text" autocomplete="off"
             spellcheck="false" aria-label="Onay için nokta adını yazın">
    </div>`, 'Bu noktaya dön', s.name || '');
  /* Pencere kapanınca yalnız GİZLENİYOR, içeriği duruyor — kutunun değeri
     bu yüzden onaydan sonra hâlâ okunabiliyor. Bir sonraki pencere açılınca
     içerik değişir, o yüzden okuma burada, hemen yapılıyor. */
  const ileriSar = !!(document.getElementById('ileri-sar-cb') || {}).checked;
  if (!ok) return;
  const r = await api('/recovery-set/restore', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ set: sid, onayla: true, ileri_sar: ileriSar })
  });
  await watchJob(r.job, 'Kurtarma noktasına dönülüyor…',
    'Her motor sırayla geri yükleniyor; sonunda hangisinin hedefe tam oturduğu yazılacak.');
  await refreshBackups(true);
  await refreshStatus();
}


async function restoreEngine(engine, f) {
  const ok = await confirmBox(engine.name + ' geri yüklensin mi?', `
    <p><b>${esc(engine.name)} içindeki şu anki veriler SİLİNİR</b> ve
       veritabanı aşağıdaki yedekteki hâline döner; işlem sırasında motor
       kısa süre erişilemez.</p>
    <div class="plan-line"><span>Dönülecek dosya</span><b>${esc(f.file)}</b></div>
    <div class="plan-line"><span>Yedeğin tarihi</span><b>${esc(tamTarih(f.epoch))}</b></div>
    <div class="plan-line"><span>Yedeğin yaşı</span><b>${esc(bagilZaman(f.epoch))}</b></div>
    <div class="plan-line"><span>Dosya boyutu</span><b>${esc(bayt(f.bytes))}</b></div>
    <p class="note">Bu tarihten <b>sonra</b> yazılan her şey kaybolur ve geri
       alınamaz. Elinizde daha yeni bir kopya olsun istiyorsanız önce
       “Yedek al” deyip sonra buraya dönün.</p>
    <p class="note">Onaylamak için motorun adını yazın:
       <b>${esc(engine.name)}</b></p>
    <div class="bk-onay">
      <input id="onay-inp" class="bk-onay-inp" type="text" autocomplete="off"
             spellcheck="false" placeholder="${esc(engine.name)}"
             aria-label="Onay için motor adını yazın">
    </div>`,
    'Geri Yükle', engine.name);
  if (!ok) return;

  const r = await api('/engines/' + engine.id + '/restore', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: f.file })
  });
  await watchJob(r.job, engine.name + ' geri yükleniyor…',
    'Veri yerine konuyor. Motor bu sırada kısa süre yanıt vermeyebilir; ' +
    'pencereyi kapatsanız da iş sunucuda devam eder.');
  // İş bitti: dosya listesi ve motorun durumu tazelensin. Geri yükleme yeni
  // dosya üretmez ama motor kısa süre kapanıp açılmış olabilir.
  await refreshBackups(true);
  await refreshStatus();
}

/* ------------------------------------------------- yeniden dengeleme */

/* Üst bar bu sayfada da duruyor, dolayısıyla aşırı taahhüt uyarısı da burada
   çıkabiliyor; düğmenin yalnız panelde çalışması, uyarıyı burada okuyan
   kullanıcıyı çıkışsız bırakırdı. Gövde app.js'teki ikizi ile aynı sözü
   veriyor: CONTAINER YENİDEN BAŞLATILMAZ, docker update cgroup sınırını
   canlı değiştirir. */
async function rebalance() {
  const m = bellekModeli(STATUS.system || {});
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
  /* watchJob bu dosyada kendiliğinden tazelemiyor (app.js'teki ikizi
     tazeliyor). Yeni sınırlar üst barda görünsün diye durumu biz istiyoruz. */
  await refreshStatus();
}

/* ================================================================== çizim */

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
  const sys = STATUS.system || {};
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

/* ------------------------------------------------------ zamanlama kutusu */

/* ERTELENMİŞ TUR, BAŞARISIZ TUR DEĞİLDİR.
   Ekranda “Son yedek: 6 saat önce · BAŞARISIZ — başka bir işlem kilidi
   tutuyor” yazıyordu ve kırmızıydı; oysa olan şey şuydu: tam o dakikada
   başka bir yedekleme (ya da geri yükleme) sürüyordu, tur hiç koşmadı ve
   yeniden denenecek. Kırmızı, kullanıcıyı olmayan bir arızanın peşine
   düşürüyordu.

   Alan controller/app.py'de schedule.last_deferred ve ertelemenin OLDUĞU
   ANI (epoch) taşıyor. Tek başına bakmak yeterli: yeni bir tur başlarken
   controller onu None'a çekiyor, erteleme anında da last_run önceki turun
   zamanına GERİ ALINIYOR (tur koşmuş sayılmıyor). Yani alan doluysa en son
   olan şey bir ertelemedir. */
function ertelenmisMi(s) {
  return typeof s.last_deferred === 'number' && s.last_deferred > 0;
}

function schedHtml(s) {
  const acik = !!s.enabled;
  const saat = /^\d{1,2}:\d{2}$/.test(s.time || '') ? s.time : '02:00';
  const gun  = s.retention_days > 0 ? Math.round(s.retention_days) : 7;

  const durum = acik
    ? 'Otomatik yedek: <b>AÇIK</b> — her gün ' + esc(saat)
    : 'Otomatik yedek: <b>KAPALI</b>';
  const calisiyor = s.running ? ' <span class="badge busy">Yedek alınıyor</span>' : '';

  /* “KAPALI” tek başına bir ayarın durumu gibi okunuyor; oysa söylediği şey
     bir risk. Sessizce kapalı kalmasın diye sonucunu da yazıyoruz. */
  const kapaliNot = acik ? ''
    : `<p class="bk-warn">Hiçbir yedek alınmıyor — bugün silinen ya da bozulan
         bir veriyi geri getirebileceğiniz kopya oluşmuyor.</p>`;

  const ertelendi = ertelenmisMi(s);

  let son;
  if (!s.last_run) {
    son = '<p class="bk-last bk-muted">Henüz hiç yedek alınmadı.</p>';
  } else if (s.last_ok === false) {
    // Sayfadaki kırmızı bir şey gerçekten sorun demek: başarısız yedek,
    // "yedeğim var" sanan kullanıcının en pahalı yanılgısıdır. Sebebi de
    // burada duruyor; kullanıcıyı log dosyasına göndermiyoruz.
    son = `<p class="bk-last bk-err" title="${esc(tamTarih(s.last_run))}">
             Son otomatik yedek: ${esc(bagilZaman(s.last_run))} · <b>BAŞARISIZ</b>${
             s.last_error ? ' — ' + esc(s.last_error) : ''}</p>`;
  } else if (s.last_ok === true) {
    son = `<p class="bk-last" title="${esc(tamTarih(s.last_run))}">
             Son otomatik yedek: ${esc(bagilZaman(s.last_run))} · başarılı</p>`;
  } else if (ertelendi) {
    /* Erteleme, önceki turun sonuç damgasını da sıfırlıyor (controller
       last_ok'u None'a çekiyor). Burada “sonucu bilinmiyor” yazmak,
       ertelemenin yan etkisini bir arıza gibi göstermek olurdu: tarihi
       veriyoruz, uydurma bir yargı vermiyoruz. */
    son = `<p class="bk-last bk-muted" title="${esc(tamTarih(s.last_run))}">
             Koşan son tur: ${esc(bagilZaman(s.last_run))}.</p>`;
  } else {
    son = `<p class="bk-last bk-muted" title="${esc(tamTarih(s.last_run))}">
             Son otomatik yedek: ${esc(bagilZaman(s.last_run))} · sonucu bilinmiyor</p>`;
  }

  /* Ertelemenin zamanı last_run DEĞİL last_deferred'dir: erteleme anında
     last_run geri alındığı için “son deneme” diye last_run'ı yazsaydık
     ekranda düne ait bir saat görünürdü. */
  const erteNot = ertelendi
    ? `<p class="bk-last bk-defer" title="${esc(tamTarih(s.last_deferred))}">
         Zamanlanmış tur ${esc(bagilZaman(s.last_deferred))}
         <b>ertelendi, tekrar denenecek</b> — o sırada başka bir yedekleme ya
         da geri yükleme sürüyordu. İki ağır iş aynı anda koşarsa aynı
         container'ın belleğini iki kez zorlar; kilit sırayı koruyor ve tur
         koşmuş sayılmıyor.</p>` : '';

  /* SIRADAKİ *DENEME*, "24 saat sonra" DEĞİL.

     ÖLÇÜLEN OLAY: son tur kilide takılmıştı ve zamanlayıcı 10 dakika sonra
     yeniden deneyecekti; kutu ise next_run'ı okuyup "Sıradaki yedek: 24 saat
     sonra" yazıyordu. Kullanıcı o günün yedeğinden umudu kesip elle yedek
     alıyordu — oysa sistem zaten deneyecekti.

     next_attempt bir sonraki DENEMEyi verir (ertelemeden sonraki kısa
     tekrar, normalde gecelik saat), attempt_note da sebebini. Alan yoksa
     (bu alanları göndermeyen eski controller) eski next_run'a düşülür:
     yanlış olmayan, yalnız daha az bilgi veren bir cevap. */
  const deneme = s.next_attempt != null ? s.next_attempt : s.next_run;
  const not    = s.attempt_note || '';
  /* Deneme normal gecelik saatten FARKLIYSA bu bir tekrardır; başlığı da
     öyle yazıyoruz. Aynıysa "Sıradaki yedek" doğru kelimedir — her turu
     "deneme" diye adlandırmak, olağan gecelik yedeği tedirgin edici
     gösterirdi. */
  const tekrar = s.next_attempt != null && s.next_run != null
              && s.next_attempt !== s.next_run;
  /* Kilit çakışması KIRMIZI DEĞİL: arıza değil, sıra bekleme. .bk-retry
     .bk-defer ile aynı sarı tonu kullanıyor (bkz. style.css 16. bölüm). */
  const sira = (acik && deneme && !s.running)
    ? `<p class="bk-next${tekrar || not ? ' bk-retry' : ''}"
          title="${esc(tamTarih(deneme))}">${
          tekrar || not ? 'Sıradaki deneme' : 'Sıradaki yedek'}:
         ${esc(bagilZaman(deneme))}${not ? ' — ' + esc(not) : ''}</p>`
    : '';

  return `
  <div class="bk-sched${acik ? '' : ' is-off'}">
    <div class="bk-sched-txt">
      <p class="bk-state">${durum}${calisiyor}</p>
      ${son}${erteNot}${sira}${kapaliNot}
    </div>
    <div class="bk-ctrl">
      <label class="bk-field"><span>Saat</span>
        <input class="bk-inp" type="time" step="60" data-bk="time"
               value="${esc(saat)}" aria-label="Günlük yedek saati"></label>
      <label class="bk-field"><span>Saklama</span>
        <input class="bk-inp bk-inp-num" type="number" min="1" max="365" step="1"
               data-bk="keep" value="${gun}"
               aria-label="Yedeklerin saklanacağı gün sayısı">
        <span class="bk-unit">gün</span></label>
      <button class="btn${acik ? '' : ' btn-open'}"
              data-act="${acik ? 'bk-off' : 'bk-on'}">${acik ? 'Kapat' : 'Aç'}</button>
    </div>
  </div>
  <p class="bk-hint">Saklama süresinden eski yedekler temizlik turunda silinir.
     Her motorun en yeni birkaç kopyası, yaşı ne olursa olsun korunur — kapalı
     kalmış bir motor son kurtarma noktasını da kaybetmesin diye.</p>`;
}

/* ------------------------------------------------------------ motor satırı */

/* KAYNAK etiketi dosya adından TAHMİN EDİLMİYOR: controller kendi başlattığı
   koşumdan sonra oluşan dosyaları deftere yazıyor, deftere girmemiş dosya
   “dış”tır (host cron'u ya da komut satırı). Tahmin etseydik, elle alınmış
   bir yedek “dün gece tur koştu” diye okunabilirdi. */
const KAYNAK_AD  = { 'elle': 'elle', 'zamanlı': 'zamanlı', 'dış': 'dış' };
const KAYNAK_CLS = { 'elle': 'man', 'zamanlı': 'auto' };

/* Satır bir GRID: ikon · ad · bilgiler · düğmeler, dosya listesi ise tam
   genişlikte ALT SATIR. Panelde satır flex'ti ve tam genişlik isteyen dosya
   listesi düğmenin yanına sıkışıyordu — ekranda “Yedek al” ile “Yedekleri
   göster” üst üste biniyordu. Sütunlar artık adlarıyla duruyor; iki öğenin
   aynı hücreye düşmesi mümkün değil (bkz. style.css, .bk-row). */
function rowHtml(engine, b, st, s) {
  const dosyalar = b.files || [];
  const kapali   = !st.active;
  const mesgul   = !!s.running;

  /* Controller “bu motor geri yüklenebilir mi”yi kendisi söylerse ona
     uyulur; söylemiyorsa yukarıdaki kopya listeye bakılır. */
  const geriOk = (b.restorable != null) ? !!b.restorable
    : ((engine.backup || {}).restorable != null
        ? !!engine.backup.restorable
        : GERI_YUKLENEBILIR.indexOf(engine.id) !== -1);

  /* O MOTORDA ŞU AN SÜREN İŞ. Kilit bayrağı (s.running) yalnız "bir yerde
     bir iş var" der; kullanıcının sorduğu soru "BENİM motorumda ne oluyor".
     Ölçülen olay: kullanıcı MariaDB satırında "Yedek al"a bastı, satır
     dakikalarca "en yeni 55 dakika önce" yazmaya devam etti, sonra listeye
     ZAMANLI bir yedek düştü. Panel o süre boyunca hiçbir şey söylemediği
     için haklı olarak "çalışmadı" sanıldı. Sessiz kalmak da bir cevaptır ve
     yanlış olanıdır. */
  const surenler = Array.isArray(b.calisiyor) ? b.calisiyor : [];
  const IS_ADI = { backup: 'yedek alınıyor', restore: 'geri yükleniyor',
                   drill: 'kurtarma provası sürüyor' };

  const facts = [];
  if (surenler.length) {
    /* Sayılardan ÖNCE geliyor: satırın en taze gerçeği bu. Altındaki
       "en yeni 55 dakika önce" yazısı hâlâ doğru ama artık yanıltmıyor,
       çünkü yanında işin sürdüğü yazıyor. */
    facts.push('<span class="badge busy">'
      + esc(IS_ADI[surenler[0]] || surenler[0] + ' sürüyor') + '…</span>');
  }
  if (!b.latest) {
    // Bu satırın en önemli bilgisi bu: yedeksiz bir veritabanı, boyut ve
    // adet sütunları boş kaldığı için eskiden gözden kaçıyordu.
    facts.push('<span class="bk-none">hiç yedek yok</span>');
  } else {
    facts.push('<span>' + (b.count || 0) + ' yedek</span>');
    facts.push('<span>' + esc(bayt(b.total_bytes)) + '</span>');
    facts.push(`<span title="${esc(b.latest.file || '')} · ${esc(tamTarih(b.latest.epoch))}"
                  >en yeni ${esc(bagilZaman(b.latest.epoch))}</span>`);
  }
  if (kapali) facts.push('<span class="bk-muted">motor kapalı</span>');

  /* Kapalı motorun yedeği ALINAMAZ, geri de YÜKLENEMEZ: dump araçları da
     yükleme araçları da çalışan container'a `docker exec` ile giriyor.
     Düğmeyi tıklanır bırakmak, kullanıcıya bir iş başlatıp saniyesinde hata
     penceresi göstermekten başka işe yaramıyordu. */
  const bkNot = kapali ? 'Motor kapalı — yedek almak için önce açın'
              : surenler.length ? 'Bu motorda bir iş sürüyor, bitmesini bekleyin'
              : mesgul ? 'Şu an başka bir motorda yedek alınıyor' : '';
  const grNot = !geriOk
      ? 'Bu motorda panelden geri yükleme yok; docs/BACKUP.md anlatıyor'
      : kapali ? 'Motor kapalı — geri yüklemek için önce açın'
      : mesgul ? 'Şu an bir yedekleme sürüyor, bitmesini bekleyin' : '';
  const grKapali = !geriOk || kapali || mesgul;

  /* “Son yedeğe dön” yalnız dönülecek bir dosya varken çıkar. Yedeksiz bir
     motorda sönük de olsa bir geri yükleme düğmesi göstermek, olmayan bir
     kurtarma noktası vaat etmek olurdu. */
  /* KURTARMA PROVASI. Bir yedeğin tek dürüst güvencesi, geri yüklendiğinin
     GÖRÜLMÜŞ olmasıdır. Burada üç durum var ve üçü de farklı şey söyler:
       geçti      → "bu yedek N saniyede gerçekten geri yüklendi"
       kaldı      → elde geri YÜKLENEMEYEN bir yedek var; felaket gününden
                    önce öğrenmenin tek yolu buydu
       hiç yapılmadı → yedeğiniz var ama geri yüklenip yüklenmeyeceği
                    BİLİNMİYOR. Bunu sessizce boş bırakmak, kullanıcıya
                    olmayan bir güvence hissettirirdi. */
  const pr = b.drill;
  let provaRozet = '';
  if (b.drill_supported === false) {
    provaRozet = '';
  } else if (!pr) {
    provaRozet = b.latest
      ? '<span class="bk-drill bk-drill-yok">prova yapılmadı</span>' : '';
  } else if (pr.ok === true) {
    provaRozet = `<span class="bk-drill bk-drill-ok"
      title="${esc(tamTarih(pr.at))} · ${esc(pr.detail || '')}"
      >prova geçti ${esc(bagilZaman(pr.at))}${
        /* Birim KAYNAKTA çevriliyor: bu metin 'prova geçti {1}{2}'
           kalıbının ikinci deliğine düşüyor ve iki delik yan yana
           olduğu için hangi parçanın nereye ait olduğu belirsiz —
           kalıp eşleşse bile 'sn' Türkçe kalıyordu. */
        pr.seconds != null ? ' · ' + esc(pr.seconds) + ' ' + T('sn') : ''}</span>`;
  } else if (pr.ok === false) {
    provaRozet = `<span class="bk-drill bk-drill-err"
      title="${esc(tamTarih(pr.at))} · ${esc(pr.detail || '')}"
      >PROVA KALDI ${esc(bagilZaman(pr.at))}</span>`;
  } else {
    provaRozet = `<span class="bk-drill bk-drill-yok"
      title="${esc(pr.detail || '')}">prova ölçülemedi</span>`;
  }

  const provaBtn = (b.drill_supported !== false && b.latest)
    ? `<button class="btn btn-sm" data-act="drill" data-id="${esc(engine.id)}"
         title="Yedeği tek kullanımlık bir kopyada geri yükler; üretime dokunmaz"
         aria-label="${esc(engine.name)} yedeğinin kurtarma provasını yap"
         >Prova yap</button>` : '';

  /* SEBEBİ SATIRDA YAZ. Sönük bir düğme + baloncuk, "geri yükleyebilir
     miyim?" sorusunu cevapsız bırakıyordu; kullanıcı düğmeyi sönük görüp
     bunun geçici bir durum mu yoksa kalıcı bir sınır mı olduğunu
     anlayamıyordu. Diğer durumlar (prova geçti, hiç yedek yok) zaten
     satırda yazılı — bu da yazılmalı. */
  const geriRozet = !geriOk
    ? `<span class="bk-drill bk-drill-yok" title="${esc(grNot)}"
         >panelden geri yükleme yok — elle: docs/BACKUP.md</span>`
    : '';
  /* Yedeği hiç alınamayan motorun SEBEBİ. Neo4j Community'de çevrimiçi yedek
     yok; sebep yalnız yedekleme günlüğünde kalıyordu ve panelde motor
     sessizce yedeksiz görünüyordu. */
  const kesintiRozet = (!b.latest && (engine.backup || {}).requires_downtime)
    ? `<span class="bk-drill bk-drill-yok"
         >otomatik yedek yok — bu motorda yedek almak veritabanını durdurur</span>`
    : '';

  const sonBtn = b.latest
    ? `<button class="btn btn-sm btn-danger" data-act="restore-last"
         data-id="${esc(engine.id)}"${grKapali ? ' disabled' : ''}${
         grNot ? ' title="' + esc(grNot) + '"' : ''}
         aria-label="${esc(engine.name)} veritabanını son yedeğe döndür"
         >Son yedeğe dön</button>` : '';

  /* DOSYA LİSTESİ. Özet satırı “3 yedek” diyor ama hangi tarihlerde ve
     hangisi elle alınmış — bunu görmeden “dün gece yedek alındı mı”
     sorusuna cevap veremiyorsunuz. Her satırın kendi geri yükleme düğmesi
     var: “son yedek” her zaman istenen yedek değildir — veriyi bozan işlem
     dün öğlen olmuşsa dönülecek yer ondan ÖNCEKİ kopyadır. */
  const liste = dosyalar.length
    ? `<details class="bk-files" data-key="bk:${esc(engine.id)}:files">
         <summary class="sum"><span class="chev" aria-hidden="true"></span>
           Yedekleri göster${b.count > dosyalar.length
             ? ` (son ${dosyalar.length} / ${b.count})` : ''}</summary>
         <ul class="bk-flist">
           ${dosyalar.map((f) => `
           <li class="bk-file">
             <span class="bk-file-when" title="${esc(tamTarih(f.epoch))}"
               >${esc(bagilZaman(f.epoch))}</span>
             <span class="bk-file-kind bk-kind-${esc(KAYNAK_CLS[f.kind] || 'dis')}"
               >${esc(KAYNAK_AD[f.kind] || f.kind || '?')}</span>
             <span class="bk-file-name" title="${esc(f.file)}">${esc(f.file)}${
               f.readable === false
                 ? `<span class="bk-acilmaz" title="${esc(ACILMAZ)}">açılamaz</span>`
                 : ''}</span>
             <span class="bk-file-size">${esc(bayt(f.bytes))}${
               f.schema ? `<span class="bk-sema" title="${esc(SEMA_BALON(f.schema))}"
                 >şema ${esc(f.schema.short)}${f.schema.stable === false ? ' ?' : ''}</span>` : ''}</span>
             <button class="btn btn-sm bk-file-btn" data-act="inspect"
               data-id="${esc(engine.id)}" data-file="${esc(f.file)}"
               ${f.readable === false ? 'disabled' : ''}
               aria-label="${esc(f.file)} yedeğinin içindekileri göster"
               title="${f.readable === false ? esc(ACILMAZ) : 'Yedeği GERİ YÜKLEMEDEN içindeki tabloları göster'}"
               >İçini gör</button>
             ${b.shadow_supported ? `<button class="btn btn-sm bk-file-btn"
               data-act="shadow" data-id="${esc(engine.id)}" data-file="${esc(f.file)}"
               ${grKapali || f.readable === false ? 'disabled' : ''}${
                 f.readable === false ? ' title="' + esc(ACILMAZ) + '"'
                                      : (grNot ? ' title="' + esc(grNot) + '"' : '')}
               title="Üretim çalışırken yeni bir kopyaya yükler; geçiş saniyeler sürer ve 24 saat geri dönülebilir"
               >Kesintisiz dön</button>` : ''}
             <button class="btn btn-sm bk-file-btn" data-act="restore"
               data-id="${esc(engine.id)}" data-file="${esc(f.file)}"
               ${grKapali || f.readable === false ? 'disabled' : ''}${
                 f.readable === false ? ' title="' + esc(ACILMAZ) + '"'
                                      : (grNot ? ' title="' + esc(grNot) + '"' : '')}
               aria-label="${esc(engine.name)} veritabanını ${esc(f.file)} yedeğine döndür"
               >Bu yedeğe dön</button>
           </li>`).join('')}
         </ul>
       </details>`
    : '';

  /* Elle başlatılan son denemenin sonucu, iş penceresi kapandıktan sonra da
     burada durur. Yoksa ekranda hiçbir iz kalmıyor ve kullanıcı "hata
     vermedi ama yedek de alınmamış" durumunda kalıyordu. */
  /* KURTARMA NOKTASI SAYISI YANILTMASIN: şifreli ama anahtarsız bir dosya
     listede duruyor, yer kaplıyor ve "yedeğim var" duygusu veriyor — ama
     geri yüklenemez. Bunu dosya listesi KAPALIYKEN de söylüyoruz, çünkü
     kullanıcı listeyi ancak ihtiyaç duyduğunda açar ve o an çok geçtir. */
  if (b.unreadable > 0) {
    facts.push(`<span class="bk-none"
      title="${esc(ACILMAZ)}">${b.unreadable} yedek açılamaz (şifreli, anahtar yok)</span>`);
  }

  /* AÇIK BİLET: kullanıcının 'geri dönebilirim' hakkı ve SÜRESİ. Süreyi
     yazmazsak kapı sessizce kapanır ve kimse fark etmez. */
  if (b.ticket) {
    const sa = Math.max(1, Math.round(b.ticket.remaining_seconds / 3600));
    facts.push(`<span class="bk-ticket"
      title="Geçişte yüklenen: ${esc(b.ticket.file || '—')} · önceki kopya: ${esc(b.ticket.old_volume)}"
      >geri dönüş bileti açık — ${sa} saat kaldı</span>`);
  }
  /* İŞARETÇİ İLE GERÇEK AYRIŞMASI: dosya bir kopyayı gösterirken container
     başkasını bağlamış olabilir (takas yarıda kalmışsa). Motor sağlıklı
     görünür ve kimse hata görmez; bu yüzden panelde söylüyoruz. 'Ölçemedik'
     ile 'ayrışma yok' ayrı iki cevap. */
  if (b.generation && b.generation.drift === true) {
    facts.push(`<span class="bk-none"
      title="volumes.env ${esc(b.generation.intent || '?')} diyor, container ${esc(b.generation.live || '?')} bağlamış">
      kopya işaretçisi AYRIŞMIŞ</span>`);
  } else if (b.generation && b.generation.drift === null) {
    facts.push(`<span class="card-detail"
      title="Motor kapalıyken hangi kopyanın bağlı olduğu ölçülemez">
      kopya işaretçisi ölçülemedi</span>`);
  }

  const deneme = SON_DENEME[engine.id];
  const denemeNotu = deneme
    ? `<p class="bk-attempt ${deneme.tur === 'ertelendi' ? 'bk-attempt-wait'
                                                        : 'bk-attempt-err'}"
         >${deneme.tur === 'ertelendi' ? '⏳' : '⛔'} ${esc(deneme.metin)}</p>`
    : '';

  return `
  <li class="bk-row" id="bk-${esc(engine.id)}">
    <span class="bk-icon" aria-hidden="true">${esc(engine.icon)}</span>
    <span class="bk-name">${esc(engine.name)}</span>
    <span class="bk-facts">${facts.join('')}${provaRozet}${geriRozet}${kesintiRozet}${denemeNotu}</span>
    <span class="bk-acts">
      <button class="btn btn-sm" data-act="backup" data-id="${esc(engine.id)}"
        ${kapali || mesgul ? 'disabled' : ''}${bkNot ? ' title="' + esc(bkNot) + '"' : ''}
        aria-label="${esc(engine.name)} yedeğini şimdi al">Yedek al</button>
      ${b.ticket ? `<button class="btn btn-sm btn-danger" data-act="rollback"
        data-id="${esc(engine.id)}"
        title="Geçişten önceki kopyaya dön — kesinti saniyeler"
        >Takas öncesine dön</button>` : ''}
      ${provaBtn}
      ${sonBtn}
    </span>
    ${liste}
  </li>`;
}

/* ------------------------------------------------------------- render() */
/* Açık <details> ve odak, yeniden çizimde korunuyor: liste kendi turunda
   tazeleniyor ve kullanıcının açtığı dosya listesini kapatmak ya da basmak
   üzere olduğu düğmeyi ayağının altından çekmek kabul edilemez. */
function snapshot(kok) {
  const open = [];
  kok.querySelectorAll('details[data-key]').forEach((d) => {
    if (d.open) open.push(d.dataset.key);
  });
  const a = document.activeElement;
  let focus = null;
  if (a && kok.contains(a)) {
    if (a.dataset && a.dataset.act)
      focus = { act: a.dataset.act, id: a.dataset.id, file: a.dataset.file };
    else if (a.tagName === 'SUMMARY' && a.parentElement && a.parentElement.dataset.key)
      focus = { key: a.parentElement.dataset.key };
  }
  return { open: open, focus: focus };
}

function restoreFocus(kok, snap) {
  kok.querySelectorAll('details[data-key]').forEach((d) => {
    if (snap.open.indexOf(d.dataset.key) !== -1) d.open = true;
  });
  if (!snap.focus) return;
  let el = null;
  if (snap.focus.act) {
    kok.querySelectorAll('[data-act]').forEach((n) => {
      if (!el && n.dataset.act === snap.focus.act
          && n.dataset.id === snap.focus.id
          && (n.dataset.file || '') === (snap.focus.file || '')) el = n;
    });
  } else {
    kok.querySelectorAll('details[data-key]').forEach((d) => {
      if (!el && d.dataset.key === snap.focus.key) el = d.querySelector('summary');
    });
  }
  if (el) el.focus({ preventScroll: true });
}

let lastSchedHtml = '';
let lastListHtml  = '';

function render() {
  /* Kurtarma noktaları da her tazelemede yeniden çiziliyor: yeni alınan bir
     nokta ancak sayfa yenilenince görünseydi, kullanıcı işin bittiğini
     anlamazdı. */
  try { renderSets(); } catch (e) { /* setler çizilemezse liste yine çizilsin */ }
  renderSystem();
  if (!CATALOG) return;

  const yukleniyor = $('#bk-loading');
  const schedZone  = $('#bk-sched-zone');
  const listZone   = $('#bk-list-zone');

  if (!BACKUPS || !BACKUPS.schedule) {
    /* Panelde veri gelmeyince yedek bölümü sessizce kayboluyordu; BURADA
       susmak, boş bir ekranı “hiç yedeğiniz yok” diye okutmak olurdu. Ne
       bilmediğimizi ve bunun ne anlama GELMEDİĞİNİ söylüyoruz. */
    schedZone.hidden = true;
    listZone.hidden = true;
    if (yukleniyor) {
      yukleniyor.hidden = false;
      /* İlk istek daha yoldayken "alınamadı" demek erken ve yanlış olurdu:
         /api/status neredeyse her zaman /api/backups'tan önce dönüyor ve
         açılışta ekranda bir an o cümle parlıyordu. Önce sormuş olmak
         gerekiyor. */
      yukleniyor.textContent = bkDenendi
        ? ('Yedek bilgisi alınamadı — kontrol servisi kapalı olabilir. Bu, '
           + 'yedeklerinizin silindiği anlamına gelmez; dosyalar sunucudaki '
           + 'backups/ dizininde durur.')
        : 'Yükleniyor…';
    }
    return;
  }
  if (yukleniyor) yukleniyor.hidden = true;

  const s    = BACKUPS.schedule || {};
  const eng  = BACKUPS.engines || {};
  const byId = {};
  (STATUS.engines || []).forEach((e) => { byId[e.id] = e; });

  /* --- zamanlama --- */
  const sh = schedHtml(s);
  schedZone.hidden = false;
  if (sh !== lastSchedHtml) {
    /* Kullanıcı saat ya da gün kutusunun İÇİNDEYKEN yeniden yazmıyoruz: tur
       tam “0” yazılmışken gelip kutuyu sunucudaki değere döndürüyor, ikinci
       haneyi yazan kullanıcı kendi yazdığını kaybediyordu. */
    const ae = document.activeElement;
    if (!(ae && ae.tagName === 'INPUT' && schedZone.contains(ae))) {
      $('#bk-sched').innerHTML = sh;
      lastSchedHtml = sh;
    }
  }

  /* --- motor listesi ---
     Yalnız katalogda backup.supported olan motorlar. Kafka gibi yedeği
     TANIMSIZ olan kayıtlar listeye girseydi her satırında ömür boyu “hiç
     yedek yok” yazacaktı; gerçekten yedeksiz kalmış bir veritabanı da o
     gürültünün içinde kaybolacaktı. */
  const list  = (CATALOG.engines || []).filter((e) => (e.backup || {}).supported);
  const eksik = list.filter((e) => !(eng[e.id] || {}).latest).length;

  const head = '<h2 class="zone-title" id="bk-list-title">Motorlar</h2>'
    + `<span class="zone-count">${list.length}</span>`
    + (eksik
        ? `<p class="zone-note zone-note-err">${eksik} motorun hiç yedeği yok.</p>`
        : '<p class="zone-note">Her motorun diskteki yedek dosyaları.</p>');
  const hEl = $('#bk-list-head');
  if (hEl && hEl.innerHTML !== head) hEl.innerHTML = head;

  const lh = list.map((e) => rowHtml(e, eng[e.id] || {}, byId[e.id] || {}, s)).join('');
  listZone.hidden = false;
  if (lh !== lastListHtml) {
    const kok = $('#bk-list');
    const snap = snapshot(kok);
    kok.innerHTML = lh;
    lastListHtml = lh;
    restoreFocus(kok, snap);
  }
}

/* ------------------------------------------------------------------ döngü */

/* Motorun açık olup olmadığı düğmeleri belirliyor ve o bilgi çabuk eskiyor:
   başka bir sekmede motoru açan kullanıcı burada sönük bir düğmeye bakmasın.
   /api/status ucuz — dosya saymıyor, docker'a soruyor. */
const ST_ARALIK = 5000;

async function refreshStatus() {
  try {
    STATUS = await api('/status');
    $('#banner').hidden = true;
  } catch (e) {
    $('#banner').textContent = 'Kontrol servisine ulaşılamıyor: ' + e.message;
    $('#banner').hidden = false;
  }
  render();
}

/* Yedek listesi 5 saniyelik tura GİRMİYOR: yanıtı üretmek yedek klasörünü
   gezip dosya saymayı gerektiriyor ve sunucu boştayken bile diski sürekli
   uyandırmanın anlamı yok — yedekler dakikalarca değişmez. Tek istisna, yedek
   ALINIRKEN: orada 30 saniye beklemek “Yedek alınıyor” rozetini ve kilitli
   düğmeleri iş bittikten sonra yarım dakika daha ekranda tutuyordu. */
const BK_ARALIK        = 30000;
const BK_ARALIK_MESGUL = 8000;
let bkSon   = 0;
let bkIstek = null;
let bkDenendi = false;   // uca EN AZ BİR KEZ soruldu mu (bkz. render)

function refreshBackups(zorla) {
  // Uçuşta bir istek varken ikincisini açmıyoruz; “zorla” diyen (düğmeye
  // basmış) çağrı ise eski yanıtla yetinmesin diye sıraya giriyor.
  if (bkIstek) return zorla ? bkIstek.then(() => refreshBackups(true)) : bkIstek;

  const mesgul = !!(BACKUPS && BACKUPS.schedule && BACKUPS.schedule.running);
  if (!zorla && Date.now() - bkSon < (mesgul ? BK_ARALIK_MESGUL : BK_ARALIK)) {
    return Promise.resolve();
  }

  bkIstek = api('/backups').then(
    (d) => { BACKUPS = d; },
    () => { BACKUPS = null; }
  ).then(() => {
    bkSon = Date.now();
    bkIstek = null;
    bkDenendi = true;
    render();
  });
  return bkIstek;
}

/* ------------------------------------------------------------------- tema */
/* Üç durum, iki değil: sistem → açık → koyu → sistem. index.html ile AYNI
   anahtar (dbstack-theme) kullanılıyor; iki sayfa arasında gezerken temanın
   değişmesi, kullanıcıya başka bir ürüne girmiş hissi verirdi. */
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

/* -------------------------------------------------------------- olaylar */

/* Dosya adından dosya kaydını buluyoruz: düğme yalnız adı taşıyabilir, tarih
   ve boyut ise onay penceresinde gösterilmek zorunda — “hangi yedeğe
   döndüğünü bilmeden onayla” diye bir şey olamaz. */
function dosyaBul(eid, ad) {
  const b = (BACKUPS && BACKUPS.engines && BACKUPS.engines[eid]) || {};
  return (b.files || []).find((f) => f.file === ad) || null;
}

document.addEventListener('click', (ev) => {
  const b = ev.target.closest('[data-act]');
  if (!b || b.disabled) return;
  const engine = CATALOG
    ? CATALOG.engines.find((e) => e.id === b.dataset.id) : null;
  let p;
  switch (b.dataset.act) {
    case 'backup': p = takeBackup(engine); break;
    case 'inspect': p = inspectBackup(engine, b.dataset.file); break;
    case 'inspect-raw':
      p = inspectRaw(engine, b.dataset.file, parseInt(b.dataset.kb, 10) || 50);
      break;
    case 'drill':  p = runDrill(engine); break;
    case 'bk-on':  p = toggleSchedule(true); break;
    // Motora bağlı değil: dataset.id yok, engine null kalır.
    case 'rebalance': p = rebalance(); break;
    case 'bk-off': p = toggleSchedule(false); break;
    case 'restore-last': {
      const bk = ((BACKUPS && BACKUPS.engines) || {})[engine.id] || {};
      /* Ekrandaki liste eskimiş olabilir: kullanıcı düğmeye bastığı anda
         temizlik turu o dosyayı silmiş olabilir. Kayıt yoksa iş
         başlatmıyoruz — onay penceresinde tarih yerine boşluk göstermek,
         onayın kendisini anlamsız kılardı. */
      if (!bk.latest) {
        infoBox('Dönülecek yedek yok', '<p>Bu motorun listede bir yedeği '
          + 'görünmüyor. Sayfayı tazeleyip tekrar bakın.</p>');
        return;
      }
      p = restoreEngine(engine, bk.latest);
      break;
    }
    case 'restore': {
      const f = dosyaBul(engine.id, b.dataset.file);
      if (!f) {
        infoBox('Yedek bulunamadı', '<p>Bu dosya listede artık yok — saklama '
          + 'temizliği silmiş olabilir. Sayfayı tazeleyin.</p>');
        return;
      }
      p = restoreEngine(engine, f);
      break;
    }
    case 'shadow': {
      const f = dosyaBul(engine.id, b.dataset.file);
      if (!f) {
        infoBox('Yedek bulunamadı', '<p>Bu dosya listede artık yok — saklama '
          + 'temizliği silmiş olabilir. Sayfayı tazeleyin.</p>');
        return;
      }
      p = shadowRestore(engine, f);
      break;
    }
    case 'set-new': p = yeniSet(); break;
    case 'set-restore': p = setGeriYukle(b.dataset.set); break;
    case 'rollback': {
      const bk = ((BACKUPS && BACKUPS.engines) || {})[engine.id] || {};
      if (!bk.ticket) {
        infoBox('Geri dönüş bileti yok', '<p>Bu motorda dönülecek bir '
          + 'kopya kayıtlı değil. Sayfayı tazeleyip tekrar bakın.</p>');
        return;
      }
      p = useTicket(engine, bk.ticket);
      break;
    }
  }
  /* Hata BURADA yakalanır: düğmeye basınca çalışan işlevlerin tek çağrı yeri
     burası ve dinleyici async değil. Dallar promise'i yakalamadan bıraksaydı
     api()'nin 403/503/504'te fırlattığı hata sessiz bir promise reddine
     dönüşür, onay penceresi kapanır ve ekranda HİÇBİR ŞEY olmazdı — gateway
     tam da bu durum için yazdığı düz metinleri kullanıcıya hiç
     ulaştıramıyordu. */
  if (p) p.catch((e) => infoBox('İşlem yapılamadı', '<p>' + esc(e.message) + '</p>'));
});

/* Saat ve saklama alanları 'change' ile kaydediliyor, 'input' ile DEĞİL: her
   tuş vuruşunda POST atmak, “03:00” yazan kullanıcının ayarını yol boyunca
   “00:00”a düşürüyordu. */
document.addEventListener('change', (ev) => {
  const el = ev.target.closest ? ev.target.closest('[data-bk]') : null;
  if (!el) return;
  const s = (BACKUPS && BACKUPS.schedule) || {};
  let p;
  if (el.dataset.bk === 'time') {
    // Boşaltılmış ya da yarım bir saat kutusu KAYDEDİLMEZ; alan sunucudaki
    // değerine döner. Tarayıcı geçersiz girdide value'yu "" veriyor ve bu
    // sözleşmede geçerli bir saat değil.
    if (!/^\d{1,2}:\d{2}$/.test(el.value)) { el.value = s.time || '02:00'; return; }
    p = saveSchedule({ time: el.value });
  } else if (el.dataset.bk === 'keep') {
    const n = parseInt(el.value, 10);
    if (!(n >= 1)) { el.value = s.retention_days || 7; return; }
    p = saveSchedule({ retention_days: Math.min(365, n) });
  } else return;
  p.catch((e) => infoBox('Zamanlama kaydedilemedi', '<p>' + esc(e.message) + '</p>'));
});

/* --------------------------------------------------------------- açılış */
(async function init() {
  try {
    CATALOG = await api('/catalog');
  } catch (e) {
    // Controller kapalıysa sayfa yine de motor listesini gösterebilsin.
    CATALOG = await (await fetch('catalog.json')).json();
  }
  await Promise.all([refreshStatus(), refreshBackups(true)]);
  setInterval(refreshStatus, ST_ARALIK);
  // Yedek turu kendi sıklığını kendisi biliyor (30 sn, yedek alınırken 8);
  // buradaki yoklama yalnız “zamanı geldi mi” diye soruyor, her seferinde
  // ağa çıkmıyor.
  setInterval(refreshBackups, ST_ARALIK);
})();

/* Dil değişince kartları yeniden çiziyoruz: sözlük DOM'a uygulanıyor ama
   "3 saat önce" gibi birleştirilmiş metinler ancak yeniden çizimle düzelir. */
document.addEventListener('dbstack:dil', function () { renderSystem(); render(); renderSets(); });
