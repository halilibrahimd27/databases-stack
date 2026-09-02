# =============================================================================
# databases-stack controller — kontrol düzlemi
# =============================================================================
# Harici Python bağımlılığı YOK (yalnız stdlib). Tek gereksinim docker CLI +
# compose eklentisi; aktivasyon `docker compose --profile X up -d` ile yapılır.
# =============================================================================
FROM python:3.12-alpine

# docker-cli-compose = `docker compose` alt komutu (compose v2 eklentisi).
# kubectl yalnız BACKEND=kubernetes iken kullanılır; imajı şişirmemek için
# alpine'ın paketi tercih edildi.
#
# YEDEKLEME ARAÇLARI (bash + coreutils + findutils + tar) — imajı şişirdiğinin
# farkındayız, sebebi şu: zamanlanmış yedeği artık controller'ın kendisi
# çalıştırıyor, yani scripts/backup.sh bu container'ın içinde koşuyor.
# O betik #!/bin/bash ile başlar ve alpine'da bash YOKTUR; yorumlayıcı
# bulunamayınca betik ilk satırında "not found" ile ölür — üstelik hata
# mesajı betiğin adını gösterdiği için insan eksik olanı betikte arar.
#
# coreutils/findutils/tar de aynı sebeple: betik GNU davranışına bel bağlıyor,
# busybox'ın küçük sürümleri aynı şeyi yapmıyor. En somutu findutils:
# backup.sh yedekleri `find ... -printf '%T@\t...'` ile listeliyor, busybox
# find'da -printf HİÇ YOK ("find: unrecognized: -printf") — list/stats boş
# döner, clean hiçbir dosya silmez, yani saklama süresi sessizce hiç işlemez.
# tar/du/date/awk/sed tarafında da bayrak ve çıktı farkları var. Birkaç MB'ı
# bu tür sessiz yanlışlara yeğliyoruz: yedekte sessiz yanlış, yedeğin hiç
# olmamasından beterdir.
RUN apk add --no-cache \
        # openssl: şifreli yedek AÇMAK ve ALMAK için şart. Panelden ve
        # gecelik zamanlayıcıdan alınan yedekler bu container'da
        # üretiliyor; openssl olmadan şifreleme sessizce devre dışı
        # kalır ve dökümler şifresiz diske yazılır. e2e bunu yakaladı:
        # "controller container'ında openssl YOK — panelden ve gecelik
        # zamanlayıcıdan şifreli yedek ALINAMAZ".
        openssl \n        docker-cli \
        docker-cli-compose \
        kubectl \
        tini \
        bash \
        coreutils \
        findutils \
        tar \
    && adduser -D -u 10001 controller

WORKDIR /app
COPY app.py /app/app.py

# Docker soketine erişim gerektiği için root çalışır (soket root:docker'a ait).
# Dış dünyaya portu yoktur; yalnızca gateway'den, token ile erişilir.
EXPOSE 8000

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["python", "-u", "/app/app.py"]
