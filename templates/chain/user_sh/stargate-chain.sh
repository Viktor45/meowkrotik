#!/bin/sh

# ============================================================================
# STARGATE-CHAIN.SH
# Автоматические цепочки через российские серверы
# Источник: https://raw.githubusercontent.com/Viktor45/meowkrotik/refs/heads/main/templates/chain/stargate-chain.yaml
# Дополнение: https://raw.githubusercontent.com/Viktor45/meowkrotik/refs/heads/main/templates/chain/user_sh/stargate-chain.sh
# ============================================================================

# Работает только со своим шаблоном
if [ "$CONFIG" = "stargate-chain.yaml" ]; then

# Значения по умолчанию, если не заданы переменными окружения
HEALTH_CHECK_URL="${HEALTH_CHECK_URL:-https://www.gstatic.com/generate_204}"
HEALTH_CHECK_EXPECTED_STATUS="${HEALTH_CHECK_EXPECTED_STATUS:-204}"
PROVIDER_INTERVAL="${PROVIDER_INTERVAL:-3600}"

# Блоки провайдеров пересобираем здесь, а не берём из entrypoint.sh:
# так цепочки не зависят от изменений основного скрипта.

PROVIDERS_BLOCK=""
PROVIDERS_LIST=""

# Подписка SUB* с заголовком x-hwid
add_http_provider() {
    name="$1"
    url="$2"
      # meow-rs принимает и список, и скаляр в header: оставляем формат-список mihomo.
    header="
    header:
      x-hwid:
      - $HWID"
    PROVIDERS_BLOCK="${PROVIDERS_BLOCK}  ${name}:
    type: http
    url: \"${url}\"
    interval: ${PROVIDER_INTERVAL}
    health-check:
      enable: true
      url: \"${HEALTH_CHECK_URL}\"
      interval: ${HEALTH_CHECK_INTERVAL}
      timeout: ${HEALTH_CHECK_TIMEOUT}
      lazy: ${HEALTH_CHECK_LAZY}
      expected-status: ${HEALTH_CHECK_EXPECTED_STATUS}${header}
"
    PROVIDERS_LIST="${PROVIDERS_LIST}      - ${name}
"
}

# Цепочка "иностранный сервер → через российский прокси": дубль подписки,
# у которого dialer-proxy указывает на RU_AUTO, а российские узлы отсеяны.
add_http_chain_provider() {
    name="$1"
    url="$2"
    chain_name="${name}-via-ru"
    PROVIDERS_CHAIN_BLOCK="${PROVIDERS_CHAIN_BLOCK}  ${chain_name}:
    type: http
    url: \"${url}\"
    interval: ${PROVIDER_INTERVAL}
    # exclude-filter читается только на уровне провайдера; внутри override:
    # ядро учитывает исключительно dialer-proxy.
    exclude-filter: *exclude_ru
    override:
      dialer-proxy: RU_AUTO
    health-check:
      enable: true
      url: \"${HEALTH_CHECK_URL}\"
      interval: ${HEALTH_CHECK_INTERVAL}
      timeout: ${HEALTH_CHECK_TIMEOUT}
      lazy: ${HEALTH_CHECK_LAZY}
      expected-status: ${HEALTH_CHECK_EXPECTED_STATUS}
"
    PROVIDERS_CHAIN_LIST="${PROVIDERS_CHAIN_LIST}      - ${chain_name}
"
}

# Это наши переменные блоков цепочек для шаблона stargate-chain.yaml
PROVIDERS_CHAIN_BLOCK=""
PROVIDERS_CHAIN_LIST=""

while IFS='=' read -r name value; do
  case "$name" in
    SUB[0-9]*)
        # кавычки в URL экранируются, иначе ломается YAML
      value_clean=$(printf '%s' "$value" | sed 's/"/\\"/g')
      add_http_provider "$name" "$value_clean"
      add_http_chain_provider "$name" "$value_clean"
      ;;
  esac
done << EOF
$(env)
EOF

# Провайдеры SRV/VETH, созданные основным entrypoint.sh
if [ -f "$srv_file" ]; then
add_provider "SRV" "file" "$srv_file"
fi

if [ -f "$veth_file" ]; then
add_provider "VETH" "file" "$veth_file"
fi

# Экспорт для подстановки в stargate-chain.yaml (остальное экспортирует entrypoint.sh)
export PROVIDERS_CHAIN_BLOCK
export PROVIDERS_CHAIN_LIST

fi
