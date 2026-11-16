#!/bin/sh
sleep 1

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

if [ -f /etc/alpine-release ]; then
    OS="alpine"
else
    OS="other"
fi

# Есть ли в ядре модуль nf_tables. На RouterOS /proc/modules недоступен или
# пуст — lsmod ничего не печатает, и ветка считается «nftables нет».
lsmod 2>/dev/null | grep -q '^nf_tables' && NFT_CORE=1 || NFT_CORE=0

# Бэкенд файрвола: nft, если в ядре есть модуль nf_tables и пользователь не
# принудил iptables; иначе — iptables (в ядре без nf_tables nft не работает).
if [ "${IPTABLES:-0}" -eq 1 ] || [ $NFT_CORE -eq 0 ]; then
  FW=iptables
else
  FW=nft
fi
log "Файрвол: $FW (модуль nf_tables в ядре: $NFT_CORE)"

# Пакеты файрвола запечены в образ (nftables + iptables + iptables-legacy):
# доустанавливать их на старте не нужно, сети на роутере может не быть.
# В ветке iptables работаем legacy-бэкендом: nft-бэкенд iptables в ядре без
# nf_tables падает с "can't initialize ip_tables" и не создаёт ни одного
# правила. Ссылки создаются всегда, а не только после установки пакета: если
# iptables-legacy уже был в образе, apk их не создавал, и iptables оставался
# nft-бэкендом — ровно тот случай, из-за которого правил не было.
if [ "$OS" = "alpine" ] && [ "$FW" = "iptables" ]; then
  if [ ! -x /usr/sbin/iptables-legacy ]; then
    apk add --no-cache iptables-legacy >/dev/null 2>&1 || true
  fi
  if [ -x /usr/sbin/iptables-legacy ]; then
    rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore
    ln -s /usr/sbin/iptables-legacy         /usr/sbin/iptables
    ln -s /usr/sbin/iptables-legacy-save    /usr/sbin/iptables-save
    ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore
    rm -f /usr/sbin/ip6tables /usr/sbin/ip6tables-save /usr/sbin/ip6tables-restore
    ln -s /usr/sbin/ip6tables-legacy         /usr/sbin/ip6tables
    ln -s /usr/sbin/ip6tables-legacy-save    /usr/sbin/ip6tables-save
    ln -s /usr/sbin/ip6tables-legacy-restore /usr/sbin/ip6tables-restore
  else
    log "ОШИБКА: iptables-legacy недоступен — перехват трафика невозможен"
  fi
fi

# настроить маскарад
if [ "$FW" = "nft" ]; then
  nft add table ip nat
  nft add chain ip nat postrouting { type nat hook postrouting priority srcnat \; }
  nft add rule ip nat postrouting meta oiftype ether ip daddr != { 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255} masquerade
else
  # legacy-бэкенд не принимает несколько -d в одном правиле ("multiple
  # --destination options not allowed"), поэтому исключения — отдельными
  # правилами с RETURN
  iptables -t nat -A POSTROUTING -d 127.0.0.0/8 -j RETURN
  iptables -t nat -A POSTROUTING -d 169.254.0.0/16 -j RETURN
  iptables -t nat -A POSTROUTING -d 224.0.0.0/4 -j RETURN
  iptables -t nat -A POSTROUTING -d 255.255.255.255/32 -j RETURN
  iptables -t nat -A POSTROUTING -j MASQUERADE
fi

FIRST_IFACE=$(ip -o link show | awk -F': ' '/link\/ether/ {print $2; exit}' | cut -d@ -f1)
OTHER_IFACES=$(ip -o link show | awk -F': ' '/link\/ether/ {print $2}' | cut -d@ -f1)
GATEWAY=$(ip route | awk -v iface="$FIRST_IFACE" '$1=="default" && $0~iface {print $3; exit}')
LOCAL_IPS=$(
  ip -4 -o addr show scope global \
  | awk '
      NR==FNR && /link\/ether/ {
          sub(/@.*/, "", $2)
          iface[$2]=1
          next
      }
      $2 in iface {
          split($4,a,"/")
          print a[1]
      }
    ' <(ip -o link show) - \
  | paste -sd, -
)
# тот же список через пробел — для iptables, где каждый адрес отдельным -d
LOCAL_IPS_LIST=$(echo "$LOCAL_IPS" | tr ',' ' ')

