# syntax=docker/dockerfile:1
#
# Образ meow-rs (https://github.com/meow-rs/meow-rs) — drop-in замена mihomo
# в контейнере wiktorbgu/mihomo-mikrotik: тот же entrypoint.sh, та же модель
# шаблонов/envsubst и переменных окружения, но ядром выступает релизный бинарник
# meow-rs, совместимый с конфигами mihomo (переключатели, провайдеры, правила).
#
# Мультиархитектурная сборка (docker buildx --platform linux/amd64,linux/arm64,
# linux/arm/v7): BuildKit передаёт TARGETARCH/TARGETVARIANT, по ним выбирается
# release-asset:
#   amd64   -> x86_64-unknown-linux-musl       (статический)
#   arm64   -> aarch64-unknown-linux-musl      (статический)
#   arm/v7  -> armv7-unknown-linux-gnueabihf   (glibc, динамический — база Debian)
# Стейдж fetch выполняется на родной архитектуре хоста (--platform=$BUILDPLATFORM):
# скачивание не зависит от архитектуры, меняется только имя файла.
#
# Переменная сборки MEOW_VERSION выбирает релиз meow-rs: latest (по умолчанию)
# резолвит новейший релиз через GitHub API прямо при сборке, конкретный тег
# (например v0.21.2) пинит точную версию.
# ===========================================================================================

ARG MEOW_VERSION=latest

# ---- Stage 1: скачивание релизного бинарника meow-rs ---------------------------------------

FROM --platform=$BUILDPLATFORM alpine:latest AS fetch
ARG MEOW_VERSION
ARG TARGETARCH
ARG TARGETVARIANT

RUN apk add --no-cache ca-certificates curl \
    && rm -rf /var/cache/apk/*
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
        amd64) target=x86_64-unknown-linux-musl ;; \
        arm64) target=aarch64-unknown-linux-musl ;; \
        arm) \
            case "${TARGETVARIANT:-v7}" in \
                v7) target=armv7-unknown-linux-gnueabihf ;; \
                *) echo "unsupported TARGETARCH/TARGETVARIANT: ${TARGETARCH}/${TARGETVARIANT}" >&2; exit 1 ;; \
            esac ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    if [ "$MEOW_VERSION" = "latest" ]; then \
        asset_url=$(curl -fsSL https://api.github.com/repos/meow-rs/meow-rs/releases/latest \
            | grep "browser_download_url" | cut -d '"' -f 4 \
            | grep -- "-${target}\.tar\.gz" | head -n 1); \
        [ -n "$asset_url" ] || { echo "no meow-rs release asset for ${target}" >&2; exit 1; }; \
    else \
        asset_url="https://github.com/meow-rs/meow-rs/releases/download/${MEOW_VERSION}/meow-${MEOW_VERSION}-${target}.tar.gz"; \
    fi; \
    echo "fetching $asset_url"; \
    curl -fsSL -o /tmp/meow.tar.gz "$asset_url"; \
    mkdir -p /tmp/meow-extract; \
    tar -xzf /tmp/meow.tar.gz -C /tmp/meow-extract; \
    binary=$(find /tmp/meow-extract -type f -name meow -print -quit); \
    [ -n "$binary" ] || { echo "meow binary not found in the release archive" >&2; exit 1; }; \
    install -m 0755 "$binary" /usr/local/bin/meow; \
    rm -rf /tmp/meow.tar.gz /tmp/meow-extract

# ---- Stage 2: рантайм-слой ----------------------------------------------------------------

FROM alpine:latest AS runtime

ARG TARGETPLATFORM

RUN case "$TARGETPLATFORM" in \
    linux/arm64 | linux/amd64) \
    apk add --no-cache tini tzdata gcompat nftables envsubst ca-certificates ;; \
    linux/arm/v7) \
    apk add --no-cache tini tzdata gcompat iptables iptables-legacy envsubst ca-certificates && \
    ln -sf /usr/sbin/iptables-legacy /usr/sbin/iptables && \
    ln -sf /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save && \
    ln -sf /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore && \
    ln -sf /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables && \
    ln -sf /usr/sbin/ip6tables-legacy-save /usr/sbin/ip6tables-save && \
    ln -sf /usr/sbin/ip6tables-legacy-restore /usr/sbin/ip6tables-restore ;; \
    *) \
    echo "Unsupported platform: $TARGETPLATFORM" >&2; exit 1 ;; \
    esac && rm -rf /var/cache/apk/*

# meow-rs совместим с CLI mihomo, но entrypoint.sh вызывает "mihomo";
# алиас убирает расхождение без правки скрипта.
COPY --from=fetch /usr/local/bin/meow /usr/local/bin/meow
RUN ln -sf /usr/local/bin/meow /usr/local/bin/mihomo
COPY entrypoint.sh /entrypoint.sh
COPY default_config.yaml /etc/mihomo/template/default_config.yaml

RUN chmod +x /entrypoint.sh

ENV CONFIG="default_config.yaml" \
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
    KEEP_ALIVE_IDLE=60 \
    KEEP_ALIVE_INTERVAL=30 \
    FIND_PROCESS_MODE="off" \
    STORE_SELECTED="true" \
    UNIFIED_DELAY="true" \
    LOADBALANCE_STRATEGY="consistent-hashing"

WORKDIR /etc/mihomo

EXPOSE 1080 9090

# entrypoint.sh заканчивается на "exec mihomo $CMD_MIHOMO", где
# CMD_MIHOMO="${@:-"-d $WORKDIR -f $WORKDIR/$CONFIG"}" — при пустом CMD
# контейнер стартует с -d /etc/mihomo -f /etc/mihomo/default_config.yaml.
# Как и в образе-оригинале, CMD не задан: RouterOS "/container add" без cmd=
# запускает контейнер в рабочем режиме, а аргументы (например "-v" или "-t")
# передаются через cmd= для разовых диагностических запусков.
ENTRYPOINT ["tini", "--", "/entrypoint.sh"]
