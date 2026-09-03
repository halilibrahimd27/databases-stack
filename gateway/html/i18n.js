/* =========================================================================
   DİL DESTEĞİ — Türkçe / İngilizce
   =========================================================================
   TASARIM KARARI: ANAHTAR = TÜRKÇE METNİN KENDİSİ.

   Alternatif "sembolik anahtar" (t('panel.baslik')) daha derli toplu görünür
   ama bu depoda YANLIŞ seçim olurdu: panel bugün baştan sona Türkçe yazılmış
   ve sembolik anahtara geçmek her dizgiyi iki yerden (kod + Türkçe sözlük)
   yönetmek demek. Asıl kazanç ise şu: SÖZLÜKTE OLMAYAN HER METİN TÜRKÇEYE
   DÜŞER. Yani yarım kalmış bir çeviri paneli bozmaz — İngilizce seçen
   kullanıcı çevrilmemiş cümleyi Türkçe görür, boş kutu ya da 'undefined'
   değil. Sessizce bozulmaktansa görünür biçimde eksik olmak yeğdir.

   ÜÇ YOL:
     t('metin')                 JS içinden
     data-i18n                  HTML metin düğümü
     data-i18n-attr="title,..." HTML nitelikleri (title, placeholder, aria-label)

   DİL SEÇİMİ: localStorage → tarayıcı dili → Türkçe.
   Seçim localStorage'da durur; sunucuya gitmez, kullanıcı başına ayrıdır.
   ========================================================================= */
