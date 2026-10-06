# syntax=docker/dockerfile:1
#
# Образ meow-rs (https://github.com/meow-rs/meow-rs) — drop-in замена mihomo
# в контейнере wiktorbgu/mihomo-mikrotik: тот же entrypoint.sh, та же модель
# шаблонов/envsubst и переменных окружения, но ядром выступает бинарник
# meow-rs, совместимый с конфигами mihomo (переключатели, провайдеры, правила).
#
# Мультиархитектурная сборка (docker buildx --platform linux/amd64,linux/arm64,
# linux/arm/v7). BuildKit передаёт TARGETARCH/TARGETVARIANT, и способ получения
# бинарника выбирается по ним:
#   amd64   -> релиз meow-rs x86_64-unknown-linux-musl   (скачивается)
#   arm64   -> релиз meow-rs aarch64-unknown-linux-musl  (скачивается)
#   arm/v7  -> СБОРКА ИЗ ИСХОДНИКОВ под armv7-unknown-linux-musleabihf
#
# Почему arm/v7 собирается у нас, а не скачивается: релизов под 32-битный musl
# у meow-rs нет, а единственный armv7-релиз (armv7-unknown-linux-gnueabihf)
# динамический и требует GLIBC_2.28. В Alpine на armhf gcompat этих символов не
# даёт, поэтому execve падал с "No such file or directory" на существующем
# файле. Статический musl-бинарник обеих проблем снимает: он не зависит ни от
# базы, ни от gcompat, и Alpine снова подходит всем трём архитектурам.
#
# Кросс-компиляция arm/v7 идёт на родной архитектуре хоста
# (--platform=$BUILDPLATFORM) тулчейном musl-cross: armv7-unknown-linux-musleabihf-gcc
# со статической musl, sysroot'ом и линкером в комплекте. Тулчейн поставляется
# образом messense/rust-musl-cross, который собран под архитектуру ХОСТА,
# поэтому его тег заканчивается на -amd64 или -arm64; сборка arm/v7 на чужой
# архитектуре хоста требует подставить свой тег в BUILDER_IMAGE.
#
# Переменная сборки MEOW_VERSION выбирает версию meow-rs: latest (по умолчанию)
# для скачиваемых релизов резолвит новейшую через GitHub API, а для arm/v7 берёт
# ветку main; конкретный тег (например v0.22.0) пинит версию в обоих случаях.
# ===========================================================================================

ARG MEOW_VERSION=latest
# База стадии сборки. arm/v7 требует кросс-тулчейна (rustc + musl-gcc + cmake +
# libclang для BoringSSL), amd64/arm64 он не нужен, и CI подставляет alpine,
# чтобы не тянуть лишний образ. Тег musl-cross заканчивается на архитектуру
# хоста: -amd64 или -arm64.
ARG BUILDER_IMAGE=messense/rust-musl-cross:armv7-musleabihf-amd64

# ---- Stage 1: получение бинарника meow-rs -------------------------------------------------

FROM --platform=$BUILDPLATFORM ${BUILDER_IMAGE} AS meow
ARG MEOW_VERSION
ARG TARGETARCH
ARG TARGETVARIANT
# Профиль сборки arm/v7 — по умолчанию ровно как собирает апстрим
# (lto = "fat", codegen-units = 1), чтобы arm/v7 совпадал с официальными
# бинарниками amd64/arm64 и по коду, и по размеру. Флаги оставлены как
# ускорители на случай правок исходников: MEOW_LTO=thin MEOW_CODEGEN_UNITS=16
# срезают сборку примерно на 9% (5m30s -> 4m59s на 4 ядрах), но добавляют к
# бинарнику ~2 МБ (10.3 -> 12.3 МБ), поэтому включать их стоит осознанно.
ARG MEOW_LTO=true
ARG MEOW_CODEGEN_UNITS=1