# Адрес контейнера на входящем интерфейсе. Перенаправление (nat DNAT) меняет
# адрес назначения именно на него, и tproxy-слушатель обязан быть привязан к
# тому же адресу: сокет на 127.0.0.1 перенаправленный поток не примет.
TPROXY_IP=$(ip -4 -o addr show scope global dev "$FIRST_IFACE" 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}')
if [ -z "$TPROXY_IP" ]; then
  TPROXY_IP=$(ip -4 -o addr show scope global 2>/dev/null | awk 'NR==1 {split($4,a,"/"); print a[1]}')
fi
if [ -z "$TPROXY_IP" ]; then
  TPROXY_IP="127.0.0.1"
  log "ОШИБКА: у контейнера нет IPv4-адреса — перехват трафика работать не будет"
fi

# удалить ранние main/default for ros = 7.22
ip rule | awk '
/lookup main/ && $1+0 < 32766 {gsub(":","",$1); print $1}
/lookup default/ && $1+0 < 32767 {gsub(":","",$1); print $1}
' | while read prio; do
    ip rule del priority "$prio" 2>/dev/null
done
# гарантировать системные правила
ip rule | grep -q "lookup main" || ip rule add lookup main priority 32766
ip rule | grep -q "lookup default" || ip rule add lookup default priority 32767

TEMPLATE_DIR="$WORKDIR/template"
USER_SH_DIR="$WORKDIR/user_sh"
mkdir -p "$TEMPLATE_DIR" "$USER_SH_DIR"
DEFAULT_CONFIG_FILE="/etc/mihomo/template/default_config.yaml"
TEMPLATE_FILE="$TEMPLATE_DIR/$CONFIG"
BACKUP_PATH="$TEMPLATE_DIR/default_config_old.yaml"

# если не указано имя кастомного конфига, используем и актуализируем default
if [ "$CONFIG" = "default_config.yaml" ]; then
  if [ -f "$TEMPLATE_FILE" ]; then
    if ! diff -q "$DEFAULT_CONFIG_FILE" "$TEMPLATE_FILE" >/dev/null; then
      mv "$TEMPLATE_FILE" "$BACKUP_PATH"
      cp "$DEFAULT_CONFIG_FILE" "$TEMPLATE_FILE"
    fi
  else
    cp "$DEFAULT_CONFIG_FILE" "$TEMPLATE_FILE"
  fi
  CONFIG_FILE=$TEMPLATE_FILE
else
  if [ -f "$TEMPLATE_FILE" ]; then
    # есть заданный шаблон — используем его
    CONFIG_FILE="$TEMPLATE_FILE"
  elif [ -f "$WORKDIR/$CONFIG" ]; then
    # шаблона нет, но есть кастомный конфиг
    CONFIG_FILE="$WORKDIR/$CONFIG"
    ENVSUBST=0
  else
    # нет ни шаблона, ни кастомного конфига
    log "ERROR: Config not found! Checked: $TEMPLATE_FILE and $WORKDIR/$CONFIG. Check container mounts/volume paths."
    exit 1
  fi
fi    

# Панель zashboard запечена в образ (/etc/mihomo/zui) и по умолчанию
# EXTERNAL_UI_PATH указывает на неё: ядро раздаёт её файлы по /ui/. Дефолт
# живёт здесь, а не в Dockerfile ENV, и подставляется только если переменная
# вовсе не задана - пустое значение остаётся пустым и отключает панель (тогда
# по /ui/ отвечает встроенный дашборд meow-rs).
EXTERNAL_UI_PATH="${EXTERNAL_UI_PATH-zui}"
export EXTERNAL_UI_PATH

# Папку панели разворачиваем в рабочий каталог, если её там нет. Случай
# RouterOS: рабочий каталог смонтирован поверх /etc/mihomo
# (/container mounts add dst=/etc/mihomo), и запечённый zui под маунтом
# не виден, а ядро без папки external-ui отдаёт /ui/ как 404 - fallback
# на встроенный дашборд в этом случае нет. Поэтому запасной архив
# /opt/zui.tar.gz лежит вне точки монтирования. Уже существующая папка
# не трогается: пользовательская панель не затирается.
if [ -n "$EXTERNAL_UI_PATH" ] && [ ! -d "$WORKDIR/$EXTERNAL_UI_PATH" ] && [ -f /opt/zui.tar.gz ]; then
  log "Unpacking UI panel into $WORKDIR/$EXTERNAL_UI_PATH"
  mkdir -p "$WORKDIR/$EXTERNAL_UI_PATH"
  tar -xzf /opt/zui.tar.gz -C "$WORKDIR/$EXTERNAL_UI_PATH"
