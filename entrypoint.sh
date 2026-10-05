#!/bin/sh
sleep 1

if [ -f /etc/alpine-release ]; then
    OS="alpine"
else
    OS="other"
fi

lsmod | grep -q '^nf_tables' && NFT_CORE=1 || NFT_CORE=0

if [ "$OS" = "alpine" ]; then
  # если в системе нет модуля nftables или принудительно хотим использовать iptables
  if [ "${IPTABLES:-0}" -eq 1 ] || [ $NFT_CORE -eq 0 ]; then
      # удалить nftables если есть
      apk info -e nftables >/dev/null 2>&1 && apk del nftables >/dev/null 2>&1
      # установить iptables если отсутствуют
      apk info -e iptables >/dev/null 2>&1 || apk add iptables
      # установить iptables-legacy если отсутствует и исправить символьные ссылки
      if ! apk info -e iptables-legacy >/dev/null 2>&1; then
        apk add iptables-legacy
        # IPv4
        rm -f /usr/sbin/iptables /usr/sbin/iptables-save /usr/sbin/iptables-restore
        ln -s /usr/sbin/iptables-legacy         /usr/sbin/iptables
        ln -s /usr/sbin/iptables-legacy-save    /usr/sbin/iptables-save
        ln -s /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore
        # IPv6
        rm -f /usr/sbin/ip6tables /usr/sbin/ip6tables-save /usr/sbin/ip6tables-restore
        ln -s /usr/sbin/ip6tables-legacy         /usr/sbin/ip6tables
        ln -s /usr/sbin/ip6tables-legacy-save    /usr/sbin/ip6tables-save
        ln -s /usr/sbin/ip6tables-legacy-restore /usr/sbin/ip6tables-restore
      fi
  # если в системе есть модуль nftables
  else
      export DISABLE_NFTABLES=0
      # удалить iptables и legacy если есть
      if apk info -e iptables iptables-legacy >/dev/null 2>&1; then
        apk del iptables iptables-legacy >/dev/null 2>&1
      fi
      # установить nftables если отсутствует
      apk info -e nftables >/dev/null 2>&1 || apk add nftables
  fi
fi

# настроить маскарад
if [ "${IPTABLES:-0}" -eq 0 ] && [ $NFT_CORE -eq 1 ]; then
  nft add table ip nat
  nft add chain ip nat postrouting { type nat hook postrouting priority srcnat \; }
  nft add rule ip nat postrouting meta oiftype ether ip daddr != { 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255} masquerade
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

# если не указано имя кастомного конфига, испольузем и актуализируем default
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
    echo "ERROR: Config not found! Checked: $TEMPLATE_FILE and $WORKDIR/$CONFIG. Check container mounts/volume paths."
    exit 1
  fi
fi    

# смена веб панели при замене ссылки на её загрузку
UI_URL_CHECK="$WORKDIR/.ui_url"
LAST_UI_URL=$(cat "$UI_URL_CHECK" 2>/dev/null)
if [[ "$EXTERNAL_UI_URL" != "$LAST_UI_URL" ]]; then
  rm -rf "$WORKDIR/$EXTERNAL_UI_PATH"
  echo "$EXTERNAL_UI_URL" > "$UI_URL_CHECK"
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

PROVIDERS_BLOCK=""
PROVIDERS_LIST=""

add_provider() {
    local name="$1"
    local type="$2"        # file / http
    local source="$3"      # path / url
    local add_header="${4:-false}"

    local header=""
    local interval_block=""
    local source_key="path"

    [[ "$type" == "http" ]] && source_key="url"

    # header только для SUB*
    if [[ "$add_header" == "true" && "$name" != "SRV" ]]; then
        header="
    header:
      x-hwid:
      - $HWID"
    fi

    # interval: для http — период обновления подписки, для file (meow-rs
    # 0.22+) — период перечитывания файла И расписания health-check. Без него
    # file-провайдер загружается один раз и не проверяется по таймеру.
    interval_block="    interval: ${PROVIDER_INTERVAL}"$'\n'

    PROVIDERS_BLOCK="${PROVIDERS_BLOCK}  ${name}:
    type: ${type}
    ${source_key}: \"${source}\"
${interval_block}    health-check:
      enable: ${HEALTH_CHECK_ENABLE}
      url: ${HEALTH_CHECK_URL}
      interval: ${HEALTH_CHECK_INTERVAL}
      timeout: ${HEALTH_CHECK_TIMEOUT}
      lazy: ${HEALTH_CHECK_LAZY}
      expected-status: ${HEALTH_CHECK_EXPECTED_STATUS}${header}
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
# Всё это собирается в один YAML-документ "proxies:".
srv_file="$WORKDIR/srv.yaml"
srv_file_has_content=0
if env | grep -qE '^SRV[0-9]'; then
    srv_body=""
    while IFS='=' read -r name value; do
        case "$name" in
            SRV[0-9]*)
                # Если SRV содержит http(s)-ссылку, автоматически принимаем её как subscription — так же, как SUB1/SUB2/...
                case "$value" in
                    http://*|https://*)
                        add_provider "$name" "http" "$value" true
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
            add_provider "$name" "http" "$value" true
            ;;
    esac