# curl нужен обеим веткам (скачать релиз / скачать исходники), cmake и clang —
# только arm/v7: BoringSSL собирается из исходников, а его bindgen требует
# libclang. Тулчейн подставляет CC/CXX/линкер/sysroot сам через переменные
# окружения вида *_armv7_unknown_linux_musleabihf.
RUN set -eux; \
    if command -v apk >/dev/null 2>&1; then \
        apk add --no-cache curl ca-certificates; \
    else \
        apt-get update; \
        apt-get install -y --no-install-recommends curl ca-certificates; \
        rm -rf /var/lib/apt/lists/*; \
    fi; \
    if [ "${TARGETARCH:-}" != "arm" ]; then exit 0; fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends cmake clang libclang-dev; \
    rm -rf /var/lib/apt/lists/*

# Сборка arm/v7 из исходников разбита на отдельные шаги намеренно: так кэш
# Docker переживает смену версии meow-rs — пересобирается только шаг сборки,
# скачанные исходники остаются в слое, а реестр крейтов и target/ живут в
# кэш-mount (ниже) и переживают вообще любую инвалидацию слоёв.
ENV BINDGEN_EXTRA_CLANG_ARGS="--target=armv7-unknown-linux-musleabihf --sysroot=${TARGET_HOME} -I${TARGET_C_INCLUDE_PATH}" \
    CARGO_HTTP_LOW_SPEED_LIMIT=0 \
    CARGO_HTTP_TIMEOUT=600 \
    CARGO_NET_RETRY=10 \
    CARGO_PROFILE_RELEASE_LTO=${MEOW_LTO} \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=${MEOW_CODEGEN_UNITS}
# Линковка статической musl-программы идёт с -nodefaultlibs, поэтому libgcc не
# подключается — а его builtin'ы (__sync_add_and_fetch_4 и соседние) нужны
# libstdc++.a, который тянет за собой C++-код BoringSSL/quiche. Отсюда -lgcc.
# Обратная сторона: libgcc определяет часть этих символов и сам, а Rust уже
# тащит свой compiler_builtins, поэтому линкер ругается на дубли — гасим это
# --allow-multiple-definition. +crt-static повторяет то, что выставляет образ
# тулчейна: Dockerfile не разворачивает ENV базового образа, значение нужно
# указать явно.
ENV CARGO_TARGET_ARMV7_UNKNOWN_LINUX_MUSLEABIHF_RUSTFLAGS="-C target-feature=+crt-static -C link-arg=-lgcc -C link-arg=-lgcc_eh -C link-arg=-Wl,--allow-multiple-definition"

RUN set -eux; \
    if [ "${TARGETARCH:-}" != "arm" ]; then \
        echo "TARGETARCH=${TARGETARCH:-} — берём релизный бинарник, тулчейн не нужен"; \
        exit 0; \
    fi; \
    command -v armv7-unknown-linux-musleabihf-gcc >/dev/null 2>&1 || { \
        echo "Для сборки arm/v7 нужен musl-кросс-тулчейн. Передайте образ под архитектуру хоста," >&2; \
        echo "например --build-arg BUILDER_IMAGE=messense/rust-musl-cross:armv7-musleabihf-amd64" >&2; \
        exit 1; \
    }; \
    case "${TARGETVARIANT:-v7}" in \
        v7) ;; *) echo "unsupported TARGETVARIANT: ${TARGETVARIANT}" >&2; exit 1 ;; \
    esac; \
    if [ "$MEOW_VERSION" = "latest" ]; then ref=main; else ref="$MEOW_VERSION"; fi; \
    case "$ref" in \
        v[0-9]*) url="https://codeload.github.com/meow-rs/meow-rs/tar.gz/refs/tags/${ref}" ;; \
        main)   url="https://codeload.github.com/meow-rs/meow-rs/tar.gz/refs/heads/main" ;; \
        *) echo "MEOW_VERSION=${MEOW_VERSION}: ожидается 'latest' или тег вида v0.22.0" >&2; exit 1 ;; \
    esac; \
    echo "building meow-rs ${ref} from source"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 -o /tmp/src.tar.gz "$url"; \
    mkdir -p /src && tar -xzf /tmp/src.tar.gz --strip-components=1 -C /src && rm -f /tmp/src.tar.gz; \
    rm -f /src/rust-toolchain.toml; \
    cd /src

RUN --mount=type=cache,id=meow-registry-armv7,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,id=meow-git-armv7,target=/root/.cargo/git,sharing=locked \
    set -eux; \
    if [ "${TARGETARCH:-}" != "arm" ]; then exit 0; fi; \
    cd /src; \
    cargo fetch --locked; \
# Крейт boring берёт time_t из Rust-libc (на 32-битной цели это i32), а musl в \
    # этом тулчейне объявляет time_t 64-битным, поэтому bindgen видит 64-битную \
    # сигнатуру X509_VERIFY_PARAM_set_time и rustc падает на несовпадении типов. \
    # Затрагивается ровно одно место — X509VerifyParam::set_time, который meow-rs \
    # не вызывает ни разу, — так что приведение безопасно и просто делает вызов \
    # ABI-корректным. \
    # Патчим ВСЕ найденные версии boring, а не первую: реестр лежит в кэш-mount и \
    # копится между сборками, поэтому после сборки другой версии meow-rs в глоб \
    # попадают две директории (например boring-5.1.0 и boring-5.2.0) и проверка \
    # "[ -f $boring ]" на склеенном пути падала бы. sed идемпотентен: уже \
    # пропатченная строка его шаблону не соответствует. \
    patched=0; \
    for f in "${CARGO_HOME:-$HOME/.cargo}"/registry/src/*/boring-*/src/x509/verify.rs; do \
        [ -f "$f" ] || continue; \
        sed -i 's|X509_VERIFY_PARAM_set_time(self\.as_ptr(), time)|X509_VERIFY_PARAM_set_time(self.as_ptr(), time.into())|' "$f"; \
        if grep -q 'X509_VERIFY_PARAM_set_time(self.as_ptr(), time.into())' "$f"; then patched=$((patched + 1)); fi; \
    done; \
    [ "$patched" -gt 0 ] || { echo "исходники крейта boring не найдены в реестре cargo" >&2; exit 1; }

