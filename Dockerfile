# syntax=docker/dockerfile:1
#
# Образ meow-rs (https://github.com/meow-rs/meow-rs) — drop-in замена mihomo
# в контейнере wiktorbgu/mihomo-mikrotik: тот же entrypoint.sh, та же модель
# шаблонов/envsubst и переменных окружения, но ядром выступает бинарник
# meow-rs, совместимый с конфигами mihomo (переключатели, провайдеры, правила).
#
# Мультиархитектурная сборка (docker buildx --platform linux/amd64,linux/arm64,
# linux/arm/v7). BuildKit передаёт TARGETARCH/TARGETVARIANT, и по ним выбирается
# релизный архив meow-rs — все три архитектуры скачивают готовый бинарник:
#   amd64   -> meow-x86_64-unknown-linux-musl.tar.gz
#   arm64   -> meow-aarch64-unknown-linux-musl.tar.gz
#   arm/v7  -> meow-armv7-unknown-linux-musleabihf.tar.gz (статический, с v0.29.0)
#
# arm/v7 появился в релизах meow-rs с v0.29.0 (upstream PR #744 собирает его в
# том же musl-кросс-тулчейне, что раньше использовался здесь). Раньше образ
# компилировал arm/v7 из исходников, потому что релизов под 32-битный musl не
# было, а единственный armv7-релиз (armv7-unknown-linux-gnueabihf) динамический
# и требует GLIBC_2.28, которой нет в gcompat Alpine на armhf — execve падал с
# "No such file or directory" на существующем файле. Поэтому таргет — строго
# musleabihf: статический бинарник не зависит ни от базы, ни от gcompat, и
# Alpine подходит всем трём архитектурам.
#
# Переменная сборки MEOW_VERSION выбирает версию meow-rs: latest (по умолчанию)
# резолвит новейший релиз через GitHub API для всех трёх архитектур, конкретный
# тег (например v0.29.0) скачивает его архив напрямую.
# ===========================================================================================

ARG MEOW_VERSION=latest

# ---- Stage 1: получение бинарника meow-rs -------------------------------------------------

FROM --platform=$BUILDPLATFORM alpine:latest AS meow
ARG MEOW_VERSION
ARG TARGETARCH
ARG TARGETVARIANT

# Скачивание релиза инструментами базового Alpine — apk add здесь не нужен
# вовсе: busybox wget умеет HTTPS (ssl_client + ca-certificates-bundle уже в
# базе), так что стадия состоит из одного слоя. Стадия всегда идёт на
# архитектуре хоста ($BUILDPLATFORM), поэтому emulation не нужна даже для
# arm/v7. У busybox wget нет --retry, поэтому ретраи (5 попыток с паузой 5 с,
# как раньше у curl) делает fetch(); архив качается в файл и только потом
# распаковывается — обрыв TLS в пайп уронил бы шаг без шанса на повтор.
RUN set -eux; \
    fetch() { \
        i=0; \
        until wget -q -T 30 -O "$2" "$1"; do \
            i=$((i+1)); \
            if [ "$i" -ge 5 ]; then return 1; fi; \
            sleep 5; \
        done; \
    }; \
    case "${TARGETARCH:-amd64}" in \
        amd64) target=x86_64-unknown-linux-musl ;; \
        arm64) target=aarch64-unknown-linux-musl ;; \
        arm) \
            case "${TARGETVARIANT:-v7}" in \
                v7) target=armv7-unknown-linux-musleabihf ;; \
                *) echo "unsupported TARGETVARIANT: ${TARGETVARIANT}" >&2; exit 1 ;; \
            esac ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    if [ "$MEOW_VERSION" = "latest" ]; then \
        fetch https://api.github.com/repos/meow-rs/meow-rs/releases/latest /tmp/rel.json \
            || { echo "failed to fetch release info from GitHub API" >&2; exit 1; }; \
        asset_url=$(grep "browser_download_url" /tmp/rel.json | cut -d '"' -f 4 \
            | grep -- "-${target}\.tar\.gz" | head -n 1); \
        [ -n "$asset_url" ] || { echo "no meow-rs release asset for ${target}" >&2; exit 1; }; \
    else \
        asset_url="https://github.com/meow-rs/meow-rs/releases/download/${MEOW_VERSION}/meow-${MEOW_VERSION}-${target}.tar.gz"; \
    fi; \
    echo "fetching $asset_url"; \
    fetch "$asset_url" /tmp/meow.tar.gz \
        || { echo "download failed after 5 attempts" >&2; exit 1; }; \
    mkdir -p /tmp/meow-extract; \
    tar -xzf /tmp/meow.tar.gz -C /tmp/meow-extract; \
    binary=$(find /tmp/meow-extract -type f -name meow -print -quit); \
    [ -n "$binary" ] || { echo "meow binary not found in the release archive" >&2; exit 1; }; \
    install -m 0755 "$binary" /usr/local/bin/meow; \
    rm -rf /tmp/meow.tar.gz /tmp/meow-extract /tmp/rel.json