(function () {
  'use strict';

  var DEPO = 'dbstack-lang';

  /* Sözlük: Türkçe → İngilizce. Yalnız KULLANICIYA GÖRÜNEN metinler.
     Sıra HTML'deki görünme sırasına yakın tutuldu; yeni metin eklerken
     alfabetik değil BAĞLAMSAL yere koyun, gözden kaçmasın. */
  var EN = {
    /* --- başlık ve genel --- */
    'Veritabanı Yönetim Paneli': 'Database Control Panel',
    'İhtiyacınız olanı açın, kullanmadığınızı kapatın.':
      'Turn on what you need, turn off what you don’t.',
    'Yedekler': 'Backups',
    'Kurtarma noktalarınız — ve gerektiğinde geri dönüş.':
      'Your recovery points — and the way back when you need it.',
    'Görünüm: sistem / açık / koyu': 'Appearance: system / light / dark',
    'Görünümü değiştir': 'Change appearance',
    'Sistem': 'System',
    'Açık': 'Light',
    'Koyu': 'Dark',
    'Dil: Türkçe / English': 'Language: Türkçe / English',
    'Dili değiştir': 'Change language',
    'Yükleniyor…': 'Loading…',
    'Yükleniyor...': 'Loading...',

    /* --- sistem çubuğu --- */
    'Sunucu durumu': 'Server status',
    'Bellek kullanımı': 'Memory usage',
    'Sunucu': 'Server',
    'Disk': 'Disk',
    'İşlemci': 'CPU',
    'çekirdek': 'cores',
    'boş': 'free',

    /* --- ana panel --- */
    'Hangi veritabanına ihtiyacınız var?': 'Which database do you need?',
    'Şu an açık': 'Currently on',
    'Kapalı': 'Off',
    'Bellek ve işlemci kullanan motorlar.': 'Engines using memory and CPU.',
    'Hiç kaynak harcamıyorlar. Ne işe yaradığını görmek için satıra tıklayın.':
      'They use no resources at all. Click a row to see what it is for.',
    'Durum işaretleri': 'Status badges',
    'Araçlar': 'Tools',
    'İzleme aç': 'Open monitoring',
    'Çalışıyor': 'Running',
    'Başlatılıyor': 'Starting',
    'Sorunlu': 'Unhealthy',
    'Aktif Et': 'Turn on',
    'Kapat': 'Turn off',
    'Bağlantı bilgisi': 'Connection details',
    'Kapat ve diğer işlemler': 'Turn off and other actions',
    'Ne işe yarar': 'What it is for',
    'Lisans': 'License',
    'port': 'port',
    'baştan ayrılan': 'reserved up front',
    'üst sınır': 'ceiling',
    'bellek baskısı: yok': 'memory pressure: none',
    'yedek kopya akıyor': 'replica is streaming',
    'yedek kopya AKMIYOR': 'replica is NOT streaming',
    'yedek kopya durumu ölçülmedi': 'replica state not measured',
    'otomatik devir açık': 'automatic failover on',
    'Yeniden dengele': 'Rebalance',

    /* --- son olaylar --- */
    'Son olaylar': 'Recent events',
    'Henüz olay yok.': 'No events yet.',

    /* --- son bir saat (ASH) --- */
    'Son bir saat — veritabanının içinde': 'Last hour — inside the database',
    'Beklemeler': 'Waits',
    'Bekletenler': 'Blockers',
    'Bu saatte yığının işleri': 'The stack’s own jobs this hour',
    'bekleme görülmedi': 'no waits observed',
    'kimse kimseyi bekletmedi': 'nobody blocked anybody',
    'yığın kendi işini çalıştırmadı': 'the stack ran no jobs of its own',
    'örnekleme durdu': 'sampling stopped',
    'sürüyor': 'running',
    'örnekte': 'in samples',
    'örnekte bekletti': 'samples spent blocking',

    /* --- yedekler sayfası --- */
    '← Yönetim paneli': '← Control panel',
    'Yedekleriniz burada': 'Your backups are here',
    'Otomatik yedek': 'Automatic backup',
    'Gece kendiliğinden koşan tur.': 'The round that runs by itself at night.',
    'Motorlar': 'Engines',
    'Saat': 'Time',
    'Saklama': 'Retention',
    'gün': 'days',
    'Yedek al': 'Back up now',
    'Prova yap': 'Run drill',
    'Son yedeğe dön': 'Restore latest',
    'Bu yedeğe dön': 'Restore this one',
    'Yedekleri göster': 'Show backups',
    'İçini gör': 'Look inside',
    'yedek': 'backups',
    'hiç yedek yok': 'no backups at all',
    'motor kapalı': 'engine is off',
    'en yeni': 'newest',
    'prova yapılmadı': 'no drill run',
    'prova geçti': 'drill passed',
    'yedek alınıyor': 'backing up',
    'geri yükleniyor': 'restoring',
    'kurtarma provası sürüyor': 'recovery drill running',
    'elle': 'manual',
    'zamanlı': 'scheduled',
    'dış': 'external',
    'Yedek alınıyor': 'Backing up',

    /* --- yedeğin içi --- */
    'Tablo': 'Table',
    'Satır': 'Rows',
    'tablo': 'tables',
    'görünüm': 'views',
    'rutin': 'routines',
    'indeks': 'indexes',
    'şifreli': 'encrypted',
    'Tablo bulunamadı.': 'No tables found.',
    'Görünümler': 'Views',
    'SQL’i göster': 'Show SQL',
    'Yedek okunuyor — geri yükleme YAPILMIYOR, dosya yalnız akıtılarak taranıyor…':
      'Reading the backup — NOTHING is being restored; the file is only streamed and scanned…',
    'Bu görünüm gerçek veri içerebilir; yedeğin kendisini gösteriyor.':
      'This view can contain real data; it shows the backup itself.',
    'Bu motorun yedek biçimi okunamıyor.':
      'This engine’s backup format cannot be read.',

    /* --- iş penceresi --- */
    'Tamamlandı': 'Completed',
    'Başarısız': 'Failed',
    'Ertelendi': 'Deferred',
    'Vazgeç': 'Cancel',
    'Devam': 'Continue',

    /* --- alt bağlantılar --- */
    'Yardımcı bağlantılar': 'Helpful links',
    'Yönetim paneli': 'Control panel',
    'Belgeler': 'Documentation',
    'Güvenlik kurulumu': 'Security setup',
    'Güvenlik sertifikasını indir': 'Download the security certificate',

    /* --- kurulum sayfası, kapalı motor, uzun cümleler --- */
    'Bu veritabanı şu an kapalı':
      'This database is currently off',
    'Paneline ulaşabilmek için önce ilgili veritabanını açmanız gerekiyor. Yönetim panelindeki listede o veritabanının satırındaki <b>Aktif Et</b> düğmesi yeterli.':
      'To reach its panel you first have to turn the database on. The <b>Turn on</b> button on that database’s row in the control panel is all it takes.',
    'Az önce açtıysanız birkaç saniye bekleyip sayfayı yenileyin — ilk açılışta imaj indirilmesi birkaç dakika sürebilir.':
      'If you just turned it on, wait a few seconds and refresh — on the very first start, pulling the image can take a few minutes.',
    'Yönetim paneline dön':
      'Back to the control panel',
    'Aşağıdaki listede her veritabanının <b>ne işe yaradığı</b> sade dille yazıyor. <b>Aktif Et</b> dediğinizde sistem sunucunun boş belleğini ölçer, veritabanına ne kadar ayıracağını ve ayarlarını kendisi hesaplar — teknik bir değer girmeniz gerekmez. Sunucu yetmiyorsa açmaz, sebebini söyler.':
      'The list below says in plain language <b>what each database is for</b>. When you press <b>Turn on</b>, the system measures the server’s free memory and works out by itself how much to give that database and how to tune it — you never enter a technical value. If the server cannot take it, it does not start it and tells you why.',
    '<b>Nereden başlamalı?</b> İlk kurulumda çoğu proje için doğru başlangıç: <b>PostgreSQL</b> (verileriniz için) ve <b>Redis</b> (hız için).':
      '<b>Where to start?</b> For a first install, the right starting point for most projects: <b>PostgreSQL</b> (for your data) and <b>Redis</b> (for speed).',
    'Kapalı motorlar aşağıdaki listede rozet taşımaz — hepsi kapalıdır. Rozetler yalnızca “Şu an açık” bölümünde görünür.':
      'Engines that are off carry no badge in the list below — they are all off. Badges appear only in the “Currently on” section.',
    'Oturumlar saniyede bir örnekleniyor. “Dün gece dondu, sabah baktım normal” sorusunun cevabı burada: o an kim neyi bekliyordu ve bekletenin kim olduğu. Örneklenemeyen saniyeler <b>ayrıca</b> yazılır — ölçüm yokluğu “sistem boştu” demek değildir.':
      'Sessions are sampled once a second. This is where the answer to “it froze last night, everything looked normal this morning” lives: who was waiting on what at that moment, and who was blocking them. Seconds that could not be sampled are reported <b>separately</b> — absence of measurement does not mean “the system was idle”.',
    'Açma, kapama, otomatik devir ve uyarılar. Otomatik devir gerçekleştiğinde burada — tanımlıysa webhook bildiriminde de — görünür.':
      'Turning on and off, automatic failover and warnings. When an automatic failover happens it shows up here — and in the webhook notification, if one is configured.',
    '<a href="/setup">Güvenlik kurulumu</a> — tarayıcıdaki “güvenli değil” uyarısını kaldırmak için adım adım anlatım.':
      '<a href="/setup">Security setup</a> — a step-by-step guide to removing the browser’s “not secure” warning.',
    '<a href="/ca.crt" download="databases-stack-ca.crt">Güvenlik sertifikasını indir</a> — sertifikayı zaten biliyorsanız doğrudan indirin.':
      '<a href="/ca.crt" download="databases-stack-ca.crt">Download the security certificate</a> — if you already know the drill, grab it directly.',
    '<a href="https://github.com/halilibrahimd27/databases-stack" target="_blank" rel="noopener">Belgeler</a> — kurulum, yedekleme ve komut satırı kullanımı.':
      '<a href="https://github.com/halilibrahimd27/databases-stack" target="_blank" rel="noopener">Documentation</a> — installation, backups and command-line usage.',
    'Tek seferlik güvenlik kurulumu':
      'One-time security setup',
    'Üç adım sürer; sonrasında tarayıcı uyarısı tamamen kalkar.':
      'It takes three steps; after that the browser warning is gone for good.',
    'Tarayıcı neden “Güvenli değil” diyor?':
      'Why does the browser say “Not secure”?',
    'Bağlantınız <b>şifreli</b> — sorun şifrelemede değil, <b>kimin imzaladığında</b>. Bu sunucu iç ağda çalışıyor ve bir alan adı yok; alan adı olmadan Let\'s Encrypt gibi kamuya açık bir sertifika sağlayıcısı sertifika veremez.':
      'Your connection <b>is encrypted</b> — the problem is not the encryption but <b>who signed it</b>. This server runs on an internal network and has no domain name; without one, a public certificate authority such as Let\'s Encrypt cannot issue a certificate.',
    'Bu yüzden kurulum sırasında sunucu <b>kendi sertifika otoritesini</b> üretti. Tarayıcınız bu otoriteyi henüz tanımıyor, o yüzden uyarıyor. Aşağıdaki dosyayı bir kez kurduğunuzda tanıyacak ve uyarı bir daha çıkmayacak.':
      'So during installation the server generated <b>its own certificate authority</b>. Your browser does not know that authority yet, which is why it warns you. Install the file below once and it will — and the warning will not come back.',
    '<a class="btn btn-primary btn-lg" href="/ca.crt" download="databases-stack-ca.crt"> Sertifikayı indir (ca.crt)</a>':
      '<a class="btn btn-primary btn-lg" href="/ca.crt" download="databases-stack-ca.crt"> Download the certificate (ca.crt)</a>',
    'Bu dosya yalnızca <b>ortak anahtar</b> içerir — gizli bir şey değildir, paylaşmak güvenlidir. Özel anahtar sunucuda kalır ve hiçbir zaman gönderilmez.':
      'This file contains only the <b>public key</b> — there is nothing secret in it and sharing it is safe. The private key stays on the server and is never sent anywhere.',
    'İşletim sisteminizi seçip adımları uygulayın.':
      'Pick your operating system and follow the steps.',
    'İndirdiğiniz <code>ca.crt</code> dosyasına <b>çift tıklayın</b>.':
      '<b>Double-click</b> the <code>ca.crt</code> file you downloaded.',
    '<b>Sertifikayı Yükle…</b> → <b>Yerel Bilgisayar</b> → İleri.':
      '<b>Install Certificate…</b> → <b>Local Machine</b> → Next.',
    '<b>Tüm sertifikaları aşağıdaki depoya yerleştir</b> → <b>Gözat</b> → <b>Güvenilen Kök Sertifika Yetkilileri</b> → Tamam → İleri → Son.':
      '<b>Place all certificates in the following store</b> → <b>Browse</b> → <b>Trusted Root Certification Authorities</b> → OK → Next → Finish.',
    'Tarayıcıyı <b>tamamen kapatıp</b> yeniden açın.':
      '<b>Fully close</b> the browser and open it again.',
    'Firefox kendi deposunu kullanır: Ayarlar → Gizlilik ve Güvenlik → Sertifikalar → Sertifikaları Görüntüle → Yetkililer → İçe Aktar.':
      'Firefox uses its own store: Settings → Privacy & Security → Certificates → View Certificates → Authorities → Import.',
    '<code>ca.crt</code> dosyasına çift tıklayın; <b>Anahtar Zinciri Erişimi</b> açılır.':
      'Double-click the <code>ca.crt</code> file; <b>Keychain Access</b> opens.',
    'Sertifikayı <b>Sistem</b> anahtar zincirine ekleyin.':
      'Add the certificate to the <b>System</b> keychain.',
    'Sertifikaya çift tıklayın → <b>Güven</b> → “Bu sertifikayı kullanırken” → <b>Her Zaman Güven</b>.':
      'Double-click the certificate → <b>Trust</b> → “When using this certificate” → <b>Always Trust</b>.',
    'Tarayıcıyı yeniden başlatın.':
      'Restart the browser.',
    'Terminalden:':
      'From the terminal:',
    'Chrome/Chromium ve Firefox kendi depolarını kullanır; tarayıcı ayarlarından “Yetkililer” bölümüne ayrıca eklemeniz gerekebilir.':
      'Chrome/Chromium and Firefox use their own stores; you may also need to add it under “Authorities” in the browser settings.',
    '<b>Android:</b> Ayarlar → Güvenlik → Şifreleme ve kimlik bilgileri → Sertifika yükle → CA sertifikası.':
      '<b>Android:</b> Settings → Security → Encryption &amp; credentials → Install a certificate → CA certificate.',
    '<b>iOS:</b> Dosyayı Safari ile indirin → Ayarlar → Profil İndirildi → Yükle. Ardından Ayarlar → Genel → Hakkında → <b>Sertifika Güveni Ayarları</b> bölümünden bu sertifikayı <b>etkinleştirin</b> (bu ikinci adım şarttır).':
      '<b>iOS:</b> Download the file with Safari → Settings → Profile Downloaded → Install. Then go to Settings → General → About → <b>Certificate Trust Settings</b> and <b>enable</b> this certificate (this second step is required).',
    'Sertifikayı kurduktan sonra tarayıcıyı yeniden başlatın ve devam edin:':
      'After installing the certificate, restart the browser and carry on:',
    '<a class="btn btn-primary btn-lg" id="go" href="/">Yönetim paneline git</a>':
      '<a class="btn btn-primary btn-lg" id="go" href="/">Go to the control panel</a>',
    'Kurmak istemiyorsanız uyarı ekranında <b>Gelişmiş → Devam et</b> diyerek de girebilirsiniz. Bağlantı yine şifrelidir; yalnız tarayıcı her seferinde uyarır.':
      'If you would rather not install it, you can still get in from the warning screen with <b>Advanced → Proceed</b>. The connection is still encrypted; the browser will just warn you every time.',
    'Ayrılan bellek':
      'Reserved memory',
    'Her veritabanının diskteki yedek dosyaları, ne zaman alındıkları ve kaynakları aşağıda. Gecelik yedeğin saati ve kaç gün saklanacağı da buradan ayarlanır.':
      'Below are each database’s backup files on disk, when they were taken and where they came from. The nightly backup’s time and how many days it is kept are set here too.',
    '<b>Bir yedek yalnız geri yüklenebildiği kadar yedektir.</b> Silinen ya da bozulan bir veriyi geri getirmek istediğinizde motorun satırındaki <b>Son yedeğe dön</b> düğmesini kullanın; belirli bir güne dönmek için dosya listesini açıp o satırdaki düğmeye basın.':
      '<b>A backup is only as good as your ability to restore it.</b> When you want to bring back deleted or corrupted data, use the <b>Restore latest</b> button on the engine’s row; to go back to a particular day, open the file list and press the button on that row.',
    '<a href="/">Yönetim paneli</a> — veritabanlarını açıp kapatma.':
      '<a href="/">Control panel</a> — turning databases on and off.',
    '<a href="https://github.com/halilibrahimd27/databases-stack" target="_blank" rel="noopener">Belgeler</a> — yedekleme, geri yükleme ve komut satırı kullanımı.':
      '<a href="https://github.com/halilibrahimd27/databases-stack" target="_blank" rel="noopener">Documentation</a> — backups, restores and command-line usage.',

    /* --- panel (JS ile çizilen) --- */
    '(toplam − işletim sistemi payı − çekirdek servisler).':
      '(total − operating-system share − core services).',
    '(üretimde ayrı lisans gerekir)': '(a separate licence is required in production)',
    ') fazla. Bu bellek gerçekten tutulur; tavanların aksine':
      '). This memory is genuinely held; unlike ceilings it',
    '); ama motorların hepsi aynı anda tavanına dayanırsa cgroup OOM':
      '); but if every engine hits its ceiling at the same time, the cgroup OOM',
    ', bağlantılarınız kopmaz.': ', and your connections stay up.',
    ', dağıtılabilir bellek ise': 'at start-up, while the distributable memory is',
    ', dağıtılabilir bellekten (': 'up front, more than the distributable memory (',
    ', çekirdek baskısı': ', kernel pressure',
    '. Sıfıra yakınsa sistemde bellek darlığı yoktur.':
      '. Close to zero means the system is not short of memory.',
    '. Tavanların aksine bu bellek gerçekten tutulur.':
      '. Unlike ceilings, this memory is genuinely held.',
    '. Var olan dosyalar silinmez ama yaşlanır: bugünden sonraki veriler hiçbir kopyada bulunmaz.':
      '. Existing files are not deleted but they age: nothing written after today will exist in any copy.',
    ': açık motorların üst': ': the ceilings of the running engines are',
    ': aşağıdaki “Eski kopyayı yeniden kur” eski düğümü':
      ': “Rebuild the old copy” below brings the old node back as a',
    '; dağıtılabilir bellek': '; the distributable memory allows up to',
    '; politika, dağıtılabilir belleğin (': '; policy allows up to',
    'Ana kopya yanıt vermezse sistem yedeğe kendisi geçer.':
      'If the primary stops answering, the system switches to the standby by itself.',
    'Ayrılacak bellek': 'Memory to reserve',
    'AÇIK': 'ON',
    'Aç': 'Turn on',
    'Açık bir veritabanını kapatırsanız bu satır tekrar kullanılabilir hâle gelir.':
      'Turn off a running database and this row becomes available again.',
    'Açık motorlara verilen tavanlar toplamı':
      'The ceilings given to the running engines total',
    'Açık motorların açılışta gerçekten ayırdığı toplam': 'The running engines really take',
    'Açık motorların baştan ayırdığı toplam': 'The running engines reserve',
    'Açık motorların bellek üst sınırları güncelleniyor. Container\'lar':
      'Updating the memory ceilings of the running engines. Because the containers',
    'Açık motorların docker üst sınırları toplamı':
      'The docker ceilings of the running engines total',
    'Açık veritabanlarının bellek': 'The memory',
    'Açılırsa izin verilecek üst sınır (docker --memory).':
      'The ceiling it would be allowed if turned on (docker --memory).',
    'Aşağıdaki düğme açık motorların sınırlarını':
      'The button below updates the limits of the running engines with',
    'BAŞARISIZ': 'FAILED',
    'Bakım yap': 'Run maintenance',
    'Bağlantı adresiniz değişmez — yönlendirmeyi sistem yapar.':
      'Your connection address does not change — the system does the redirecting.',
    'Bağlantı bilgisi alınamadı': 'Could not fetch the connection details',
    'Bağlantılarınız kopmaz, veri kaybı olmaz; değişen tek şey cgroup\'un izin verdiği en fazla bellektir.':
      'Your connections stay up and no data is lost; the only thing that changes is the maximum memory the cgroup allows.',
    'Başlatılıyor. İlk açılışta imaj indirileceği için birkaç dakika sürebilir.':
      'Starting. The first start pulls the image, so it can take a few minutes.',
    'Baştan ayrılan (rezerve):': 'Reserved up front:',
    'Baştan ayrılan bellek dağıtılabilirin': 'Memory reserved up front is above',
    'Baştan ayıracağı:': 'Would reserve up front:',
    'Bu bilgiler yönetici parolasına aittir. Uygulamalarınız için yetkisi kısıtlı ayrı bir kullanıcı oluşturmanız önerilir:':
      'These are the administrator credentials. For your applications, create a separate user with limited privileges:',
    'Bu dosya listede artık yok — saklama':
      'This file is no longer in the list — the retention',
    'Bu ek bellek tüketir; sistem yer olup olmadığını kontrol eder.':
      'This uses extra memory; the system checks whether there is room.',
    'Bu görünüm gerçek veri içerebilir; yedeğin':
      'This view can contain real data; it shows the backup',
    'Bu liste yalnız ad ve sayı verir. Dosyanın kendisini görmek için:':
      'This list gives only names and counts. To see the file itself:',
    'Bu motora ait çalışır durumda kalan container\'ları kaldırır — veri silinmez':
      'Removes any containers this engine has left running — no data is deleted',
    'Bu motorda bir iş sürüyor, bitmesini bekleyin':
      'A job is running on this engine; wait for it to finish',
    'Bu motorun listede bir yedeği': 'This engine has no backup',
    'Bundan sonra': 'From now on',
    'Container\'ı ayakta ama servis çalışmıyor (durum:':
      'Its container is up but the service is not running (status:',
    'Daha fazlası:': 'More:',
    'Dağıtılabilir:': 'Distributable:',
    'Devir yapıldı — şu an': 'Failover happened —',
    'Devirden sonra durdurulan eski kopya, yeni ana kopyanın':
      'The old copy, stopped after the failover, is rebuilt from scratch as the new primary’s',
    'Diskte kalır; tekrar “Aktif Et” dediğinizde her şey yerinde olur.':
      'It stays on disk; press “Turn on” again and everything is where you left it.',
    'Dosya boyutu': 'File size',
    'Dosya çok büyük olduğu için tamamı taranmadı —':
      'The file was too large to scan in full —',
    'Durum alınamadı:': 'Could not fetch the status:',
    'Durur, belleği serbest kalır. Verileriniz silinmez.':
      'Stops it and frees its memory. Your data is not deleted.',
    'Dönülecek dosya': 'File to restore',
    'Dönülecek yedek yok': 'No backup to restore',
    'Eski kopya yeniden kurulsun mu?': 'Rebuild the old copy?',
    'Eski kopyadaki veriler silinir': 'The data on the old copy is erased',
    'Eski kopyadaki veriler silinir, yeni ana kopyadan baştan kopyalanır.':
      'The data on the old copy is erased and copied afresh from the new primary.',
    'Eski kopyayı yeniden kur': 'Rebuild the old copy',
    'Gece alınan zamanlanmış yedek ayrıca sürer; bu, ek bir kurtarma noktası oluşturur. Dosyalar, tarihler ve geri yükleme':
      'The scheduled nightly backup still runs; this adds one more recovery point. Files, dates and restores are on the',
    'Geri Yükle': 'Restore',
    'Gerçek kullanım:': 'Actual usage:',
    'Görünümler:': 'Views:',
    'Güvenli bakım tabloyu kilitlemez; veritabanı çalışmaya devam eder.':
      'Safe maintenance does not lock the table; the database keeps serving.',
    'Henüz hiç yedek alınmadı.': 'No backup has been taken yet.',
    'Henüz hiçbir veritabanı açık değil — sunucu boşta duruyor. Aşağıdaki listeden ihtiyacınız olanı seçip “Aç” deyin.':
      'No database is on yet — the server is idle. Pick what you need from the list below and press “Turn on”.',
    'Her motorun diskteki yedek dosyaları.': 'Each engine’s backup files on disk.',
    'Hesaplanan teknik ayarlar (bilgi amaçlı)': 'Computed technical settings (for reference)',
    'Hiçbir yedek alınmıyor — bugün silinen ya da bozulan bir veriyi geri getirebileceğiniz kopya oluşmuyor.':
      'No backups are being taken — no copy is being made that could bring back data deleted or corrupted today.',
    'Katalogdaki her şey açık.': 'Everything in the catalogue is on.',
    'Kontrol servisine ulaşılamıyor:': 'Cannot reach the control service:',
    'Kurulum eksik:': 'Setup incomplete:',
    'Motor kapalı — geri yüklemek için önce açın':
      'The engine is off — turn it on before restoring',
    'Motor kapalı — yedek almak için önce açın':
      'The engine is off — turn it on before backing up',
    'Motorların': 'The memory the engines',
    'Okunamadı:': 'Could not read:',
    'Onaylamak için motorun adını yazın:': 'Type the engine’s name to confirm:',
    'Otomatik devir açılsın mı?': 'Turn on automatic failover?',
    'Otomatik devir kapatılsın mı?': 'Turn off automatic failover?',
    'Otomatik devri aç': 'Turn on automatic failover',
    'Otomatik devri kapat': 'Turn off automatic failover',
    'Otomatik yedek kapatılsın mı?': 'Turn off automatic backups?',
    'Otomatik yedek:': 'Automatic backup:',
    'Replika Kur': 'Set up replica',
    'Replika durdurulur. Ana kopya etkilenmez.':
      'The replica is stopped. The primary is untouched.',
    'Replika kapatılsın mı?': 'Turn off the replica?',
    'Replikasyon güncelleniyor…': 'Updating replication…',
    'SQL\'i göster': 'Show the SQL',
    'Saklama süresinden eski yedekler temizlik turunda silinir. Her motorun en yeni birkaç kopyası, yaşı ne olursa olsun korunur — kapalı kalmış bir motor son kurtarma noktasını da kaybetmesin diye.':
      'Backups older than the retention period are removed in the cleanup round. The newest few copies of every engine are kept whatever their age — so that an engine left switched off does not also lose its last recovery point.',
    'Sil-yaz döngüsü tabloları şişirir; bu alan diskte duruyor ama kullanılmıyor. Güvenli bakım tabloyu':
      'Delete-write cycles bloat tables; that space sits on the disk unused. Safe maintenance does',
    'Sistem ana kopyayı sürekli izler. Üst üste birkaç kez yanıt vermezse':
      'The system watches the primary continuously. If it fails to answer several times in a row it',
    'Sistem sunucunuzu ölçtü ve bu veritabanı için aşağıdaki ayarları seçti. Elle bir şey girmeniz gerekmiyor.':
      'The system measured your server and picked the settings below for this database. You do not have to enter anything by hand.',
    'Taban — baştan ayrılanların toplamı': 'Floor — sum of what is reserved up front',
    'Tavan — üst sınırların toplamı': 'Ceiling — sum of the limits',
    'Uygulamanızın bu veritabanına bağlanmak için kullanacağı bilgiler:':
      'What your application needs in order to connect to this database:',
    'Veri yerine konuyor. Motor bu sırada kısa süre yanıt vermeyebilir;':
      'The data is being put back. The engine may be briefly unresponsive;',
    'Verileriniz silinmez.': 'Your data is not deleted.',
    'Veritabanları yeniden': 'The databases are',
    'Veritabanları yeniden başlatılmaz.': 'The databases are not restarted.',
    'Veritabanı durdurulur ve belleği serbest kalır.':
      'The database is stopped and its memory is released.',
    'Veriye dokunulmadı. Sunucuda o an başka bir yedekleme ya da':
      'No data was touched. Another backup or restore was running on the server',
    'Yapılacak şey: kullanmadığınız bir': 'What to do: turn off a database you are',
    'Yapılacak şey: kullanmadığınız bir veritabanını kapatın ya da sunucuya RAM ekleyin.':
      'What to do: turn off a database you are not using, or add RAM to the server.',
    'Yedek bilgisi alınamadı — kontrol servisi kapalı olabilir. Bu,':
      'Could not fetch backup information — the control service may be down. This does',
    'Yedek bulunamadı': 'Backup not found',
    'Yedek kopya (replika) açılsın mı?': 'Turn on the standby copy (replica)?',
    'Yedek kopya kur': 'Set up a standby copy',
    'Yedek kopya yeniden kuruluyor…': 'Rebuilding the standby copy…',
    'Yedek kopyayı kapat': 'Turn off the standby copy',
    'Yedek okunuyor — geri yükleme YAPILMIYOR, dosya':
      'Reading the backup — NOTHING is being restored, the file is only',
    'Yedek, TEK KULLANIMLIK bir kopyada geri yükleniyor. Üretim':
      'The backup is restored into a THROWAWAY copy. Your production',
    'Yedek, veritabanı çalışırken alınır. Büyük bir veritabanında birkaç':
      'The backup is taken while the database is running. On a large database it can take a few',
    'Yedeği GERİ YÜKLEMEDEN içindeki tabloları göster':
      'Show the tables inside the backup WITHOUT restoring it',
    'Yedeğin tarihi': 'Backup date',
    'Yedeğin yaşı': 'Backup age',
    'Yeniden Kur': 'Rebuild',
    'Yeniden kur': 'Rebuild',
    'YÜKSEK': 'HIGH',
    'Zamanlama kaydedilemedi': 'Could not save the schedule',
    'ana kopya. Uygulamanız': 'is the primary now. Your application keeps connecting to',
    'aynı adrese': 'the same address',
    'az önce': 'just now',
    'açılamıyor': 'cannot be turned on',
    'açılsın mı?': '— turn it on?',
    'açılıyor…': 'starting…',
    'aştı.': '.',
    'bakımı…': 'maintenance…',
    'bağlanmaya devam eder, bağlantı bilgisi değişmez. Şu an yedek kopya':
      ', the connection details do not change. The standby right now is',
    'bağlantı bilgileri': 'connection details',
    'başlatmayla değişir.': 'on a restart.',
    'başlatılmaz': 'not restarted',
    'baştan ayrılacak bellek kalmadı': 'no memory left to reserve up front',
    'baştan ayırdığı': 'reserve up front',
    'beklerken geçirdiği zaman payı: son 10 sn %': 'share of time spent waiting: last 10 s %',
    'bellek (rezerve) bu işlemle değişmez: o, motorun kendi ayarından gelir ve ancak yeniden başlatmayla değişirdi.':
      'does not change here: that comes from the engine’s own configuration and would only change on a restart.',
    'bellek yetmiyor': 'not enough memory',
    'boş · baskı': 'free · pressure',
    'bu sunucuda çalışmaz': 'will not run on this server',
    'bugünkü koşullara göre yeniden hesaplanır ve':
      'of the running databases are recomputed for today’s conditions and applied with',
    'dakika sürebilir; pencereyi kapatsanız da iş sunucuda devam eder.':
      'minutes; the job carries on server-side even if you close this window.',
    'devir sırasında ana kopya durdurulur. Bu, iki kopyanın aynı anda yazı kabul edip verilerin ayrışmasını (split-brain) önlemek için zorunludur.':
      'the primary is stopped during failover. This is required to stop both copies accepting writes at once and diverging (split-brain).',
    'disk yetmiyor': 'not enough disk',
    'ertelendi, tekrar denenecek': 'deferred, will be retried',
    'geri getirir. Ana kopya': '. The primary stays',
    'geri yükleme sürüyordu; birkaç dakika sonra tekrar deneyin':
      'on the server; try again in a few minutes',
    'geri yükleme sürüyordu; o iş bitince tekrar deneyebilirsiniz.':
      'at that moment; try again once it finishes.',
    'geri yükleniyor…': 'restoring…',
    'geri yüklensin mi?': '— restore it?',
    'görünmüyor. Sayfayı tazeleyip tekrar bakın.':
      'in the list. Refresh the page and look again.',
    'hepsini temizler; verileriniz silinmez.':
      'button below clears all of it; your data is not deleted.',
    'hiçbir yedek alınmaz': 'no backup will be taken',
    'ile günceller.': '.',
    'ile uygulanır.': '.',
    'kapatılsın mı?': '— turn it off?',
    'kapatılıyor…': 'stopping…',
    'katına kadar izin veriyor (': '× that (',
    'katına — yani': '× the distributable memory (',
    'kendisini gösteriyor.': 'itself.',
    'killer devreye girer ve birini öldürür.': 'killer steps in and kills one of them.',
    'kurtarma provası…': 'restore drill…',
    'liste EKSİK olabilir.': 'the list may be INCOMPLETE.',
    'okunamadı': 'could not be read',
    'okunamadı: bu çekirdekte yok ya da erişilemiyor.':
      'could not be read: not present on this kernel, or not reachable.',
    'olarak baştan kurulur.': '.',
    'olarak kalır — rollerin yer değiştirmiş olması zararsızdır, geri takas etmek gereksiz ikinci bir kesinti demek olurdu.':
      '— the roles having swapped is harmless, and swapping them back would mean a second, needless outage.',
    'otomatik olarak': 'automatically',
    'pencereyi kapatsanız da iş sunucuda devam eder.':
      'the job carries on server-side even if you close this window.',
    'prova başarısız:': 'drill failed:',
    'prova ertelendi — sunucuda başka bir yedekleme ya da geri':
      'drill deferred — another backup or restore was running on the',
    'prova ölçülemedi': 'drill not measured',
    'sayfasında.': 'page.',
    'sebep bilinmiyor': 'reason unknown',
    'son deneme başarısız:': 'last attempt failed:',
    'son deneme ertelendi — sunucuda başka bir yedekleme ya da':
      'last attempt deferred — another backup or restore was running',
    'sınırları bugünkü koşullara göre yeniden hesaplanır ve':
      'recomputed for today’s conditions and applied with',
    'tabloyu kilitleyen agresif bakım ister.':
      'needs aggressive maintenance, which locks the table.',
    'temizliği silmiş olabilir. Sayfayı tazeleyin.':
      'sweep may have removed it. Refresh the page.',
    'toplamı; tavan bir rezervasyon değildir ve bugünkü koşullara göre yeniden hesaplanabilir.':
      'ceilings; a ceiling is not a reservation and can be recomputed for today’s conditions.',
    've veritabanı aşağıdaki yedekteki hâline döner; işlem sırasında motor kısa süre erişilemez.':
      'and the database returns to the state in the backup below; the engine is briefly unreachable during the operation.',
    've yeni ana kopyadan baştan kopyalanır. Bu bilinçlidir: iki kopyanın geçmişi devir anında ayrıştığı için eski veriyi korumak tutarsızlık yaratırdı.':
      'and copied afresh from the new primary. This is deliberate: the two histories diverged at the moment of failover, so keeping the old data would create an inconsistency.',
    'veritabanını kapatın. Üst sınırları yeniden hesaplamak burada işe':
      'not using. Recomputing the ceilings does not help',
    'veritabanınıza dokunulmaz. Büyük bir yedekte birkaç dakika sürebilir.':
      'database is untouched. On a large backup this can take a few minutes.',
    'yalnız akıtılarak taranıyor…': 'streamed and scanned…',
    'yapılır.': '.',
    'yaramaz — taban, motorun kendi ayarından gelir ve ancak yeniden':
      'here — the floor comes from the engine’s own configuration and only changes',
    'yazılan her şey kaybolur ve geri alınamaz. Elinizde daha yeni bir kopya olsun istiyorsanız önce “Yedek al” deyip sonra buraya dönün.':
      'everything written since is lost and cannot be recovered. If you want a newer copy in hand, press “Back up now” first and then come back here.',
    'yedek kopyayı devreye alır ve uygulamalarınızın bağlantısını oraya yönlendirir.':
      'promotes the standby and redirects your applications there.',
    'yedek olarak': 'standby',
    'yedeklerinizin silindiği anlamına gelmez; dosyalar sunucudaki':
      'not mean your backups are gone; the files are still on the server under',
    'yedeği': 'standby',
    'yeniden başlatılmadığı için işlem birkaç saniye sürer.':
      'are not restarted, this takes a few seconds.',
    'yeniden dağıtılamaz.': 'cannot be redistributed.',
    'yükleme sürüyordu': 'server',
    'Çalışıyor ama sağlık kontrolüne yanıt vermiyor. Birkaç dakika beklemesine rağmen düzelmezse kapatıp yeniden açmayı deneyin.':
      'Running, but not answering the health check. If it does not recover after a few minutes, try turning it off and on again.',
    'Çekirdek bellek baskısı:': 'Kernel memory pressure:',
    'Çekirdek — boş bellek ve baskı': 'Kernel — free memory and pressure',
    'Çiğnenen kural: taban.': 'Rule broken: the floor.',
    'Çiğnenen kural: tavan bütçesi.': 'Rule broken: the ceiling budget.',
    'Ölçülen boşluğun tamamı geri gelmeyebilir — yeri diske geri vermek':
      'Not all of the measured slack may come back — actually returning the space to the disk',
    'Ölçülen değerler': 'Measured values',
    'Önemli:': 'Important:',
    'Üst sınırlar yeniden hesaplansın mı?': 'Recompute the ceilings?',
    'Üst sınırlar yeniden hesaplanıyor…': 'Recomputing the ceilings…',
    'Üst sınırların toplamı politika sınırını':
      'The sum of the ceilings has crossed the policy limit',
    'çalışmıyor (': 'not running (',
    'ölçülemedi': 'not measured',
    'önce': 'ago',
    'üst sınır bütçesi doldu': 'the ceiling budget is full',
    'üst sınırları': 'ceilings',
    'üst sınırların': 'of the',
    'üstünde.': 'the distributable total.',
    'İkinci bir kopya tutulur; her değişiklik oraya da yazılır. Ek bellek ister.':
      'A second copy is kept and every change is written there too. Needs extra memory.',
    'İkinci kopya durur, ana kopya etkilenmez.':
      'The second copy stops; the primary is untouched.',
    'İlk açılışta veritabanı imajı indirileceği için birkaç dakika sürebilir.':
      'The first start pulls the database image, so it can take a few minutes.',
    'İstediğiniz zaman aynı düğmeyle geri açabilirsiniz.':
      'You can turn it back on with the same button whenever you like.',
    'İzin verilecek üst sınır': 'Ceiling it would be allowed',
    'İzin verilen üst sınır (tavan):': 'Allowed ceiling:',
    'İzleme durur. Ana kopya çökerse devir':
      'Watching stops. If the primary dies, failover is done',
    'İzleme durur; ana kopya çökerse devir elle yapılır.':
      'Watching stops; if the primary dies, failover is manual.',
    'İşlem sonrası boşta kalacak': 'Free afterwards',
    'İşlem yapılamadı': 'Could not do that',
    'Şimdi yedek al': 'Back up now',
    'Şu an başka bir motorda yedek alınıyor': 'A backup is running on another engine right now',
    'Şu an bir yedekleme sürüyor, bitmesini bekleyin':
      'A backup is running right now; wait for it to finish',
    'şu an açılamıyor': 'cannot be turned on right now',
    '— docker limitlerinin toplamı, rezervasyon değil.':
      '— the sum of the docker limits, not a reservation.',
    '— her gün': '— every day at',
    '— kadar izin veriyor. Şu an bir sorun görünmüyor (gerçek kullanım':
      ') — that is the limit. Nothing looks wrong right now (actual usage',
    '— motorların açılışta gerçekten ayırdığı bellek.':
      '— memory the engines really take at start-up.',
    '— o sırada başka bir yedekleme ya da geri yükleme sürüyordu. İki ağır iş aynı anda koşarsa aynı container\'ın belleğini iki kez zorlar; kilit sırayı koruyor ve tur koşmuş sayılmıyor.':
      '— another backup or restore was running at the time. Two heavy jobs at once strain the same container’s memory twice over; the lock keeps them in order and the round does not count as run.',
    '— tavanlar aynı anda dolmaz': '— ceilings do not all fill at once',
    '“~” işaretli sayılar TAHMİNDİR (INSERT satırlarından sayıldı); işaretsizler dökümdeki veri bloğundan birebir sayılmıştır.':
      'Numbers marked “~” are ESTIMATES (counted from INSERT statements); unmarked ones were counted exactly from the dump’s data block.',
    '⛔ Başarısız': '⛔ Failed',
    '✅ Tamamlandı': '✅ Done',
    '✓ geçti': '✓ passed',
    '✗ kaldı': '✗ failed',
    'Günlük yedek saati':
      'Daily backup time',
    'INSERT sayısından tahmin — kesin sayı ancak geri yükleyerek bulunur':
      'Estimated from the INSERT count — the exact number can only be found by restoring',
    'Onay için motor adını yazın':
      'Type the engine name to confirm',
    'Satırına git':
      'Go to its row',
    'Yedek dosyaları, zamanlama ve geri yükleme':
      'Backup files, schedule and restore',
    'Yedeklerin saklanacağı gün sayısı':
      'How many days backups are kept',
    'Yedeği tek kullanımlık bir kopyada geri yükler; üretime dokunmaz':
      'Restores the backup into a throwaway copy; production is untouched',
    'baştan ayrılanlar dağıtılabiliri aştı':
      'reserved exceeds distributable',
    'bellek baskısı:':
      'memory pressure:',
    /* --- göreli zaman: parçalardan kuruluyor, DOM'da tam metin yok --- */
    'birazdan': 'in a moment',
    '%s önce': '%s ago',
    '%s sonra': 'in %s',
    'zaman\x1fdakika': 'minute',
    'zaman\x1fsaat': 'hour',
    'zaman\x1fgün': 'day',
    'tr-TR': 'en-GB',

    /* --- ölçüm değeri taşıyan kalıplar ({n} = değişen değer) --- */
    '). “Yeniden başlıyor” hâlinde işlemci harcar ve kendiliğinden düzelmez. {1}':
      '). If it is stuck restarting it burns CPU and will not fix itself. {1}',
    '. En şişkin: {1}.':
      '. Most bloated: {1}.',
    'Açık motorlara verilen tavanlar toplamı {1}; politika, dağıtılabilir belleğin ({2}) {3} katına — yani {4} — kadar izin veriyor. Şu an bir sorun görünmüyor (gerçek kullanım {5}, çekirdek baskısı {6}); ama motorların hepsi aynı anda tavanına dayanırsa cgroup OOM killer devreye girer ve birini öldürür.':
      'The ceilings given to the running engines total {1}; policy allows up to {3}× the distributable memory ({2}) — that is {4}. Nothing looks wrong right now (actual usage {5}, kernel pressure {6}); but if every engine hits its ceiling at the same time, the cgroup OOM killer steps in and kills one of them.',
    'Açık motorların açılışta gerçekten ayırdığı toplam {1}, dağıtılabilir bellek ise {2}. Tavanların aksine bu bellek gerçekten tutulur.':
      'The running engines really take {1} at start-up, while the distributable memory is {2}. Unlike ceilings, this memory is genuinely held.',
    'Açık motorların baştan ayırdığı toplam {1}, dağıtılabilir bellekten ({2}) fazla. Bu bellek gerçekten tutulur; tavanların aksine yeniden dağıtılamaz.':
      'The running engines reserve {1} up front, more than the distributable memory ({2}). This memory is genuinely held; unlike ceilings it cannot be redistributed.',
    'Açık motorların docker üst sınırları toplamı {1}; dağıtılabilir bellek {2}. Politika {3} katına kadar izin veriyor ({4}).':
      'The docker ceilings of the running engines total {1}; the distributable memory is {2}. Policy allows up to {3}× that ({4}).',
    'Bakım — {1} boşa gidiyor':
      'Maintenance — {1} going to waste',
    'Baştan ayrılan (rezerve): {1} — motorların açılışta gerçekten ayırdığı bellek.':
      'Reserved up front: {1} — memory the engines really take at start-up.',
    'Baştan ayıracağı: {1}.':
      'Would reserve up front: {1}.',
    'Durum alınamadı: {1}':
      'Could not fetch the status: {1}',
    'Dökümün ilk {1} KB\'ı okunuyor…':
      'Reading the first {1} KB of the dump…',
    'Dökümün ilk {1} KB\'ı{2} — geri yükleme YAPILMADI.':
      'The first {1} KB of the dump{2} — NOTHING was restored.',
    'Gerçek kullanım: {1} / {2} RAM.{3} İzin verilen üst sınır (tavan): {4} — docker limitlerinin toplamı, rezervasyon değil. Dağıtılabilir: {5} (toplam − işletim sistemi payı − çekirdek servisler). Çekirdek bellek baskısı: {6}.':
      'Actual usage: {1} / {2} RAM.{3} Allowed ceiling: {4} — the sum of the docker limits, not a reservation. Distributable: {5} (total − operating-system share − core services). Kernel memory pressure: {6}.',
    'Görünümler: {1}':
      'Views: {1}',
    'Kontrol servisine ulaşılamıyor: {1}':
      'Cannot reach the control service: {1}',
    'Koşan son tur: {1}.':
      'Last round run: {1}.',
    'Makine dolmuş değil — {1} kullanımda ve çekirdek baskısı {2}. Dolan şey, açık motorlara verilmiş':
      'The machine is not full — {1} in use and kernel pressure {2}. What is full is the',
    'Okunamadı: {1}':
      'Could not read: {1}',
    'Son otomatik yedek: {1} · başarılı':
      'Last automatic backup: {1} · succeeded',
    'Yedekleri göster{1}':
      'Show backups{1}',
    'Zamanlanmış tur {1}':
      'Scheduled round {1}',
    'baştan ayrılan {1}':
      'reserved up front {1}',
    'bellek baskısı: {1}':
      'memory pressure: {1}',
    'boş · baskı {1}':
      'free · pressure {1}',
    'en çok {1} eşzamanlı oturum':
      'peak {1} concurrent sessions',
    'prova başarısız: {1}':
      'drill failed: {1}',
    'prova geçti {1}{2}':
      'drill passed {1}{2}',
    'son bir saatin {1}%\'i örneklendi':
      '{1}% of the last hour was sampled',
    'son deneme başarısız: {1}':
      'last attempt failed: {1}',
    'tavan toplamı %{1} — tavanlar aynı anda dolmaz':
      'ceilings total {1}% — ceilings do not all fill at once',
    '{1} artık container':
      '{1} leftover containers',
    '{1} aç':
      'Open {1}',
    '{1} için ikinci bir kopya kurulur ve ana kopyadaki her değişiklik otomatik olarak buraya da yazılır.':
      'A second copy of {1} is set up, and every change on the primary is written here too, automatically.',
    '{1} içindeki şu anki veriler SİLİNİR':
      'the current data in {1} WILL BE ERASED',
    '{1} panelini yeni sekmede aç':
      'Open the {1} panel in a new tab',
    '{1} tablo · {2} görünüm · {3} rutin · {4} indeks{5}':
      '{1} tables · {2} views · {3} routines · {4} indexes{5}',
    '{1} {2} aç':
      'Open {1} {2}',
    '{1} örnekte':
      'in {1} samples',
    '{1} örnekte bekletti':
      'blocked others in {1} samples',
    'Çekirdek ölçümü (/proc/pressure/memory) — süreçlerin bellek beklerken geçirdiği zaman payı: son 10 sn %{1}, son 60 sn %{2}. Sıfıra yakınsa sistemde bellek darlığı yoktur.':
      'Kernel measurement (/proc/pressure/memory) — the share of time processes spend waiting for memory: last 10 s {1}%, last 60 s {2}%. Close to zero means the system is not short of memory.',
    'çalışmıyor ({1})':
      'not running ({1})',
    'üst sınır {1}':
      'ceiling {1}',
    '— her gün {1}':
      '— every day at {1}',
    '⚠️ Lisans uyarısı — {1}':
      '⚠️ Licence warning — {1}',
    '⚠️ Lisans: {1}. Üretimde ayrı lisans gerekir.':
      '⚠️ Licence: {1}. A separate licence is required in production.',
    '(kırpıldı)': '(truncated)',
    '· {1} sn': '· {1} s',
    '(son {1} / {2})': '(latest {1} of {2})',
    '({1})': '({1})',

    /* --- zincir birleşince ortaya çıkan tam cümleler --- */
    '). “Yeniden başlıyor” hâlinde işlemci harcar ve kendiliğinden düzelmez. {1}Aşağıdaki':
      '). If it is stuck restarting it burns CPU and will not fix itself. {1}The',
    ': açık motorların üst sınırları bugünkü koşullara göre yeniden hesaplanır ve':
      ': the ceilings of the running engines are recomputed for today’s conditions and applied with',
    'Açık motorların bellek üst sınırları güncelleniyor. Container\'lar yeniden başlatılmadığı için işlem birkaç saniye sürer.':
      'Updating the memory ceilings of the running engines. Because the containers are not restarted, this takes a few seconds.',
    'Baştan ayrılan bellek dağıtılabilirin üstünde.':
      'Memory reserved up front is above the distributable total.',
    'Bu dosya listede artık yok — saklama temizliği silmiş olabilir. Sayfayı tazeleyin.':
      'This file is no longer in the list — the retention sweep may have removed it. Refresh the page.',
    'Bu motorda panelden geri yükleme yok; docs/BACKUP.md anlatıyor':
      'This engine cannot be restored from the panel; docs/BACKUP.md explains how',
    'Bu motorun listede bir yedeği görünmüyor. Sayfayı tazeleyip tekrar bakın.':
      'This engine has no backup in the list. Refresh the page and look again.',
    'Dosya çok büyük olduğu için tamamı taranmadı — liste EKSİK olabilir.':
      'The file was too large to scan in full — the list may be INCOMPLETE.',
    'Güvenli bakım tabloyu kilitlemez; veritabanı çalışmaya devam eder. Ölçülen boşluğun tamamı geri gelmeyebilir — yeri diske geri vermek tabloyu kilitleyen agresif bakım ister.':
      'Safe maintenance does not lock the table; the database keeps serving. Not all of the measured slack may come back — actually returning the space to the disk needs aggressive maintenance, which locks the table.',
    'Motorların açılışta GERÇEKTEN ayırdığı bellek (PostgreSQL shared_buffers, MariaDB innodb buffer pool, JVM motorlarında -Xms) toplandığında yer kalmıyor. Bu bellek gerçekten tutulur; yeniden dağıtılamaz.':
      'Adding up the memory the engines REALLY take at start-up (PostgreSQL shared_buffers, MariaDB innodb buffer pool, -Xms on the JVM engines) leaves no room. This memory is genuinely held; it cannot be redistributed.',
    'Veri yerine konuyor. Motor bu sırada kısa süre yanıt vermeyebilir; pencereyi kapatsanız da iş sunucuda devam eder.':
      'The data is being put back. The engine may be briefly unresponsive; the job carries on server-side even if you close this window.',
    'Veritabanları yeniden başlatılmaz':
      'The databases are not restarted',
    'Veriye dokunulmadı. Sunucuda o an başka bir yedekleme ya da geri yükleme sürüyordu; o iş bitince tekrar deneyebilirsiniz.':
      'No data was touched. Another backup or restore was running on the server at that moment; try again once it finishes.',
    'Yapılacak şey: kullanmadığınız bir veritabanını kapatın. Üst sınırları yeniden hesaplamak burada işe yaramaz — taban, motorun kendi ayarından gelir ve ancak yeniden başlatmayla değişir.':
      'What to do: turn off a database you are not using. Recomputing the ceilings does not help here — the floor comes from the engine’s own configuration and only changes on a restart.',
    'Yedek bilgisi alınamadı — kontrol servisi kapalı olabilir. Bu, yedeklerinizin silindiği anlamına gelmez; dosyalar sunucudaki backups/ dizininde durur.':
      'Could not fetch backup information — the control service may be down. This does not mean your backups are gone; the files are still in the backups/ directory on the server.',
    'Yedek, TEK KULLANIMLIK bir kopyada geri yükleniyor. Üretim veritabanınıza dokunulmaz. Büyük bir yedekte birkaç dakika sürebilir.':
      'The backup is restored into a THROWAWAY copy. Your production database is untouched. On a large backup this can take a few minutes.',
    'Yedek, veritabanı çalışırken alınır. Büyük bir veritabanında birkaç dakika sürebilir; pencereyi kapatsanız da iş sunucuda devam eder.':
      'The backup is taken while the database is running. On a large database it can take a few minutes; the job carries on server-side even if you close this window.',
    'prova ertelendi — sunucuda başka bir yedekleme ya da geri yükleme sürüyordu':
      'drill deferred — another backup or restore was running on the server',
    'son deneme ertelendi — sunucuda başka bir yedekleme ya da geri yükleme sürüyordu; birkaç dakika sonra tekrar deneyin':
      'last attempt deferred — another backup or restore was running on the server; try again in a few minutes',
    'Çekirdeğin bellek baskısı ölçümü (/proc/pressure/memory) okunamadı: bu çekirdekte yok ya da erişilemiyor.':
      'The kernel’s memory-pressure measurement (/proc/pressure/memory) could not be read: not present on this kernel, or not reachable.',
    'Üst sınırların toplamı politika sınırını aştı.':
      'The sum of the ceilings has crossed the policy limit.',

    /* --- şifreli ama anahtarsız yedek --- */
    'Bu yedek şifreli ve bu kurulumda BACKUP_ENCRYPT_KEY tanımlı değil — içi okunamaz ve geri yüklenemez. Yedeği alan kurulumun anahtarını .env dosyasına ekleyin.':
      'This backup is encrypted and BACKUP_ENCRYPT_KEY is not set on this install — it cannot be read or restored. Add the key from the install that took it to the .env file.',
    '{1} yedek açılamaz (şifreli, anahtar yok)':
      '{1} backups cannot be opened (encrypted, no key)',
    'açılamaz':
      'cannot open',

    /* --- gölge geri yükleme ve geri dönüş bileti --- */
    '. Kopya açılıp satırları doğrulandıktan sonra üretim ona geçer.':
      '. Once the copy opens and its rows check out, production switches to it.',
    ': karar yanlışsa tek düğmeyle geri dönülür. Klasik geri yüklemede bu düğme yoktur.':
      ': if the decision was wrong, one button takes you back. The classic restore has no such button.',
    'Bu motorda dönülecek bir kopya kayıtlı değil. Sayfayı tazeleyip tekrar bakın.':
      'No copy is recorded to return to for this engine. Refresh the page and look again.',
    'Bunun bedeli: geçişe kadar {1}':
      'What it costs: until the switch, {1}',
    'Container önceki kopyayla yeniden yaratılıyor.':
      'The container is being recreated with the previous copy.',
    'Dönülecek kopya':
      'Copy to return to',
    'Geri dön':
      'Go back',
    'Geri dönüş bileti yok':
      'No return ticket',
    'Geçiş zamanı':
      'Switch time',
    'Geçişte yüklenen':
      'Loaded at the switch',
    'Geçişten':
      'Data written',
    'Geçişten sonra':
      'After the switch',
    'Geçişten önceki kopyaya dön — kesinti saniyeler':
      'Return to the copy from before the switch — the outage is seconds',
    'Kesinti yalnız container yeniden yaratılırken — saniyeler.':
      'The outage is only the container being recreated — seconds.',
    'Kesinti yalnız geçiş anındadır':
      'The outage is the switch only',
    'Kesintisiz dön':
      'Restore without downtime',
    'Takas öncesine dön':
      'Back to before the switch',
    'Yedek ayrı bir kopyaya yükleniyor; üretim çalışmaya devam ediyor. Geçiş, kopya doğrulandıktan sonra ve saniyeler içinde olur.':
      'The backup is being loaded into a separate copy; production keeps running. The switch happens once the copy is verified, and takes seconds.',
    'Yeni kopyaya geç':
      'Switch to the new copy',
    'Yüklenecek dosya':
      'File to load',
    'bugünkü (belki bozuk) veriyi':
      'today’s (possibly corrupt) data',
    'döner.':
      '.',
    'eski veri 24 saat saklanır':
      'the old data is kept for 24 hours',
    'geri dönüş bileti açık — {1} saat kaldı':
      'return ticket open — {1} hours left',
    'geri yüklenir; {1} bu sırada':
      'is restored; {1} meanwhile',
    'geçişten önceki veriye':
      'to the data from before the switch',
    'kopya işaretçisi AYRIŞMIŞ':
      'copy pointer HAS DRIFTED',
    'kopya işaretçisi ölçülemedi':
      'copy pointer could not be measured',
    'servis etmeye devam eder, ve diskte bir kopyalık fazladan yer gerekir. Yer yetmezse işlem başlamadan sayıyla söylenir.':
      'keeps being served, and one extra copy’s worth of disk is needed. If there is not enough room you are told the numbers before anything starts.',
    'takas öncesine dönsün mü?':
      '— go back to before the switch?',
    'takas öncesine dönüyor…':
      'is going back to before the switch…',
    'yazılan veriler o kopyada bulunmaz; geri dönmek onları geride bırakır.':
      'after the switch is not in that copy; going back leaves it behind.',
    'yeni kopyaya geçsin mi?':
      '— switch to the new copy?',
    'yeni kopyaya hazırlanıyor…':
      'is being prepared on a new copy…',
    'Üretim çalışırken yeni bir kopyaya yükler; geçiş saniyeler sürer ve 24 saat geri dönülebilir':
      'Loads into a new copy while production runs; the switch takes seconds and can be undone for 24 hours',
    'çalışmaya devam eder':
      'keeps running',
    '— geri yükleme süresi kadar değil. Geri yükleme dakikalar sürebilir; motor o süre boyunca açık kalır.':
      '— not the length of the restore. The restore can take minutes; the engine stays up the whole time.',

    /* --- catalog.json içeriği: motor açıklamaları, kategoriler,
           rozetler, lisans ve devir notları --- */
    '"Bu e-postayı arka planda gönder" tarzı işler. Kafka\'dan çok daha basit; çoğu proje için yeterlidir.':
      'Jobs of the "send this email in the background" kind. Far simpler than Kafka, and enough for most projects.',
    '"Kimin arkadaşının arkadaşı", öneri motorları, dolandırıcılık tespiti gibi bağlantı sorguları.':
      'Connection queries such as "friend of a friend", recommendation engines and fraud detection.',
    '.NET / Windows tabanlı kurumsal uygulamalar genelde bunu ister. Ücretsiz Express sürümüyle gelir: veritabanı başına 10 GB\'a kadar veri, ~1.4 GB tampon havuzu. Diğerlerinden daha çok RAM tüketir.':
      '.NET / Windows-based enterprise applications usually ask for this. It ships with the free Express edition: up to 10 GB of data per database and a ~1.4 GB buffer pool. It uses more RAM than the others.',
    '0: \'max server memory\' bir tavandır. SQL Server sayfa havuzunu iş yükü geldikçe büyütür, açılışta o kadar belleği almaz.':
      '0: \'max server memory\' is a ceiling. SQL Server grows its page pool as the workload arrives; it does not take that much memory at start-up.',
    '0: Erlang VM belleği iş yüküyle büyür; açılışta ayrılan bir taban ayarlanmıyor.':
      '0: Erlang VM memory grows with the workload; no floor is set at start-up.',
    '0: MinIO nesne verisini diskte tutar, belleği istek başına kullanır; açılış tabanı yoktur.':
      '0: MinIO keeps object data on disk and uses memory per request; there is no start-up floor.',
    '0: Prometheus TSDB belleği seri sayısıyla büyür; açılışta ayrılan sabit bir taban yok.':
      '0: Prometheus TSDB memory grows with the number of series; there is no fixed floor allocated at start-up.',
    '0: WiredTiger önbelleği bir TAVANDIR. Veri okundukça o sınıra doğru büyür, açılışta ayrılmaz.':
      '0: the WiredTiger cache is a CEILING. It grows towards that limit as data is read; nothing is allocated at start-up.',
    '0: max_server_memory_usage bir tavandır; ClickHouse sorgu geldikçe büyür.':
      '0: max_server_memory_usage is a ceiling; ClickHouse grows as queries arrive.',
    '0: maxmemory bir TAVANDIR. Redis boş başlar, veri yazıldıkça büyür; baştan ayırdığı bir taban yoktur (ölçüm: 1278 MB tavan, 5 MB kullanım).':
      '0: maxmemory is a CEILING. Redis starts empty and grows as data is written; it reserves no floor up front (measured: 1278 MB ceiling, 5 MB in use).',
    '4.0\'dan beri SSPL. OSI onaylı \'açık kaynak\' DEĞİL. Kendi işiniz için kullanmak serbesttir; MongoDB\'yi bir SERVİS olarak üçüncü taraflara sunarsanız tüm hizmet yığınınızı açmanız istenir.':
      'SSPL since 4.0. NOT OSI-approved \'open source\'. Using it for your own business is free; if you offer MongoDB to third parties AS A SERVICE you are required to open your whole service stack.',
    '7.11\'den beri ELv2+SSPL; OSI onaylı değil. 8.16+ sürümlerde AGPL-3.0 seçeneği de var. Kendi kullanımınız serbest; yönetilen arama servisi olarak SATAMAZSINIZ.':
      'ELv2+SSPL since 7.11; not OSI-approved. Versions 8.16+ also offer AGPL-3.0. Your own use is free; you may NOT sell it as a managed search service.',
    '7.4 ile RSALv2+SSPL\'e geçti, 8.0 ile üçüncü seçenek olarak AGPL-3.0 eklendi. Pinlenen 8-alpine AGPL kapsamındadır. Copyleft istemiyorsanız Valkey birebir yerine geçer: REDIS_IMAGE=valkey/valkey:8-alpine':
      'Moved to RSALv2+SSPL with 7.4; 8.0 added AGPL-3.0 as a third option. The pinned 8-alpine falls under AGPL. If you do not want copyleft, Valkey is a drop-in replacement: REDIS_IMAGE=valkey/valkey:8-alpine',
    'AMQP mesaj kuyruğu. Klasik iş kuyruğu senaryoları.':
      'AMQP message queue. Classic job-queue scenarios.',
    'Always On AG ayrı node\'lar ve Windows/Linux cluster ister; tek makinede kurulamaz.':
      'Always On AG requires separate nodes and a Windows/Linux cluster; it cannot be set up on a single machine.',
    'Always On AG tek container\'da kurulamaz; ayrı node\'lar + Enterprise/Developer cluster gerekir.':
      'Always On AG cannot be set up in a single container; it needs separate nodes plus an Enterprise/Developer cluster.',
    'Amazon S3\'ün kendi sunucunuzdaki karşılığı. Yüklenen dosyaları veritabanı yerine burada tutun.':
      'The equivalent of Amazon S3 on your own server. Keep uploaded files here rather than in the database.',
    'Arama ve log analitiği motoru. Kibana ile birlikte gelir.':
      'Search and log analytics engine. Ships with Kibana.',
    'Arama ve log incelemesi için':
      'For search and log inspection',
    'Açık olan her veritabanı için hazır grafikler gelir: kaç bağlantı var, saniyede kaç işlem düşüyor, bellek yetiyor mu, yedek kopya geride mi. Her grafiğin altında ne anlama geldiği ve ne zaman endişelenmeniz gerektiği yazar.':
      'Every database that is on gets ready-made graphs: how many connections there are, how many transactions per second, whether memory is sufficient, whether the standby is behind. Under each graph it says what it means and when you should be concerned.',
    'Açık veritabanlarının grafikleri. Prometheus + Grafana.':
      'Graphs for the databases that are on. Prometheus + Grafana.',
    'BSD benzeri, en serbest lisanslardan biri. Kısıtlama yok.':
      'BSD-like, one of the most permissive licences. No restriction.',
    'Basit iş kuyruğu için':
      'For a simple job queue',
    'Bilgisayarınıza kurun':
      'Install it on your computer',
    'Bir sistemin ürettiği olayları başka sistemlerin sırayla tüketmesi. Mikroservis mimarilerinde yaygındır.':
      'Events produced by one system, consumed in order by others. Common in microservice architectures.',
    'Bolt protokolü':
      'Bolt protocol',
    'Cassandra\'da primary yoktur; her node eşittir. Dayanıklılık replication_factor ile sağlanır.':
      'Cassandra has no primary; every node is equal. Durability comes from replication_factor.',
    'Cassandra\'da primary/replica yoktur; keyspace başına replication_factor ile node ekleyerek ölçeklenir.':
      'Cassandra has no primary/replica; you scale by adding nodes with a per-keyspace replication_factor.',
    'Causal cluster yalnız Enterprise\'da vardır.':
      'Causal clustering exists only in Enterprise.',
    'Causal cluster yalnızca Neo4j Enterprise\'da vardır; Community tek node çalışır.':
      'Causal clustering exists only in Neo4j Enterprise; Community runs on a single node.',
    'Community sürümü GPL-3.0. Kullanmak serbest; kümeleme, çevrimiçi yedek ve rol bazlı yetkilendirme yalnız ticari Enterprise\'da var.':
      'The Community edition is GPL-3.0. Free to use; clustering, online backup and role-based authorisation exist only in the commercial Enterprise edition.',
    'Dağıtık event streaming platformu (KRaft, Zookeeper\'sız).':
      'Distributed event streaming platform (KRaft, no Zookeeper).',
    'Dağıtık wide-column store. Yüksek yazma hacmi, lineer ölçek.':
      'Distributed wide-column store. High write volume, linear scaling.',
    'Distributed mode en az 4 disk/node ister; tek node erasure-code\'suz çalışır.':
      'Distributed mode needs at least 4 disks/nodes; a single node runs without erasure coding.',
    'Doküman':
      'Document',
    'Doküman veritabanı. Şemasız JSON/BSON kayıtlar.':
      'Document database. Schemaless JSON/BSON records.',
    'Dosya bazlı zayıf copyleft. Kullanımda pratik kısıtlama yok.':
      'File-level weak copyleft. No practical restriction on use.',
    'Dosya ve görsel depolama':
      'File and image storage',
    'ES_JAVA_OPTS içindeki -Xms açılışta ayrılan heap\'tir ve -Xmx ile eşit verilir.':
      'The -Xms in ES_JAVA_OPTS is the heap allocated at start-up and is set equal to -Xmx.',
    'En sık kullanılan':
      'Most used',
    'GTID tabanlı asenkron replikasyon. Replika read-only açılır.':
      'GTID-based asynchronous replication. The replica starts read-only.',
    'Gelişmiş ilişkisel veritabanı. JSONB, GIS, full-text.':
      'Advanced relational database. JSONB, GIS, full-text.',
    'Genelde başka bir DB ile birlikte':
      'Usually alongside another DB',
    'Grafana OSS AGPL-3.0\'dır. Olduğu gibi çalıştırmak serbesttir; AGPL yükümlülüğü ancak Grafana\'yı DEĞİŞTİRİP ağ üzerinden üçüncü taraflara sunarsanız doğar. İç ağda kendi panolarınızı kullanmak bu kapsama girmez.':
      'Grafana OSS is AGPL-3.0. Running it as-is is free; the AGPL obligation arises only if you MODIFY Grafana and offer it to third parties over a network. Using your own dashboards on an internal network does not fall under that.',
    'Graph veritabanı. İlişki ağırlıklı sorgular (Cypher).':
      'Graph database. Relationship-heavy queries (Cypher).',
    'HTTP arayüzü':
      'HTTP interface',
    'Her kaydın alanları farklı olabilir. Ürün katalogları, form yanıtları, IoT kayıtları gibi değişken veriler.':
      'Every record can have different fields. Variable data such as product catalogues, form responses and IoT readings.',
    'Hız için geçici bellek deposu':
      'A temporary in-memory store for speed',
    'Index başına number_of_replicas ile. Tek node\'da replika ataması yapılamaz (yellow health normaldir).':
      'Per index, via number_of_replicas. On a single node no replica can be assigned (yellow health is normal).',
    'InnoDB buffer pool\'unu sunucu AÇILIŞTA ayırır ve işletim sistemine geri vermez; MARIADB_MEM_LIMIT ise yalnızca üst sınırdır.':
      'The server allocates the InnoDB buffer pool AT START-UP and never gives it back to the operating system; MARIADB_MEM_LIMIT is only a ceiling.',
    'KAFKA_HEAP_OPTS içindeki -Xms açılışta ayrılan JVM heap\'idir.':
      'The -Xms in KAFKA_HEAP_OPTS is the JVM heap allocated at start-up.',
    'Kafka bir log\'dur, veritabanı değil — yedek yerine RF ve retention politikası kullanılır.':
      'Kafka is a log, not a database — instead of backups you use RF and a retention policy.',
    'Kafka protokolü':
      'Kafka protocol',
    'Kafka\'ya göre daha kolay':
      'Easier than Kafka',
    'Kalıcı veri deposu değildir. Oturum bilgisi, önbellek ve iş kuyruğu için kullanılır; uygulamayı belirgin hızlandırır.':
      'Not a durable data store. Used for session state, caching and job queues; it makes an application noticeably faster.',
    'Klasik tablolu veri için en yaygın seçim':
      'The most common choice for classic tabular data',
    'Kolon tabanlı OLAP veritabanı. Milyar satırda saniyealtı sorgu.':
      'Column-oriented OLAP database. Sub-second queries over a billion rows.',
    'Kullanıcılar, siparişler, ürünler gibi satır-sütun verisi için. JSON alanları, harita/konum verisi, tam metin arama ve karmaşık raporlama sorguları da doğrudan içinde çözülür — çoğu proje bunun dışına çıkmadan yıllarca gider.':
      'For row-and-column data such as users, orders and products. JSON fields, map/location data, full-text search and complex reporting queries are all handled inside it too — most projects go for years without needing anything else.',
    'Kullanıcılar, siparişler, ürünler gibi satır-sütun verisi. WordPress, Laravel, çoğu web uygulaması bunu ister.':
      'Row-and-column data such as users, orders and products. WordPress, Laravel and most web applications ask for this.',
    'Mesajlaşma & Streaming':
      'Messaging & Streaming',
    'Microsoft SQL Server 2022 Express. T-SQL iş yükleri.':
      'Microsoft SQL Server 2022 Express. T-SQL workloads.',
    'Microsoft dünyası uygulamaları için':
      'For applications in the Microsoft world',
    'Milyonlarca satır üzerinde toplam/ortalama alan raporlar. Günlük uygulama verisi için değil, analiz için.':
      'Reports that sum or average over millions of rows. Not for everyday application data — for analysis.',
    'MongoDB kendi seçimini yapar. Çoğunluk gerektiği için 3. üye olarak bir arbiter eklenir — 2 üyeyle biri düşünce çoğunluk kaybolur ve seçim yapılamaz.':
      'MongoDB holds its own election. Because a majority is required, an arbiter is added as a third member — with two members, losing one destroys the majority and no election can be held.',
    'MongoDB protokolü':
      'MongoDB protocol',
    'MySQL protokolü':
      'MySQL protocol',
    'MySQL uyumlu ilişkisel veritabanı. Genel amaçlı OLTP.':
      'MySQL-compatible relational database. General-purpose OLTP.',
    'Partition lider seçimi KRaft controller\'ın işidir; tek broker\'da devreye girmez.':
      'Partition leader election is the KRaft controller\'s job; it does not come into play on a single broker.',
    'PgBouncer bağlantı havuzu':
      'PgBouncer connection pool',
    'PostgreSQL protokolü':
      'PostgreSQL protocol',
    'REPLICAOF NO ONE ile replika primary olur. Redis Sentinel\'e gerek kalmaz; aynı işi controller yapar.':
      'REPLICAOF NO ONE makes the replica the primary. Redis Sentinel is not needed; the controller does the same job.',
    'RESP protokolü':
      'RESP protocol',
    'Rapor ve analiz sorguları için':
      'For reporting and analytics queries',
    'Replica set (rs0). Primary de --replSet ile yeniden başlar — kesinti olur.':
      'Replica set (rs0). The primary also restarts with --replSet — there is an outage.',
    'ReplicatedMergeTree + ClickHouse Keeper gerektirir; tek node\'da kapalıdır.':
      'Requires ReplicatedMergeTree plus ClickHouse Keeper; it is off on a single node.',
    'Replika yükseltilir ve yazmaya açılır. Eski primary fence edilir (durdurulur) — iki primary\'nin aynı anda yazması (split-brain) böyle engellenir.':
      'The replica is promoted and opened for writes. The old primary is fenced (stopped) — that is how two primaries writing at once (split-brain) is prevented.',
    'Sabit şeması olmayan kayıtlar için':
      'For records with no fixed schema',
    'Saniyede on binlerce kayıt yazan sistemler (sensör, tıklama, log). Küçük projeler için gereğinden ağırdır.':
      'Systems writing tens of thousands of records per second (sensors, clicks, logs). Heavier than small projects need.',
    'Sertifikayı indirin':
      'Download the certificate',
    'Servisler arası olay akışı için':
      'For event flow between services',
    'Shard\'ların primary/replica ataması küme içinde otomatiktir; tek node\'da yapacak bir şey yoktur.':
      'Primary/replica assignment of shards is automatic within the cluster; on a single node there is nothing to do.',
    'Site içi arama kutusu, ya da uygulama loglarını toplayıp Kibana\'da grafikle inceleme. Yanında Kibana arayüzü gelir.':
      'An on-site search box, or collecting application logs and inspecting them graphically in Kibana. The Kibana interface comes with it.',
    'Standby pg_ctl promote ile primary olur. Eski primary fence edilir; geri döndüğünde otomatik primary OLMAZ, replika olarak yeniden kurulur.':
      'The standby becomes primary via pg_ctl promote. The old primary is fenced; when it comes back it does NOT automatically become primary, it is rebuilt as a replica.',
    'TDS protokolü':
      'TDS protocol',
    'Tablolu veri + gelişmiş özellikler':
      'Tabular data plus advanced features',
    'Tam açık kaynak. Kullanımda kısıtlama yok.':
      'Fully open source. No restriction on use.',
    'Topic başına replication.factor ile. Tek broker\'da RF=1 sınırı vardır.':
      'Per topic, via replication.factor. A single broker is limited to RF=1.',
    'Varsayılan MSSQL_PID=Express: ücretsizdir ve üretimde kullanılabilir. Sınırları: veritabanı başına 10 GB, ~1.4 GB tampon havuzu, en fazla 4 çekirdek. Tüm özellikler gerekiyorsa MSSQL_PID=Developer ücretsizdir ama YALNIZ geliştirme/test içindir; üretimde Standard/Enterprise lisansı gerekir.':
      'The default MSSQL_PID=Express is free and may be used in production. Its limits: 10 GB per database, ~1.4 GB buffer pool, at most 4 cores. If you need every feature, MSSQL_PID=Developer is free but is for development/test ONLY; production requires a Standard/Enterprise licence.',
    'Veritabanlarınızın grafikleri':
      'Graphs of your databases',
    'Veritabanı değil, izleme aracı':
      'Not a database — a monitoring tool',
    'cassandra-env.sh MAX_HEAP_SIZE\'ı hem -Xms hem -Xmx yapar; JVM heap\'i açılışta ayırır.':
      'cassandra-env.sh sets MAX_HEAP_SIZE as both -Xms and -Xmx; the JVM allocates the heap at start-up.',
    'heap initial ve max eşit veriliyor, JVM açılışta ayırır. Sayfa önbelleği (NEO4J_PAGECACHE) sayfa okundukça dolar, o bir tavandır.':
      'Heap initial and max are set equal, so the JVM allocates at start-up. The page cache (NEO4J_PAGECACHE) fills as pages are read; that one is a ceiling.',
    'replicaof ile anlık. Kesinti yok, replika read-only.':
      'Instant, via replicaof. No outage; the replica is read-only.',
    'shared_buffers\'ı postmaster AÇILIŞTA tek parça paylaşımlı bellek olarak ayırır. work_mem bağlantı başına ve geçicidir, rezerve değildir.':
      'The postmaster allocates shared_buffers AT START-UP as one block of shared memory. work_mem is per-connection and temporary, not a reservation.',
    'Çok yüksek yazma hacmi için':
      'For very high write volume',
    'Ölçüm verisi yedeklenmez: kaybolursa yeniden toplanır, veritabanlarınızın verisi değildir. Panolar zaten dosya olarak depoda durur.':
      'Measurement data is not backed up: if lost it is collected again, and it is not your databases\' data. The dashboards are kept in the repository as files anyway.',
    'Ücretli DEĞİL, AGPL-3.0. Ancak 2025\'te community konsolundaki YÖNETİM özellikleri ticari AIStor\'a taşındı. Bu yüzden sürüm bilerek o değişiklikten önceye sabitlendi (konsol tam çalışsın diye). AGPL: MinIO\'yu değiştirip servis olarak sunarsanız kaynağı açmanız gerekir; kendi altyapınızda kullanmak serbesttir.':
      'NOT paid — AGPL-3.0. However, in 2025 the MANAGEMENT features of the community console moved to the commercial AIStor. The version is therefore pinned deliberately to before that change (so the console works in full). AGPL: if you modify MinIO and offer it as a service you must open your source; using it on your own infrastructure is free.',
    'İlerleme aşağıda canlı görünür. Pencereyi kapatsanız da iş sunucuda devam eder.':
      'Progress appears live below. The job carries on server-side even if you close the window.',
    'İlişki ağırlıklı veri için':
      'For relationship-heavy data',
    'İlişkisel':
      'Relational',
    'İlk açılışta veritabanı imajı indirileceği için bu birkaç dakika sürebilir. Pencereyi açık bırakabilirsiniz; iş sunucuda devam eder.':
      'The first start pulls the database image, so this can take a few minutes. You can leave the window open; the job carries on server-side.',
    'İzleme aracının yedeği olmaz; kapalıyken veritabanlarınız etkilenmez.':
      'A monitoring tool has no standby; while it is off your databases are unaffected.',
    'İşlem sürüyor…':
      'Working…',
    'Tam açık kaynak. Kısıtlama yok.':
      'Fully open source. No restriction.',
    'İlk açılışta veritabanı imajı indirileceği için bu birkaç dakika sürebilir.':
      'The first start pulls the database image, so this can take a few minutes.',
    'İlk açılışta veritabanı imajı indirileceği için bu birkaç dakika sürebilir. Pencereyi açık bırakabilirsiniz; ilerleme aşağıda canlı görünür.':
      'The first start pulls the database image, so this can take a few minutes. You can leave the window open; progress appears live below.',

    /* --- değerle başlayan kalıplar ('512 MB baştan ayrılan') --- */
    '{1} Baştan ayıracağı: {2}.':
      '{1} Would reserve up front: {2}.',
    '{1} açılsın mı?':
      'Turn on {1}?',
    '{1} açılıyor…':
      'Starting {1}…',
    '{1} bakımı…':
      '{1} maintenance…',
    '{1} bağlantı bilgileri':
      '{1} connection details',
    '{1} baştan ayrılan':
      '{1} reserved up front',
    '{1} boş':
      '{1} free',
    '{1} boş · baskı {2}':
      '{1} free · pressure {2}',
    '{1} geri yükleniyor…':
      'Restoring {1}…',
    '{1} geri yüklensin mi?':
      'Restore {1}?',
    '{1} kapatılsın mı?':
      'Turn off {1}?',
    '{1} kapatılıyor…':
      'Stopping {1}…',
    '{1} kurtarma provası…':
      '{1} restore drill…',
    '{1} takas öncesine dönsün mü?':
      'Take {1} back to before the switch?',
    '{1} takas öncesine dönüyor…':
      'Taking {1} back to before the switch…',
    '{1} yeni kopyaya geçsin mi?':
      'Switch {1} to the new copy?',
    '{1} yeni kopyaya hazırlanıyor…':
      'Preparing {1} on a new copy…',
    '{1} çekirdek':
      '{1} cores',
    '{1} üst sınır':
      '{1} ceiling',
    '{1} şu an açılamıyor':
      '{1} cannot be turned on right now',
    '{1}Veriye dokunulmadı. Sunucuda o an başka bir yedekleme ya da geri yükleme sürüyordu; o iş bitince tekrar deneyebilirsiniz.':
      '{1}No data was touched. Another backup or restore was running on the server at that moment; try again once it finishes.',
    'sn': 's',

    /* --- şema parmak izi --- */
    'Yedek alınırken kaydedilen şema: {1}{2}': 'Schema recorded when the backup was taken: {1}{2}',
    '{1} kısıt': '{1} constraints',
    '{1} tablo': '{1} tables',
    '{1} indeks': '{1} indexes',
    '{1} view': '{1} views',
    '{1} trigger': '{1} triggers',
    '{1} rutin': '{1} routines',
    '— yedek alınırken şema DEĞİŞTİ, bu bağlantı kesin değil': '— the schema CHANGED while the backup was taken, so this link is not certain',
    'şema {1}': 'schema {1}'
  };

  function dilOku() {
    try {
      var d = localStorage.getItem(DEPO);
      if (d === 'tr' || d === 'en') return d;
    } catch (e) { /* gizli sekme: localStorage erişimi atar */ }
    var n = (navigator.language || 'tr').toLowerCase();
    return n.indexOf('tr') === 0 ? 'tr' : 'en';
  }

  var DIL = dilOku();

  /* Sözlükte yoksa Türkçesi döner. Bu bir kusur değil, tasarım: eksik
     çeviri görünür olur ama panel çalışmaya devam eder. */
  /* Aynı Türkçe kelime iki ayrı yerde ayrı İngilizce ister: 'gün'
     saklama etiketinde "days", göreli zamanda "day"dir (çoğul eki ayrıca
     ekleniyor). Bağlam veren çağrı önce 'baglam\x1fmetin' anahtarına bakar,
     bulamazsa düz anahtara düşer — yani bağlam eklemek hiçbir şeyi bozmaz. */
  var AYIRAC = '\x1f';

  function t(metin, baglam) {
    if (DIL === 'tr') return metin;
    var k = String(metin == null ? '' : metin);
    if (baglam && Object.prototype.hasOwnProperty.call(EN, baglam + AYIRAC + k)) {
      return EN[baglam + AYIRAC + k];
    }
    if (Object.prototype.hasOwnProperty.call(EN, k)) return EN[k];
    var kal = kalipCevir(k);
    return kal === null ? k : kal;
  }

  /* HTML'i çevir: data-i18n metin düğümünü, data-i18n-attr nitelikleri.
     Her çizimden sonra yeniden çağrılabilir (panel kartları JS üretiyor). */
  /* CÜMLE İÇİNDE <b>/<a> geçen metinler için: parçayı ayrı çevirmek
     İngilizcede kelime sırasını bozar ("ne işe yaradığı" tek başına
     çevrilirse cümlenin neresine oturacağı belli olmaz). Bu yüzden
     data-i18n-html, elemanın TÜM iç HTML'ini bir anahtar olarak alır ve
     çeviri de HTML olarak verilir. Sözlükte yoksa Türkçesi kalır. */
  function uygulaHtml(k) {
    k.querySelectorAll('[data-i18n-html]').forEach(function (el) {
      if (!el.dataset.i18nHtmlSrc) {
        el.dataset.i18nHtmlSrc = el.innerHTML.replace(/\s+/g, ' ').trim();
      }
      el.innerHTML = t(el.dataset.i18nHtmlSrc);
    });
  }

  /* --- JS ile çizilen içerik ------------------------------------------
     Panel kartlarını, ölçüm tablolarını ve uyarıları app.js/yedekler.js
     şablon dizgileriyle üretiyor. Bunların her birine data-i18n koymak
     üç yüzden fazla yerde ŞABLONU bölmek demekti; hem kodu okunmaz eder
     hem de her yeni özellikte unutulacak bir adım ekler.

     Onun yerine çeviri DOM'a uygulanıyor: yeni gelen METİN DÜĞÜMÜ sözlükte
     varsa yerinde değiştiriliyor. Anahtar birimi metin düğümüdür — yani
     "<b>Kapat</b> hepsini temizler" cümlesinde <b>'nin içi ve dışı ayrı
     iki anahtardır. İngilizcede kelime sırası bozulabilecek yerlerde
     data-i18n-html hâlâ tercih edilmeli; bu yol kısa ve bağımsız parçalar
     içindir.

     Özgün Türkçe metin WeakMap'te tutuluyor: dil ileri geri değiştirilince
     İngilizceyi tekrar çevirmeye kalkmıyoruz, düğümün aslını geri koyuyoruz. */
  var OZGUN = typeof WeakMap === 'function' ? new WeakMap() : null;
  var izleyici = null;

  /* --- ölçüm değeri taşıyan cümleler ---------------------------------
     Panelin bazı cümleleri kaynakta parça parça duruyor:
       'Açık motorların ayırdığı toplam ' + mb(x) + ', dağıtılabilir ' + ...
     Ekranda bunlar TEK metin düğümüdür ama içindeki sayı her ölçümde
     değişir; sözlüğe sabit anahtar olarak yazılamazlar.

     Bu yüzden sözlükte DELİKLİ kalıplar var: '... {1} ... {2} ...'. Metin
     düğümü hiçbir tam anahtara uymazsa kalıplar deneniyor, delikteki ölçüm
     değeri olduğu gibi taşınıyor. Delikler numaralı: İngilizcede kelime
     sırası değişince değerin hangi boşluğa gideceği belli olsun diye. */
  var KALIPLAR = null;

  function kacir(x) {
    return x.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  function kaliplariKur() {
    KALIPLAR = [];
    for (var k in EN) {
      if (!Object.prototype.hasOwnProperty.call(EN, k)) continue;
      if (k.indexOf('{1}') < 0) continue;
      var parca = k.split(/\{(\d)\}/);          /* metin, no, metin, no, ... */
      var desen = '', sira = [];
      for (var i = 0; i < parca.length; i++) {
        if (i % 2 === 0) desen += kacir(parca[i]);
        else { desen += '([\\s\\S]*?)'; sira.push(parca[i]); }
      }
      KALIPLAR.push({ re: new RegExp('^' + desen + '$'), en: EN[k], sira: sira });
    }
    /* Uzun kalıp önce denensin: kısa bir kalıp uzununun içine oturabilir ve
       yanlış eşleşme sessizce bozuk cümle üretir. */
    KALIPLAR.sort(function (a, b) {
      return b.re.source.length - a.re.source.length;
    });
  }

  /* Deliğe düşen parça da çevrilebilir bir cümle olabilir: bellek balonunda
     "Baştan ayrılan (rezerve): …" tam olarak böyle, koşullu bir parça olarak
     ortaya giriyor. Çevirmezsek İngilizce cümlenin ortasında Türkçe bir
     cümle kalırdı. Derinlik sınırı var: kalıp kendi kendini yakalarsa
     sonsuz döngü olmasın. */
  function icCevir(x, derinlik) {
    if (x == null || derinlik >= 2) return x;
    var oz = String(x).replace(/\s+/g, ' ').trim();
    if (!oz) return x;
    var bas = String(x).match(/^\s*/)[0], son = String(x).match(/\s*$/)[0];
    if (Object.prototype.hasOwnProperty.call(EN, oz)) return bas + EN[oz] + son;
    var k = kalipCevir(oz, derinlik + 1);
    return k === null ? x : bas + k + son;
  }

  function kalipCevir(metin, derinlik) {
    derinlik = derinlik || 0;
    if (!KALIPLAR) kaliplariKur();
    for (var i = 0; i < KALIPLAR.length; i++) {
      var m = KALIPLAR[i].re.exec(metin);
      if (!m) continue;
      var deger = {};
      for (var j = 0; j < KALIPLAR[i].sira.length; j++) {
        deger[KALIPLAR[i].sira[j]] = icCevir(m[j + 1], derinlik);
      }
      return KALIPLAR[i].en.replace(/\{(\d)\}/g, function (t, no) {
        return Object.prototype.hasOwnProperty.call(deger, no) ? deger[no] : t;
      });
    }
    return null;
  }

  function atlanir(d) {
    var p = d.parentNode;
    while (p && p.nodeType === 1) {
      var ad = p.nodeName;
      if (ad === 'SCRIPT' || ad === 'STYLE' || ad === 'TEXTAREA') return true;
      /* Bu ikisini uygula() zaten çeviriyor; iki kez dokunmayalım. */
      if (p.hasAttribute('data-i18n') || p.hasAttribute('data-i18n-html')) return true;
      p = p.parentNode;
    }
    return false;
  }

  function dugumCevir(d) {
    if (!OZGUN || !d || d.nodeType !== 3) return;
    if (!d.nodeValue || !d.nodeValue.trim()) return;
    if (atlanir(d)) return;
    var vardi = OZGUN.has(d);
    var ham = vardi ? OZGUN.get(d) : d.nodeValue;
    if (DIL === 'tr') {
      if (vardi) d.nodeValue = ham;
      return;
    }
    var anahtar = ham.replace(/\s+/g, ' ').trim();
    var karsilik = Object.prototype.hasOwnProperty.call(EN, anahtar)
      ? EN[anahtar] : kalipCevir(anahtar);
    if (karsilik === null || karsilik === undefined) return;
    if (!vardi) OZGUN.set(d, ham);
    /* Baştaki ve sondaki boşluk korunuyor: "Kapat" ile " Kapat " yan yana
       geldiğinde kelimelerin birbirine yapışmaması için. */
    d.nodeValue = ham.match(/^\s*/)[0] + karsilik + ham.match(/\s*$/)[0];
  }

  /* Baloncuk metinleri (title) ve ekran okuyucu etiketleri de kullanıcıya
     görünür. Bunlar metin düğümü değil, bu yüzden ayrı geziliyor. */
  var NITELIKLER = ['title', 'aria-label', 'placeholder'];

  function nitelikCevir(el) {
    if (!OZGUN || !el || el.nodeType !== 1) return;
    for (var i = 0; i < NITELIKLER.length; i++) {
      var ad = NITELIKLER[i];
      if (!el.hasAttribute(ad)) continue;
      /* data-i18n-attr varsa uygula() zaten ilgileniyor. */
      if (el.hasAttribute('data-i18n-attr')) continue;
      var saklaAd = 'i18nDom' + ad.replace(/(^|-)([a-z])/g,
        function (m, a, b) { return b.toUpperCase(); });
      var vardi = Object.prototype.hasOwnProperty.call(el.dataset, saklaAd);
      var ham = vardi ? el.dataset[saklaAd] : el.getAttribute(ad);
      if (DIL === 'tr') {
        if (vardi) el.setAttribute(ad, ham);
        continue;
      }
      var anahtar = String(ham).replace(/\s+/g, ' ').trim();
      var karsilik = Object.prototype.hasOwnProperty.call(EN, anahtar)
        ? EN[anahtar] : kalipCevir(anahtar);
      if (karsilik === null || karsilik === undefined) continue;
      if (!vardi) el.dataset[saklaAd] = ham;
      el.setAttribute(ad, karsilik);
    }
  }

  function agaci(kok) {
    if (!OZGUN || !kok) return;
    if (kok.nodeType === 3) { dugumCevir(kok); return; }
    if (kok.nodeType !== 1 && kok.nodeType !== 9 && kok.nodeType !== 11) return;
    nitelikCevir(kok);
    var els = kok.querySelectorAll ? kok.querySelectorAll('*') : [];
    for (var e = 0; e < els.length; e++) nitelikCevir(els[e]);
    var yur = document.createTreeWalker(kok, NodeFilter.SHOW_TEXT, null, false);
    var yigin = [], d;
    while ((d = yur.nextNode())) yigin.push(d);
    /* Önce toplayıp sonra çevirmek şart: yürürken nodeValue değiştirmek
       bazı tarayıcılarda yürüyücüyü şaşırtıyor. */
    for (var i = 0; i < yigin.length; i++) dugumCevir(yigin[i]);
  }

  function izlemeyeBasla() {
    if (izleyici || !OZGUN || typeof MutationObserver === 'undefined') return;
    if (!document.body) return;
    izleyici = new MutationObserver(function (kayitlar) {
      for (var i = 0; i < kayitlar.length; i++) {
        var ek = kayitlar[i].addedNodes;
        for (var j = 0; j < ek.length; j++) {
          var n = ek[j];
          if (n.nodeType === 3) dugumCevir(n);
          /* uygula() sonunda zaten agaci() geziyor; ikinci kez çağırmak
             beş saniyede bir yeniden çizilen panelde boşa iş demekti. */
          else if (n.nodeType === 1) uygula(n);
        }
      }
    });
    /* characterData izlenmiyor: kendi yazdığımız nodeValue'lar geri
       beslenip sonsuz döngü kurmasın. childList bizim için yeterli —
       panel içeriği innerHTML ile bütün olarak değişiyor. */
    izleyici.observe(document.body, { childList: true, subtree: true });
  }

  function uygula(kok) {
    var k = kok || document;
    uygulaHtml(k);
    k.querySelectorAll('[data-i18n]').forEach(function (el) {
      /* Özgün Türkçe metin bir kez saklanıyor: dil ileri geri
         değiştirildiğinde İngilizceyi tekrar çevirmeye kalkmayalım. */
      /* İÇ BOŞLUKLAR SIKIŞTIRILIR. Ölçülen hata: HTML'de birden çok
         satıra yayılan bir cümlenin textContent'i satır sonlarını ve
         girintileri taşıyor; sözlük anahtarı ise tek boşlukla yazılı.
         İkisi eşleşmediği için ÇOK SATIRLI HER data-i18n çevrilmeden
         kalıyordu — panelin başlık ve açıklama metinlerinin çoğu böyle.
         Daha kötüsü: selftest de sıkıştırarak baktığı için 'karşılığı var'
         diyordu; kontrol, ürünün yaptığından BAŞKA bir şeyi ölçüyordu.
         uygulaHtml() zaten böyle normalleştiriyordu; ikisi artık aynı. */
      if (!el.dataset.i18nSrc) {
        el.dataset.i18nSrc = el.textContent.replace(/\s+/g, ' ').trim();
      }
      el.textContent = t(el.dataset.i18nSrc);
    });
    k.querySelectorAll('[data-i18n-attr]').forEach(function (el) {
      el.dataset.i18nAttr.split(',').forEach(function (ad) {
        ad = ad.trim();
        if (!ad) return;
        var saklaAd = 'i18nAttr' + ad.replace(/(^|-)([a-z])/g,
          function (m, a, b) { return b.toUpperCase(); });
        if (!el.dataset[saklaAd]) el.dataset[saklaAd] = el.getAttribute(ad) || '';
        el.setAttribute(ad, t(el.dataset[saklaAd]));
      });
    });
    agaci(k);
    izlemeyeBasla();
    document.documentElement.lang = DIL;
  }

  function dugmeyiTazele() {
    var b = document.getElementById('lang-txt');
    if (b) b.textContent = DIL === 'tr' ? 'TR' : 'EN';
  }

  function degistir() {
    DIL = DIL === 'tr' ? 'en' : 'tr';
    try { localStorage.setItem(DEPO, DIL); } catch (e) { /* yok say */ }
    dugmeyiTazele();
    uygula();
    /* Kartları JS üretiyor: dil değişince yeniden çizilmeleri şart.
       Sayfa bunu dinlemiyorsa en kötü ihtimalle bir yenilemede düzelir. */
    document.dispatchEvent(new CustomEvent('dbstack:dil', { detail: DIL }));
  }

  window.I18N = { t: t, uygula: uygula, agaci: agaci,
                  dil: function () { return DIL; },
                  degistir: degistir };
  window.t = t;

  document.addEventListener('DOMContentLoaded', function () {
    var d = document.getElementById('lang-toggle');
    if (d) d.addEventListener('click', degistir);
    dugmeyiTazele();
    uygula();
  });
})();