fi

# список DNS-серверов для шаблонов: DNS_NAMESERVERS="1.1.1.1,8.8.8.8,9.9.9.9"
# meow-rs не понимает спец-строку "system" из mihomo - серверы задаются явно,
# а шаблоны получают готовый YAML-блок по строке "  - <ip>" на сервер.
DNS_NAMESERVERS="${DNS_NAMESERVERS:-1.1.1.1,8.8.8.8}"
DNS_NAMESERVERS_LIST=""
for ns in $(echo "$DNS_NAMESERVERS" | tr ',' ' '); do
  [ -n "$ns" ] && DNS_NAMESERVERS_LIST="${DNS_NAMESERVERS_LIST}  - ${ns}
"
done
export DNS_NAMESERVERS_LIST

# генерируем hwid для серверов и подписок с ограничениями по устройствам
HWID_STORE="$WORKDIR/.hwid"
if [ ! -f "$HWID_STORE" ]; then
  cat /proc/sys/kernel/random/uuid | tr -d '-' > "$HWID_STORE"
fi
HWID="${HWID:-$(cat "$HWID_STORE")}"

# Списковые DNS-переменные разворачиваются в YAML-список "  - 'элемент'".
# Разделитель — запятая или | (как в апстриме). Элементы кавычятся одинарными
# кавычками: паттерны fake-ip-filter вида *.lan без кавычек YAML считает
# алиасами и ломает парсинг.
yaml_list() {
    out=""
    for item in $(printf '%s' "$1" | tr ',' '\n' | tr '|' '\n'); do
        [ -n "$item" ] || continue
        q=$(printf '%s' "$item" | sed "s/'/''/g")
        out="${out}  - '${q}'
"
    done
    printf '%s' "$out"
}

# фильтр доменов, которым fake-ip не выдаётся: DNS_FAKE_IP_FILTER="*.lan,*.local"
DNS_FAKE_IP_FILTER=$(yaml_list "${DNS_FAKE_IP_FILTER:-}")
# отдельный резолвер для имён прокси-серверов (mihomo proxy-server-nameserver),
# поддерживает #ИМЯ_ПРОКСИ: DNS_PROXY_SERVER_NAMESERVER="tls://1.1.1.1#SELECTOR"
DNS_PROXY_SERVER_NAMESERVER=$(yaml_list "${DNS_PROXY_SERVER_NAMESERVER:-}")
# bootstrap для зашифрованных upstream с именем хоста; только IP, plain UDP/TCP
DNS_DEFAULT_NAMESERVER=$(yaml_list "${DNS_DEFAULT_NAMESERVER:-}")
export DNS_FAKE_IP_FILTER DNS_PROXY_SERVER_NAMESERVER DNS_DEFAULT_NAMESERVER

PROVIDERS_BLOCK=""
PROVIDERS_LIST=""

# значение переменной с индивидуальным суффиксом провайдера или глобальной
# fallback-переменной: PROVIDER_FILTER_SUB1 -> PROVIDER_FILTER
set_default_var() {
    local name="$1"
    local var="$2"
    local value

    value="$(printenv "${var}_${name}")"
    [ -z "$value" ] && value="$(printenv "$var")"

    printf '%s' "$value"
}