done <<EOF
$(env)
EOF

### VETH
if [ -n "$OTHER_IFACES" ]; then
  # Для дополнительных VETH используем модель multi-WAN Mihomo:
  # отдельная таблица маршрутизации + fwmark, который выставляет сам direct proxy.
  # Это корректно работает для UDP при interface-name.
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

# правила nft для настройки tproxy
nft_rules() {
  TPROXY_PORT=15123
  TPROXY_MARK=0x123
  TPROXY_TABLE=100

 # --- nftables table ---
  nft add table inet tproxy_ci

  # --- divert chain для ускорения TCP ---
  nft "add chain inet tproxy_ci divert {
    type filter hook prerouting priority mangle - 5;
    policy accept;
  }"

  # --- socket transparent (ускоряет established TCP) ---
  nft add rule inet tproxy_ci divert \
    meta l4proto tcp socket transparent 1 \
    meta mark set $TPROXY_MARK \
    accept

  # --- prerouting (mangle, но не слишком рано) ---
  nft "add chain inet tproxy_ci prerouting {
    type filter hook prerouting priority mangle;
    policy accept;
  }"

  # --- исключаем все локальные сервисы и служебные адреса ---
  if ! nft add rule inet tproxy_ci prerouting fib daddr type { local, broadcast, multicast } return 2>/dev/null; then
    # for ros < 7.22
    nft add rule inet tproxy_ci prerouting ip daddr { 0.0.0.0/8, 127.0.0.0/8, 169.254.0.0/16, 224.0.0.0/4, 255.255.255.255, $LOCAL_IPS } return
  fi

  # --- защита от MPTCP ---
  nft add rule inet tproxy_ci prerouting tcp option mptcp exists drop

  # --- TPROXY ---
  nft add rule inet tproxy_ci prerouting \
    iifname \""$FIRST_IFACE"\" \
    meta l4proto { tcp, udp } \
    meta mark set $TPROXY_MARK \
    tproxy ip to 127.0.0.1:$TPROXY_PORT \
    accept

  # --- policy routing ---
  ip rule add fwmark $TPROXY_MARK lookup $TPROXY_TABLE pref 100
  ip route replace local 0.0.0.0/0 dev lo table $TPROXY_TABLE proto static scope host

  # если ядро без IPv6 — просто пропускаем
  [ -f /proc/net/if_inet6 ] || return 0

  # --- TPROXY IPv6 ---
  nft add rule inet tproxy_ci prerouting \
      iifname \""$FIRST_IFACE"\" \
      meta l4proto { tcp, udp } \
      meta mark set $TPROXY_MARK \
      tproxy ip6 to [::1]:$TPROXY_PORT \
      accept

  # --- policy routing IPv6 ---
  ip -6 rule add fwmark $TPROXY_MARK lookup $TPROXY_TABLE pref 100
  ip -6 route replace local ::/0 dev lo table $TPROXY_TABLE
}

# если это шаблон, выполняем преднастройки
if [ "${ENVSUBST:-1}" -eq 1 ]; then
  # AUTO CONFIG tun-in
if grep -Eq '^[[:space:]]*\$TUN_IN_AUTOCONFIG' "$CONFIG_FILE"; then
  if [ "${TUN:-0}" -eq 1 ] || [ $NFT_CORE -eq 0 ]; then
  # meow-rs описывает TUN отдельной секцией верхнего уровня `tun:` (docs/tun.md),
  # а НЕ элементом listeners: - type: tun (такой тип слушателя — жёсткая ошибка).
  # Блок подставляется на колонке 0: он закрывает секцию listeners: и открывает
  # параллельный ключ верхнего уровня — валидный YAML (проверено meow -t).
  # Поддерживаемые поля: enable/device/mtu/inet4-address/auto-route/
  # outbound-interface/dns-hijack/udp-timeout. inet4-address — строка (не список).
  # Поля mihomo (stack/strict-route/auto-redirect/auto-detect-interface/
  # disable-icmp-forwarding) ядро принимает с предупреждением и игнорирует.
  # TUN требует fake-ip DNS (по умолчанию) и root/CAP_NET_ADMIN; в маршруты
  # заворачивается только fake-ip диапазон.
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
  nft_rules
  # tproxy-слушатель: в meow-rs udp: true допустим только вместе с
  # firewall: false — ядро само не ставит правила для UDP TPROXY
  # (маршрутизацию UDP обеспечивают nft-правила выше). Вход называется "tun-in".
  TUN_IN_AUTOCONFIG=$(cat <<EOF
  - name: tun-in
    type: tproxy
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
  echo "Running user scripts: $script"
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
  envsubst < "$TEMPLATE_FILE" > "$WORKDIR/$CONFIG"
fi

CMD_MIHOMO="${@:-"-d $WORKDIR -f $WORKDIR/$CONFIG"}"
mihomo -v
exec mihomo $CMD_MIHOMO || exit 1