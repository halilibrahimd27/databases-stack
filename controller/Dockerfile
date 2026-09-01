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
RUN apk add --no-cache \
        docker-cli \
        docker-cli-compose \
        kubectl \
        tini \
    && adduser -D -u 10001 controller

WORKDIR /app
COPY app.py /app/app.py

# Docker soketine erişim gerektiği için root çalışır (soket root:docker'a ait).
# Dış dünyaya portu yoktur; yalnızca gateway'den, token ile erişilir.
EXPOSE 8000

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["python", "-u", "/app/app.py"]