add_provider() {
    local name="$1"
    local type="$2"        # file / http
    local source="$3"      # path / url

    local source_key="path"
    local sub_params=""

    # параметры только для http-провайдеров
    if [ "$type" = "http" ]; then
        source_key="url"
        local filter="$(set_default_var "$name" "PROVIDER_FILTER")"
        local exclude_filter="$(set_default_var "$name" "PROVIDER_EXCLUDE_FILTER")"
        local exclude_type="$(set_default_var "$name" "PROVIDER_EXCLUDE_TYPE")"
        local headers_raw="$(set_default_var "$name" "PROVIDER_HEADER")"

        # свои заголовки запроса: пары "ключ=значение" или "ключ: значение",
        # разделённые | или #, например PROVIDER_HEADER_SUB1="User-Agent=meow"
        local custom_headers=""
        if [ -n "$headers_raw" ]; then
            headers_raw=$(printf '%s' "$headers_raw" | tr '#' '|')
            local OLDIFS=$IFS
            IFS='|'
            for pair in $headers_raw; do
                [ -z "$pair" ] && continue
                case "$pair" in
                    *=*) h_key="${pair%%=*}"; h_val="${pair#*=}" ;;
                    *:*) h_key="${pair%%:*}"; h_val="${pair#*:}" ;;
                    *) continue ;;
                esac
                # Очищаем пробелы по краям (так что можно писать с пробелами вокруг |)
                h_key=$(printf '%s' "$h_key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                h_val=$(printf '%s' "$h_val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//; s/"/\\"/g')
                [ -n "$h_key" ] && [ -n "$h_val" ] && custom_headers="${custom_headers}
      ${h_key}:
      - \"${h_val}\""
            done
            IFS="$OLDIFS"
        fi

        # Системный HWID добавляем только если пользователь не передал свой x-hwid
        local hwid_header=""
        if ! printf '%s' "$headers_raw" | grep -qi "x-hwid"; then
            hwid_header="
      x-hwid:
      - $HWID"
        fi

        sub_params="
    header:${hwid_header}${custom_headers}"

        [ -n "$filter" ] && sub_params="${sub_params}"$'\n'"    filter: \"${filter}\""
        [ -n "$exclude_filter" ] && sub_params="${sub_params}"$'\n'"    exclude-filter: \"${exclude_filter}\""
        [ -n "$exclude_type" ] && sub_params="${sub_params}"$'\n'"    exclude-type: \"${exclude_type}\""
    fi

    # interval: для http — период обновления подписки, для file — период
    # перечитывания файла (без него meow-rs читает file-провайдер один раз).
    # Индивидуальный период — PROVIDER_INTERVAL_<ИМЯ> (например PROVIDER_INTERVAL_SUB1).
    local provider_interval="$(set_default_var "$name" "PROVIDER_INTERVAL")"
    sub_params="
    interval: ${provider_interval}${sub_params}"

    # override: meow-rs признаёт в нём только dialer-proxy (issue #489); прочие
    # ключи апстрима (tfo, mptcp, down/up, skip-cert-verify и т.д.) ядро
    # предупреждает и отбрасывает, поэтому они не генерируются.
    local dialer_proxy="$(set_default_var "$name" "PROVIDER_DIALER_PROXY")"
    [ -n "$dialer_proxy" ] && sub_params="${sub_params}"$'\n'"    override:"$'\n'"      dialer-proxy: \"${dialer_proxy}\""

    # Блок health-check ядро само по таймеру не опрашивает (с 0.26 он лишь
    # хранится), но он используется групповыми проверками url-test/fallback/
    # load-balance и ручным healthcheck через API. Каждое поле можно
    # переопределить для одного провайдера: HEALTH_CHECK_URL_<ИМЯ> и т.д.
    local health_check_enable="$(set_default_var "$name" "HEALTH_CHECK_ENABLE")"
    local health_check_url="$(set_default_var "$name" "HEALTH_CHECK_URL")"
    local health_check_interval="$(set_default_var "$name" "HEALTH_CHECK_INTERVAL")"
    local health_check_timeout="$(set_default_var "$name" "HEALTH_CHECK_TIMEOUT")"
    local health_check_lazy="$(set_default_var "$name" "HEALTH_CHECK_LAZY")"
    local health_check_expected_status="$(set_default_var "$name" "HEALTH_CHECK_EXPECTED_STATUS")"

    PROVIDERS_BLOCK="${PROVIDERS_BLOCK}  ${name}:
    type: ${type}
    ${source_key}: \"${source}\"${sub_params}
    health-check:
      enable: ${health_check_enable}
      url: ${health_check_url}
      interval: ${health_check_interval}
      timeout: ${health_check_timeout}
      lazy: ${health_check_lazy}
      expected-status: ${health_check_expected_status}
"

    PROVIDERS_LIST="${PROVIDERS_LIST}      - ${name}"$'\n'
}


### SRV
# meow-rs умеет читать из file-провайдера ТОЛЬКО YAML (документ с ключом
# proxies или голый список). Строки вида vless://..., ss://... и base64-подборки
# ядро не разбирает, поэтому SRV* должен быть либо ссылкой на Clash-YAML
# подписку (http/https — обрабатывается как http-провайдер), либо YAML-маппингом
# прокси в одну строку, например:
#   SRV1="{name: my-socks, type: socks5, server: 1.2.3.4, port: 1080}"
# Deeplink-схемы happ/v2raytun/incy из апстрима не поддерживаются: в апстриме
# их обрабатывает бинарник hpwnr, а meow-rs молча загрузит из них 0 прокси.
# Всё не-http собирается в один YAML-документ "proxies:".
srv_file="$WORKDIR/srv.yaml"
srv_file_has_content=0
if env | grep -qE '^SRV[0-9]'; then
    srv_body=""
    while IFS='=' read -r name value; do
        case "$name" in
            SRV[0-9]*)
                # Если SRV содержит http(s)-ссылку, автоматически принимаем её как subscription — так же, как SUB1/SUB2/...
                srv_scheme=$(printf '%s' "$value" | sed 's/:.*//' | tr '[:upper:]' '[:lower:]')
                case "$srv_scheme" in
                    http|https)
                        add_provider "$name" "http" "$value"
                        ;;
                    *)
                        # иначе — YAML-маппинг одного прокси (см. комментарий выше)
                        srv_body="${srv_body}  - ${value}