# ---- Stage 2: рантайм-слой ----------------------------------------------------------------

FROM alpine:latest AS runtime

ARG TARGETPLATFORM

# Все три архитектуры — musl, база общая. amd64/arm64 получают nftables
# (маршрутизация в ядре) и gcompat; arm/v7 берёт iptables-legacy, потому что
# nftables в Alpine для armhf нет. gcompat на arm/v7 не нужен: бинарник
# статический. --no-cache не оставляет индекса в /var/cache/apk — чистить нечего.
RUN case "$TARGETPLATFORM" in \
    linux/arm64 | linux/amd64) \
    apk add --no-cache tini tzdata gcompat nftables envsubst ca-certificates ;; \
    linux/arm/v7) \
    apk add --no-cache tini tzdata iptables iptables-legacy envsubst ca-certificates ;; \
    *) \
    echo "Unsupported platform: $TARGETPLATFORM" >&2; exit 1 ;; \
    esac

# meow-rs совместим с CLI mihomo, но entrypoint.sh вызывает "mihomo";
# алиас убирает расхождение без правки скрипта. Ссылка и chmod — один слой.
COPY --from=meow /usr/local/bin/meow /usr/local/bin/meow
COPY entrypoint.sh /entrypoint.sh
COPY default_config.yaml /etc/mihomo/template/default_config.yaml
RUN ln -sf /usr/local/bin/meow /usr/local/bin/mihomo && chmod +x /entrypoint.sh

# Логи ядра без ANSI-цветов: tracing-subscriber красит stdout, даже когда тот
# не терминал (docker logs, журнал RouterOS), — проверки TTY у него нет.
# NO_COLOR — стандарт https://no-color.org, его понимает сам fmt-слой
# библиотеки; вернуть цвета можно, задав NO_COLOR="" в env контейнера.
ENV NO_COLOR="1" \
    CONFIG="default_config.yaml" \
    LOG_LEVEL="info" \
    WORKDIR="/etc/mihomo" \
    HEALTH_CHECK_ENABLE="true" \
    HEALTH_CHECK_URL="https://www.gstatic.com/generate_204" \
    HEALTH_CHECK_INTERVAL=300 \
    HEALTH_CHECK_TIMEOUT=5000 \
    HEALTH_CHECK_LAZY="true" \
    HEALTH_CHECK_EXPECTED_STATUS=204 \
    TOLERANCE=10 \
    MIXED_PORT=1080 \
    UI_PORT=9090 \
    EXTERNAL_CONTROLLER_ADDRESS="0.0.0.0" \
    TUN_STACK="system" \
    TUN_INET4_ADDRESS="198.19.0.1/30" \
    TUN_INET6_ADDRESS="fdfe:dcba:9876::1/126" \
    TUN_AUTO_REDIRECT="true" \
    TUN_AUTO_DETECT_INTERFACE="true" \
    TUN_AUTO_ROUTE="true" \
    TUN_DISABLE_ICMP_FORWARDING="true" \
    EXTERNAL_UI_PATH="ui" \
    IPV6="true" \
    IP_VERSION="dual" \
    PROVIDER_INTERVAL=3600 \
    DNS_ENABLE="true" \
    DNS_USE_SYSTEM_HOSTS="true" \
    DNS_CACHE_ALGORITHM="arc" \
    DNS_PREFER_H3="false" \
    DNS_LISTEN="0.0.0.0:53" \
    DNS_ENHANCED_MODE="fake-ip" \
    DNS_FAKE_IP_RANGE="198.18.0.0/15" \
    DNS_FAKE_IP_TTL=1 \
    TCP_CONCURRENT="true" \
    FIND_PROCESS_MODE="off" \
    STORE_SELECTED="true" \
    UNIFIED_DELAY="true" \
    LOADBALANCE_STRATEGY="consistent-hashing"

WORKDIR /etc/mihomo

EXPOSE 1080 9090

# entrypoint.sh сам собирает командную строку ядра: без аргументов это
# -d /etc/mihomo -f /etc/mihomo/<CONFIG>, а при "-t" без своего -f он
# подставляет собранный конфиг (иначе meow ищет "config.yaml" и падает).
# Как и в образе-оригинале, CMD не задан: RouterOS "/container add" без cmd=
# запускает контейнер в рабочем режиме, а аргументы (например "-v" или "-t")
# передаются через cmd= для разовых диагностических запусков.
ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
