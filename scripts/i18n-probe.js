/* gateway/html/i18n.js'i tarayıcı olmadan çalıştırır ve t()'yi sorgular.
 *
 * NEDEN VAR: sözlüğün statik taraması, ekranda gerçekten oluşan metni
 * göremiyor. Panel çalışırken metni parçalardan kuruyor — etiket bir
 * şablon deliğinin içinde, sayı dışarıda — ve DOM'a düşen tek metin
 * düğümü ('Sıradaki yedek: in 22 hours') hiçbir kaynak dosyada aynen
 * yazmıyor. Tarayıcı o düğümü {1} sayıp geriye kalan ': ' için "harf yok,
 * çevrilecek bir şey yok" diyordu; ekranda Türkçe kalan metin, denetimin
 * tam da geçtiği yerdeydi.
 *
 * Bu betik ürünün KENDİ motoruna soruyor. selftest beklenen karşılıkları
 * tutuyor, cevabı buradan alıyor.
 *
 * Kullanım:  echo '["metin", ...]' | node scripts/i18n-probe.js [tr|en]
 * Çıktı   :  JSON dizisi, aynı sırada karşılıklar.
 */
'use strict';

const fs = require('fs');
const path = require('path');

const DIL = process.argv[2] === 'tr' ? 'tr' : 'en';
const KAYNAK = path.join(__dirname, '..', 'gateway', 'html', 'i18n.js');

/* DOM yok; i18n.js'in dokunduğu her şeyin en küçük karşılığı. Amaç bir
   tarayıcıyı taklit etmek değil, sözlük motorunu çalıştırabilmek. */
function koy(ad, deger) {
  /* Düz atama yetmiyor: yeni Node sürümlerinde globalThis.navigator
     yalnızca okunabilir bir getter ve atama TypeError atıyor. */
  Object.defineProperty(global, ad, {
    value: deger, writable: true, configurable: true, enumerable: true,
  });
}

koy('localStorage', { getItem: () => DIL, setItem: () => {} });
koy('navigator', { language: DIL === 'tr' ? 'tr-TR' : 'en-US' });
koy('MutationObserver', function () { this.observe = () => {}; });
koy('document', {
  documentElement: {},
  body: null,
  addEventListener: () => {},
  querySelectorAll: () => [],
  getElementById: () => null,
  createTreeWalker: () => ({ nextNode: () => null }),
  dispatchEvent: () => {},
});
koy('window', global);

new Function(fs.readFileSync(KAYNAK, 'utf8'))();

let girdi = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', (d) => { girdi += d; });
process.stdin.on('end', () => {
  let liste;
  try {
    liste = JSON.parse(girdi);
  } catch (e) {
    process.stderr.write('girdi JSON değil: ' + e.message + '\n');
    process.exit(2);
  }
  if (!Array.isArray(liste)) {
    process.stderr.write('girdi bir dizi olmalı\n');
    process.exit(2);
  }
  process.stdout.write(JSON.stringify(liste.map((s) => global.t(s))));
});