"
                        srv_file_has_content=1
                        ;;
                esac
                ;;
        esac
    done <<EOF
$(env)
EOF

    # Если были обычные (не URL подписок) SRV-записи — подключаем их как file provider
    if [ "$srv_file_has_content" -eq 1 ]; then
        echo "proxies:" > "$srv_file"
        printf '%s' "$srv_body" >> "$srv_file"
        add_provider "SRV" "file" "$srv_file"
    fi
fi

### SUB
while IFS='=' read -r name value; do
    case "$name" in
        SUB[0-9]*)
            add_provider "$name" "http" "$value"
            ;;
    esac
done <<EOF
$(env)
EOF

### VETH
if [ -n "$OTHER_IFACES" ]; then
  # Для дополнительных VETH из mihomo-апстрима: ip rule/route и fwmark под
  # каждый интерфейс настраиваются, но multi-WAN в meow-rs не работает —
  # поля interface-name, ip-version и routing-mark у type: direct молча
  # игнорируются (подробности: LIMITATIONS.md, «direct и multi-WAN»).
  TABLE_BASE=201
  i=0
  veth_file="$WORKDIR/veth.yaml"
  IFACE_COUNT=$(echo "$OTHER_IFACES" | wc -w)

  # ни подписок, ни лишних veth - единственный исходящий путь
  if [ -z "$PROVIDERS_LIST" ] && [ "$IFACE_COUNT" -eq 1 ]; then
    PROVIDERS_LIST="${PROVIDERS_LIST}    proxies:
      - DIRECT"
  elif [ "$IFACE_COUNT" -gt 1 ]; then
    echo "proxies:" > "$veth_file"
    for IFACE in $OTHER_IFACES; do
      [ "$IFACE" = "$FIRST_IFACE" ] && continue

      SRC_CIDR=$(ip route show dev "$IFACE" scope link | awk 'NR==1 {print $1}')
      SRC_IP=$(ip -o -4 addr show dev "$IFACE" | awk 'NR==1 {
          split($4,a,"/")
          print a[1]
      }')

      [ -z "$SRC_CIDR" ] && continue
      [ -z "$SRC_IP" ] && continue

      TABLE=$((TABLE_BASE + i))
      MARK=$TABLE
      RULE_PREF=$((150 + i))
      MARK_HEX=$(printf '0x%x' "$MARK")

      cat >> "$veth_file" <<EOF
- name: $IFACE
  type: direct
  ip-version: $IP_VERSION
  interface-name: $IFACE
  routing-mark: $MARK
EOF

      # Policy routing по mark: именно эту схему использует Mihomo для multi-VETH.
      if ! ip rule show | grep -q "fwmark $MARK_HEX lookup $TABLE"; then
        ip rule add fwmark "$MARK" table "$TABLE" pref "$RULE_PREF"
      fi

      # В таблице обязательно должен быть connected route, иначе gateway может некорректно резолвиться/обрабатываться для отдельного policy table.
      ip route replace "$SRC_CIDR" dev "$IFACE" src "$SRC_IP" table "$TABLE"

      # шлюзом VETH становится соседний контейнер, если он задан переменной
      SAFE_IFACE=$(echo "$IFACE" | tr '-' '_')
      SAFE_IP=$(echo "$SRC_IP" | tr '.' '_')
      VAR_GATEWAY_IP="GATEWAY_${SAFE_IP}"
      VAR_GATEWAY_IFACE="GATEWAY_${SAFE_IFACE}"
      if printenv "$VAR_GATEWAY_IP" >/dev/null; then GATEWAY_VETH=$(printenv "$VAR_GATEWAY_IP"); \
        elif printenv "$VAR_GATEWAY_IFACE" >/dev/null; then GATEWAY_VETH=$(printenv "$VAR_GATEWAY_IFACE"); \
        else GATEWAY_VETH="$GATEWAY"; \
      fi
      ip route replace default via "$GATEWAY_VETH" dev "$IFACE" table "$TABLE"

      i=$((i+1))
    done
    add_provider "VETH" "file" "$veth_file"
  fi