# target/ живёт в кэш-mount, а не в слое: исходники meow-rs меняются на каждом
# коммите ветки main (а MEOW_VERSION=latest именно её и тянет), и слойный кэш
# от этого обнулялся бы целиком — сборка с нуля. В mount'е переживает
# инвалидацию слоёв сам cargo: он по отпечаткам (fingerprint) сам решает, что
# пересобрать, — при смене версии meow-rs пересобираются только крейты meow-* и
# финальная линковка. CARGO_HOME в образе тулчейна — /root/.cargo, поэтому
# mount'ы адресные. Кэш-mount не попадает в образ и в --cache-to: оба бэкенда
# отдают слои; если ваша версия buildx выгружает и mount'ы, тёплая пересборка
# переживает и переезд между раннерами.
RUN --mount=type=cache,id=meow-registry-armv7,target=/root/.cargo/registry,sharing=locked \
    --mount=type=cache,id=meow-git-armv7,target=/root/.cargo/git,sharing=locked \
    --mount=type=cache,id=meow-target-armv7,target=/src/target,sharing=locked \
    set -eux; \
    if [ "${TARGETARCH:-}" != "arm" ]; then exit 0; fi; \
    cd /src; \
    cargo build --release --locked --target armv7-unknown-linux-musleabihf --bin meow; \
    install -m 0755 target/armv7-unknown-linux-musleabihf/release/meow /usr/local/bin/meow; \
    file /usr/local/bin/meow; \
    ldd /usr/local/bin/meow 2>&1 || true

# Скачивание релиза — только для архитектур, которым meow-rs его публикует.
RUN set -eux; \
    if [ "${TARGETARCH:-}" = "arm" ]; then exit 0; fi; \
    case "${TARGETARCH:-amd64}" in \
        amd64) target=x86_64-unknown-linux-musl ;; \
        arm64) target=aarch64-unknown-linux-musl ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    if [ "$MEOW_VERSION" = "latest" ]; then \
        asset_url=$(curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 https://api.github.com/repos/meow-rs/meow-rs/releases/latest \
            | grep "browser_download_url" | cut -d '"' -f 4 \
            | grep -- "-${target}\.tar\.gz" | head -n 1); \
        [ -n "$asset_url" ] || { echo "no meow-rs release asset for ${target}" >&2; exit 1; }; \
    else \
        asset_url="https://github.com/meow-rs/meow-rs/releases/download/${MEOW_VERSION}/meow-${MEOW_VERSION}-${target}.tar.gz"; \
    fi; \
    echo "fetching $asset_url"; \
    curl -fsSL --retry 5 --retry-all-errors --retry-delay 5 -o /tmp/meow.tar.gz "$asset_url"; \
    mkdir -p /tmp/meow-extract; \
    tar -xzf /tmp/meow.tar.gz -C /tmp/meow-extract; \
    binary=$(find /tmp/meow-extract -type f -name meow -print -quit); \
    [ -n "$binary" ] || { echo "meow binary not found in the release archive" >&2; exit 1; }; \
    install -m 0755 "$binary" /usr/local/bin/meow; \
    rm -rf /tmp/meow.tar.gz /tmp/meow-extract

# ---- Stage 2: рантайм-слой ----------------------------------------------------------------

FROM alpine:latest AS runtime

ARG TARGETPLATFORM

# Все три архитектуры — musl, база общая. amd64/arm64 получают nftables
# (маршрутизация в ядре) и gcompat; arm/v7 берёт iptables-legacy, потому что
# nftables в Alpine для armhf нет. gcompat на arm/v7 не нужен: бинарник
# статический.
RUN case "$TARGETPLATFORM" in \
    linux/arm64 | linux/amd64) \
    apk add --no-cache tini tzdata gcompat nftables envsubst ca-certificates && \
    rm -rf /var/cache/apk/* ;; \
    linux/arm/v7) \
    apk add --no-cache tini tzdata iptables iptables-legacy envsubst ca-certificates && \
    rm -rf /var/cache/apk/* ;; \
    *) \
    echo "Unsupported platform: $TARGETPLATFORM" >&2; exit 1 ;; \
    esac

# meow-rs совместим с CLI mihomo, но entrypoint.sh вызывает "mihomo";
# алиас убирает расхождение без правки скрипта.
COPY --from=meow /usr/local/bin/meow /usr/local/bin/meow
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