fi

# Правила перехвата LAN-трафика tproxy-слушателем.
#
# mihomo создаёт такие правила сам (sing-tun, auto-redirect). В meow-rs поля
# auto-redirect нет вовсе (warn-dropped), а tproxy-слушатель с firewall: false
# правил не создаёт — собираем их здесь, иначе трафик LAN не перехватывается
# ничем.
#
# Механизм доставки трафика в tproxy-слушатель meow-rs (docs/tproxy-gateway.md):
#   * TCP — nat DNAT. TCP-сокет слушателя у meow-rs НЕ IP_TRANSPARENT (в
#     отличие от mihomo), поэтому mangle TPROXY для TCP не срабатывает; исходный
#     адрес meow восстанавливает через SO_ORIGINAL_DST — это conntrack-NAT,
#     то есть нужен nat DNAT/REDIRECT.
#   * UDP — mangle TPROXY. UDP-сокет у meow-rs IP_TRANSPARENT, исходный адрес
#     приходит в IP_RECVORIGDSTADDR; пакет нужно доставить локально, поэтому
#     дополнительно fwmark + policy routing.
#
# Перенаправление идёт на адрес контейнера ($TPROXY_IP): nat DNAT меняет адрес
# назначения на заданный, и слушатель обязан быть привязан к тому же адресу.
#
# Правила — только IPv4: UDP-путь meow-rs работает на IP_RECVORIGDSTADDR, то
# есть только для IPv4; IPv6-трафик идёт мимо прокси напрямую (как и в ветке
# iptables, где ip6tables в правилах не участвует).

# --- общие параметры перехвата ---
TPROXY_PORT=15123
TPROXY_MARK=0x123
TPROXY_TABLE=100

# Правило, которое не применилось (нет xt_TPROXY/xt_addrtype в ядре), не должно
# ронять остальные: теряется UDP или исключение локальных адресов, но TCP
# (nat DNAT) продолжает работать.
fw_run() {
  fw_err=$("$@" 2>&1) || log "Файрвол: правило не применилось ($*): $(echo "$fw_err" | tr '\n' ' ')"
}

# Исключение локальных адресов из перехвата: трафик к DNS/API/панели самого
# контейнера ушёл бы в прокси по кругу. xt_addrtype есть не в каждом ядре —
# при его отсутствии адреса контейнера перечисляются явно.
iptables_skip_local() {
  if iptables -t "$1" -A "$2" -m addrtype --dst-type LOCAL -j RETURN 2>/dev/null; then
    return 0
  fi
  iptables -t "$1" -A "$2" -d 127.0.0.0/8 -j RETURN
  for fw_ip in $LOCAL_IPS_LIST; do
    iptables -t "$1" -A "$2" -d "$fw_ip" -j RETURN
  done
}

# правила nft для настройки tproxy
nft_rules() {
  nft delete table inet tproxy_ci >/dev/null 2>&1
  nft delete table ip tproxy_nat >/dev/null 2>&1

  # --- nftables table ---
  fw_run nft add table inet tproxy_ci

  # --- divert chain для ускорения TCP ---
  fw_run nft "add chain inet tproxy_ci divert {
    type filter hook prerouting priority mangle - 5;
    policy accept;
  }"

  # --- socket transparent (ускоряет established TCP) ---
  fw_run nft add rule inet tproxy_ci divert \
    meta l4proto tcp socket transparent 1 \
    meta mark set $TPROXY_MARK \
    accept

  # --- prerouting (mangle, но не слишком рано) ---
  fw_run nft "add chain inet tproxy_ci prerouting {
    type filter hook prerouting priority mangle;
    policy accept;
  }"

  # --- исключаем все локальные сервисы и служебные адреса ---
  if ! nft add rule inet tproxy_ci prerouting fib daddr type { local, broadcast, multicast } return 2>/dev/null; then
    # for ros < 7.22
    fw_run nft add rule inet tproxy_ci prerouting ip daddr { 0.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255, $LOCAL_IPS } return
  fi

  # --- защита от MPTCP ---
  fw_run nft add rule inet tproxy_ci prerouting tcp option mptcp exists drop

  # --- UDP прямо на порт слушателя — это бесконечный цикл «прокси → сам себя» ---
  fw_run nft add rule inet tproxy_ci prerouting ip daddr $TPROXY_IP udp dport $TPROXY_PORT drop

  # --- UDP через TPROXY (прозрачный UDP-сокет meow) ---
  fw_run nft add rule inet tproxy_ci prerouting \
    iifname \""$FIRST_IFACE"\" \
    meta l4proto udp \
    meta mark set $TPROXY_MARK \
    tproxy ip to $TPROXY_IP:$TPROXY_PORT \
    accept

  # --- policy routing для UDP (пакет доставляется локально) ---
  ip rule add fwmark $TPROXY_MARK lookup $TPROXY_TABLE pref 100 2>/dev/null || true
  ip route replace local 0.0.0.0/0 dev lo table $TPROXY_TABLE proto static scope host 2>/dev/null || true

  # --- TCP через nat DNAT (SO_ORIGINAL_DST) ---
  fw_run nft add table ip tproxy_nat
  fw_run nft "add chain ip tproxy_nat prerouting {
    type nat hook prerouting priority dstnat;
    policy accept;
  }"
  fw_run nft add rule ip tproxy_nat prerouting fib daddr type local return
  fw_run nft add rule ip tproxy_nat prerouting \
    iifname \""$FIRST_IFACE"\" \
    meta l4proto tcp \
    dnat to $TPROXY_IP:$TPROXY_PORT
}

# правила iptables для настройки tproxy (когда в ядре нет nf_tables)
iptables_rules() {
  # --- nat: TCP через DNAT (SO_ORIGINAL_DST) ---
  iptables -t nat -N MEOW_PREROUTING 2>/dev/null || iptables -t nat -F MEOW_PREROUTING
  iptables_skip_local nat MEOW_PREROUTING
  fw_run iptables -t nat -A MEOW_PREROUTING -i "$FIRST_IFACE" -p tcp -j DNAT --to-destination "$TPROXY_IP:$TPROXY_PORT"
  iptables -t nat -C PREROUTING -j MEOW_PREROUTING 2>/dev/null || iptables -t nat -I PREROUTING 1 -j MEOW_PREROUTING

  # --- mangle: UDP через TPROXY (прозрачный UDP-сокет meow) ---
  iptables -t mangle -N MEOW_PREROUTING 2>/dev/null || iptables -t mangle -F MEOW_PREROUTING
  iptables_skip_local mangle MEOW_PREROUTING
  # UDP прямо на порт слушателя — это бесконечный цикл «прокси → сам себя»
  fw_run iptables -t mangle -A MEOW_PREROUTING -p udp -d "$TPROXY_IP" --dport "$TPROXY_PORT" -j DROP
  fw_run iptables -t mangle -A MEOW_PREROUTING -i "$FIRST_IFACE" -p udp -j TPROXY --on-ip "$TPROXY_IP" --on-port "$TPROXY_PORT" --tproxy-mark "$TPROXY_MARK/$TPROXY_MARK"
  iptables -t mangle -C PREROUTING -j MEOW_PREROUTING 2>/dev/null || iptables -t mangle -I PREROUTING 1 -j MEOW_PREROUTING

  # --- policy routing для UDP (пакет доставляется локально) ---
  ip rule add fwmark "$TPROXY_MARK" lookup "$TPROXY_TABLE" pref 100 2>/dev/null || true
  ip route replace local 0.0.0.0/0 dev lo table "$TPROXY_TABLE" proto static scope host 2>/dev/null || true
}

# если это шаблон, выполняем преднастройки
if [ "${ENVSUBST:-1}" -eq 1 ]; then
  # AUTO CONFIG tun-in
if grep -Eq '^[[:space:]]*\$TUN_IN_AUTOCONFIG' "$CONFIG_FILE"; then
  if [ "${TUN:-0}" -eq 1 ]; then
  # meow-rs описывает TUN отдельной секцией верхнего уровня `tun:` (docs/tun.md),
  # а НЕ элементом listeners: - type: tun (такой тип слушателя — жёсткая ошибка).
  # Блок подставляется на колонке 0: он закрывает секцию listeners: и открывает
  # параллельный ключ верхнего уровня — валидный YAML (проверено meow -t).
  # Поддерживаемые поля: enable/device/mtu/inet4-address/auto-route/
  # outbound-interface/dns-hijack/udp-timeout. inet4-address — строка (не список).
  # Поля mihomo (stack/strict-route/auto-redirect/auto-detect-interface/
  # disable-icmp-forwarding) ядро принимает с предупреждением и игнорирует.
  # TUN требует fake-ip DNS (по умолчанию) и root/CAP_NET_ADMIN. С 0.27
  # auto-route: true — полный перехват: свой трафик контейнера уходит в
  # устройство через policy rules, а транзитный (форвард с роутера)
  # остаётся в главной таблице, откуда в устройство попадает, как и раньше,
  # только fake-ip диапазон. Auto-redirect (перехват транзитного трафика
  # правилами iptables/nft) в meow-rs не реализован, поэтому TUN-режим
  # перехватывает только fake-ip диапазон — это режим по запросу (TUN=1).
  # Имя входа TUN для правил IN-NAME в meow-rs всегда "meow-tun".
  TUN_IN_AUTOCONFIG=$(cat <<EOF
tun:
  enable: true
  device: tun-in
  auto-route: $TUN_AUTO_ROUTE
  inet4-address: $TUN_INET4_ADDRESS
  dns-hijack:
  - any:53
EOF
)
else
  # Прозрачный перехват (tproxy) — одинаков для обоих бэкендов файрвола,
  # различаются только сами правила: nft_rules / iptables_rules.
  if [ "$FW" = "nft" ]; then
    nft_rules
  else
    iptables_rules
  fi
  # tproxy-слушатель: в meow-rs udp: true допустим только вместе с
  # firewall: false — ядро само не ставит правила для UDP TPROXY
  # (маршрутизацию UDP обеспечивают правила выше). Вход называется "tun-in".
  # listen — адрес контейнера на входящем интерфейсе: nat DNAT перенаправляет
  # пакет именно на него, и сокет на 127.0.0.1 такой поток не примет.
  TUN_IN_AUTOCONFIG=$(cat <<EOF
  - name: tun-in
    type: tproxy
    listen: $TPROXY_IP
    port: $TPROXY_PORT
    udp: true
    firewall: false
EOF
)
fi
export TUN_IN_AUTOCONFIG
fi
# конец проверки шаблона
fi

# пользовательские sh-скрипты подключаются (source) и выполняются в текущем shell-процессе с общим окружением
for script in "$USER_SH_DIR"/*.sh; do
  [ -f "$script" ] || continue
  log "Running user scripts: $script"
  . "$script"
done

# экспортируем переменные заданные текущим скриптом для использования в шаблонах конфигурации mihomo
export PROVIDERS_BLOCK
export PROVIDERS_LIST
export HWID

# если это шаблон, заполняем переменными конфиг файл
if [ "${ENVSUBST:-1}" -eq 1 ]; then
  # без единого провайдера секция proxy-providers остаётся пустой, и ядро
  # падает с "invalid type: map, expected a sequence" - говорим, в чём дело.
  if [ -z "$PROVIDERS_LIST" ]; then
    echo "WARNING: no SUB*/SRV* variables set, so no proxy providers were generated;" >&2
    echo "         the kernel will refuse this config. Add at least one SUB<n> (HTTP Clash-YAML" >&2
    echo "         subscription) or SRV<n> (one-line YAML proxy mapping) and restart." >&2
  fi
  # CONFIG может лежать в подкаталоге (area/stargate-area.yaml) — тогда папка
  # рядом с собранным конфигом должна существовать; создаём на всякий случай
  mkdir -p "$WORKDIR/$(dirname "$CONFIG")"
  envsubst < "$TEMPLATE_FILE" > "$WORKDIR/$CONFIG"
fi

# Собираем командную строку ядра.
# Без аргументов — рабочий режим: -d <рабочая папка> -f <собранный конфиг>.
# Если пользователь просит только проверку (-t) и не указал свой -f, добавляем
# собранный конфиг сами: meow по умолчанию ищет "config.yaml" и на -t без -f
# падает с "failed to read config file config.yaml".
if [ "$#" -eq 0 ]; then
    set -- -d "$WORKDIR" -f "$WORKDIR/$CONFIG"
else
    has_config=0
    wants_test=0
    for arg in "$@"; do
        case "$arg" in
            -f|--config|--config=*) has_config=1 ;;
            -t|--test) wants_test=1 ;;
        esac
    done
    if [ "$wants_test" -eq 1 ] && [ "$has_config" -eq 0 ]; then
        set -- -d "$WORKDIR" -f "$WORKDIR/$CONFIG" "$@"
    fi
fi

log "$(mihomo -v)"
exec mihomo "$@" || exit 1