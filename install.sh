#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Цвета и стили
# ============================================================
RED='\033[0;31m';    GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'
CYAN='\033[0;36m';   NC='\033[0m'
BOLD='\033[1m'

# ============================================================
# Баннер
# ============================================================
banner() {
    clear
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════╗"
    echo "║     🛡️  Mobile‑Only VPN Access Installer     ║"
    echo "║        Yandex CDN + Nginx / Caddy           ║"
    echo "╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ============================================================
# Проверка root
# ============================================================
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo -e "${RED}✘ Запустите скрипт от root: sudo bash $0${NC}"
        exit 1
    fi
}

# ============================================================
# Установка зависимостей
# ============================================================
install_deps() {
    echo -e "${BLUE}➤ Проверка зависимостей...${NC}"
    local missing=()
    for pkg in curl python3; do
        if ! command -v $pkg >/dev/null 2>&1; then
            missing+=($pkg)
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}  Устанавливаем: ${missing[*]}${NC}"
        apt-get update -qq && apt-get install -y -qq "${missing[@]}"
    fi
    echo -e "${GREEN}  ✓ Все зависимости готовы${NC}"
}

# ============================================================
# Вопросы пользователю
# ============================================================
ask_questions() {
    echo -e "\n${BOLD}${CYAN}📋 Настройка параметров${NC}\n"

    read -p "🌐 Введите домен вашей VPN‑ноды (например, node.example.com): " DOMAIN
    while [[ -z "$DOMAIN" ]]; do
        read -p "   Домен не может быть пустым. Введите ещё раз: " DOMAIN
    done

    read -p "📧 Введите email администратора (для Let's Encrypt, если используется): " ADMIN_EMAIL
    if [[ -z "$ADMIN_EMAIL" ]]; then
        ADMIN_EMAIL="admin@${DOMAIN#*.}"
        echo -e "${YELLOW}   Использован email по умолчанию: ${ADMIN_EMAIL}${NC}"
    fi

    echo ""
    echo -e "${BOLD}Выберите веб-сервер:${NC}"
    echo "  1) Nginx (уже установлен, будем настраивать)"
    echo "  2) Caddy  (уже установлен, будем настраивать)"
    read -p "Ваш выбор [1/2]: " WEB_CHOICE
    while [[ ! "$WEB_CHOICE" =~ ^[12]$ ]]; do
        read -p "   Пожалуйста, введите 1 или 2: " WEB_CHOICE
    done

    if [[ "$WEB_CHOICE" == "1" ]]; then
        WEB_SERVER="nginx"
    else
        WEB_SERVER="caddy"
    fi

    if [[ "$WEB_SERVER" == "nginx" ]]; then
        echo -e "\n${BOLD}🔒 SSL-сертификат и ключ для origin (CDN → нода)${NC}"
        read -p "   Путь к сертификату [по умолч. /etc/ssl/cdn/origin.crt]: " SSL_CERT
        SSL_CERT="${SSL_CERT:-/etc/ssl/cdn/origin.crt}"
        read -p "   Путь к ключу         [по умолч. /etc/ssl/cdn/origin.key]: " SSL_KEY
        SSL_KEY="${SSL_KEY:-/etc/ssl/cdn/origin.key}"

        mkdir -p "$(dirname "$SSL_CERT")" "$(dirname "$SSL_KEY")"
        if [[ ! -f "$SSL_CERT" || ! -f "$SSL_KEY" ]]; then
            echo -e "${YELLOW}  ⚠ Сертификат/ключ не найдены. Сгенерирую самоподписанный (для теста).${NC}"
            openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
                -keyout "$SSL_KEY" -out "$SSL_CERT" \
                -subj "/CN=${DOMAIN}" 2>/dev/null
            echo -e "${GREEN}  ✓ Самоподписанный сертификат создан${NC}"
        fi
    fi

    echo -e "\n${GREEN}✅ Конфигурация собрана:${NC}"
    echo -e "   Домен:       ${BOLD}${DOMAIN}${NC}"
    echo -e "   Email:       ${BOLD}${ADMIN_EMAIL}${NC}"
    echo -e "   Веб-сервер:  ${BOLD}${WEB_SERVER}${NC}"
    if [[ "$WEB_SERVER" == "nginx" ]]; then
        echo -e "   SSL cert:    ${BOLD}${SSL_CERT}${NC}"
        echo -e "   SSL key:     ${BOLD}${SSL_KEY}${NC}"
    fi
    echo ""
    read -p "Продолжить установку? [Y/n]: " CONFIRM
    if [[ "$CONFIRM" =~ ^[Nn] ]]; then
        echo -e "${RED}Отмена.${NC}"
        exit 0
    fi
}

# ============================================================
# Скрипт обновления мобильных диапазонов
# ============================================================
generate_update_script() {
    local OUTPUT_MODE="$1"
    local DEST="$2"

    cat > "$DEST" << 'INNER_EOF'
#!/bin/bash
MOBILE_ASN=(
    8359 13174 21365 30922 34351 25086 28884 48100 48400 44391
    47241 34456 50952 51143 206867 198552
    3216 16043 16345 42842 49037 49605 50498 57173 44493 47724 48317
    31133 8263 6854 50928 48615 47395 47218 43841 42891 41976
    35298 34552 31268 31213 31208 31205 31195 31163 29648
    25290 25159 24866 20663 20632 12396 202804
    47829 35357 34974 34702 43213 25490 31286 51547 57311 199226
    12958 15378 42437 48092 48190 41330 39374 13116 41704 34879 39927 51570 57629
    201776
    206673 48039 209449
    35816
    205638 214257 202498
    203451 203561
    47204
    31499 31224 31287
    31257 47542
    202173 211234
)

TMP=$(mktemp)
echo "Загружаем префиксы ${#MOBILE_ASN[@]} ASN..."
for ASN in "${MOBILE_ASN[@]}"; do
    echo -n "  AS${ASN}... "
    curl -s --max-time 15 \
        "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${ASN}" | \
        python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    count = 0
    for p in d.get('data', {}).get('prefixes', []):
        prefix = p.get('prefix', '')
        if prefix and ':' not in prefix:
            __OUTPUT_FORMAT__
            count += 1
    print(count, file=sys.stderr)
except: print(0, file=sys.stderr)
" 2>/tmp/asn_count >> "$TMP"
    echo "$(cat /tmp/asn_count) префиксов"
    sleep 0.15
done

sort -u "$TMP" -o __FINAL_FILE__
rm -f "$TMP" /tmp/asn_count
echo "✅ Готово: $(wc -l < __FINAL_FILE__) префиксов"

__RELOAD_CMD__
INNER_EOF

    local FINAL_FILE RELOAD_CMD OUTPUT_FORMAT
    if [[ "$OUTPUT_MODE" == "nginx" ]]; then
        FINAL_FILE="/etc/nginx/mobile-ranges.conf"
        RELOAD_CMD="nginx -t 2>/dev/null && nginx -s reload 2>/dev/null || true"
        OUTPUT_FORMAT="print(prefix + ' 1;')"
    else
        FINAL_FILE="/etc/caddy/mobile-ranges.txt"
        RELOAD_CMD="systemctl reload caddy 2>/dev/null || true"
        OUTPUT_FORMAT="print('        ' + prefix)"
    fi

    mkdir -p "$(dirname "$FINAL_FILE")"

    local ESC_FINAL_FILE ESC_RELOAD_CMD ESC_OUTPUT_FORMAT
    ESC_FINAL_FILE=$(printf '%s' "$FINAL_FILE" | sed -e 's/[&#\]/\\&/g')
    ESC_RELOAD_CMD=$(printf '%s' "$RELOAD_CMD" | sed -e 's/[&#\]/\\&/g')
    ESC_OUTPUT_FORMAT=$(printf '%s' "$OUTPUT_FORMAT" | sed -e 's/[&#\]/\\&/g')

    sed -i "s#__FINAL_FILE__#${ESC_FINAL_FILE}#g" "$DEST"
    sed -i "s#__RELOAD_CMD__#${ESC_RELOAD_CMD}#g" "$DEST"
    sed -i "s#__OUTPUT_FORMAT__#${ESC_OUTPUT_FORMAT}#g" "$DEST"

    chmod +x "$DEST"
}

# ============================================================
# Настройка Nginx
# ============================================================
configure_nginx() {
    echo -e "\n${BLUE}➤ Настройка Nginx...${NC}"

    if ! command -v nginx >/dev/null 2>&1; then
        echo -e "${RED}✘ Nginx не установлен. Установите его (apt-get install nginx) и запустите скрипт заново.${NC}"
        exit 1
    fi

    mkdir -p /etc/nginx/sites-enabled

    generate_update_script "nginx" /usr/local/bin/update-mobile-ranges.sh
    echo -e "${GREEN}  ✓ update-mobile-ranges.sh создан${NC}"

    echo -e "${YELLOW}  Первичная загрузка мобильных диапазонов...${NC}"
    /usr/local/bin/update-mobile-ranges.sh

    cat > /etc/nginx/sites-enabled/default << NGINXEOF
log_format mobile '\$time_local | \$http_x_real_ip | \$is_mobile | \$status | \$request';

geo \$http_x_real_ip \$is_mobile {
    default 0;
    include /etc/nginx/mobile-ranges.conf;
}

map \$request_method \$proxy_method_override {
    default     \$request_method;
    OPTIONS     POST;
}

server {
    listen 80 default_server;
    server_name _;
    location ^~ /.well-known/acme-challenge/ { root /var/www/html; default_type text/plain; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl http2 default_server;
    server_name ${DOMAIN};

    ssl_certificate     ${SSL_CERT};
    ssl_certificate_key ${SSL_KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    server_tokens off;
    client_max_body_size 0;
    client_body_timeout 3600s;
    keepalive_timeout 600s;
    keepalive_requests 10000;
    http2_max_concurrent_streams 256;
    large_client_header_buffers 8 16k;
    access_log /var/log/nginx/mobile.log mobile;

    location ^~ /.well-known/acme-challenge/ { root /var/www/html; default_type text/plain; }
    location = / { return 200 'origin-OK'; default_type text/html; }

    location / {
        if (\$is_mobile = 0) {
            return 403;
        }
        proxy_pass http://127.0.0.1:8003;
        proxy_method \$proxy_method_override;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINXEOF

    echo -e "${GREEN}  ✓ Конфигурация Nginx записана${NC}"

    if nginx -t 2>/dev/null; then
        nginx -s reload
        echo -e "${GREEN}  ✓ Nginx перезагружен${NC}"
    else
        echo -e "${RED}  ✘ Ошибка в конфигурации Nginx. Проверьте вручную.${NC}"
        exit 1
    fi
}

# ============================================================
# Настройка Caddy
# ============================================================
configure_caddy() {
    echo -e "\n${BLUE}➤ Настройка Caddy...${NC}"

    if ! command -v caddy >/dev/null 2>&1; then
        echo -e "${RED}✘ Caddy не установлен. Установите его и запустите скрипт заново.${NC}"
        exit 1
    fi

    mkdir -p /etc/caddy

    generate_update_script "caddy" /usr/local/bin/update-mobile-ranges.sh
    echo -e "${GREEN}  ✓ update-mobile-ranges.sh создан${NC}"

    echo -e "${YELLOW}  Первичная загрузка мобильных диапазонов...${NC}"
    /usr/local/bin/update-mobile-ranges.sh

    PREFIXES=$(cat /etc/caddy/mobile-ranges.txt | tr '\n' ' ')

    cat > /etc/caddy/Caddyfile << CADDYEOF
{
        email ${ADMIN_EMAIL}
        servers {
                protocols h1 h2
                max_header_size 65536
                timeouts {
                        read_body 0
                        read_header 30s
                        write 0
                        idle 10m
                }
                trusted_proxies static 91.231.236.0/24 188.72.110.0/24 188.72.111.0/24
        }
}

${DOMAIN} {
        log
        handle /health {
                header Content-Type "application/json"
                respond \`{"status":"ok","service":"xhttp-origin"}\` 200
        }

        @mobile {
                client_ip ${PREFIXES}
        }

        @nonmobile {
                not client_ip ${PREFIXES}
        }

        handle @mobile {
                reverse_proxy 127.0.0.1:8003 {
                        flush_interval -1
                        header_up Host {host}
                        header_up X-Real-IP {remote_host}
                        transport http {
                                versions 1.1
                                dial_timeout 5s
                                keepalive 120s
                                keepalive_idle_conns 512
                                keepalive_idle_conns_per_host 256
                        }
                }
        }

        handle @nonmobile {
                respond 403
        }

        handle {
                root * /var/www/html
                try_files {path} {path}/ =404
                file_server
        }

        header -Server
}
CADDYEOF

    echo -e "${GREEN}  ✓ Caddyfile записан${NC}"

    if caddy validate --config /etc/caddy/Caddyfile 2>/dev/null; then
        systemctl reload caddy
        echo -e "${GREEN}  ✓ Caddy перезагружен${NC}"
    else
        echo -e "${RED}  ✘ Ошибка в Caddyfile. Проверьте вручную.${NC}"
        exit 1
    fi
}

# ============================================================
# Крон
# ============================================================
setup_cron() {
    echo -e "${BLUE}➤ Настройка автообновления префиксов (cron)...${NC}"
    local CRON_FILE="/etc/cron.d/mobile-ranges"
    echo "0 2 * * * root /usr/local/bin/update-mobile-ranges.sh >> /var/log/mobile-ranges-update.log 2>&1" > "$CRON_FILE"
    chmod 644 "$CRON_FILE"
    echo -e "${GREEN}  ✓ Задание cron добавлено (ежедневно в 02:00)${NC}"
}

# ============================================================
# Финальное сообщение
# ============================================================
finish() {
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║          🎉 Установка завершена!             ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}Полезная информация:${NC}"
    echo -e "  • Домен:         ${CYAN}${DOMAIN}${NC}"
    echo -e "  • Веб-сервер:    ${CYAN}${WEB_SERVER}${NC}"
    if [[ "$WEB_SERVER" == "nginx" ]]; then
        echo -e "  • Лог доступа:   ${CYAN}/var/log/nginx/mobile.log${NC}"
        echo -e "  • Просмотр лога: ${CYAN}tail -f /var/log/nginx/mobile.log${NC}"
    else
        echo -e "  • Лог доступа:   ${CYAN}journalctl -u caddy -f${NC}"
    fi
    echo -e "  • Обновление IP:  ${CYAN}sudo /usr/local/bin/update-mobile-ranges.sh${NC}"
    echo ""
    echo -e "${YELLOW}⚠ Не забудьте:${NC}"
    echo -e "  - На CDN (Яндекс) настроить передачу реального IP в заголовке X-Real-IP"
    echo -e "  - Убедиться, что проксируемый порт 8003 слушает ваш VPN (Xray/XHTTP)"
    echo -e "  - При использовании Caddy поставить SSL-сертификат через CDN или Let's Encrypt"
    echo ""
}

# ============================================================
# Главный поток
# ============================================================
main() {
    banner
    check_root
    install_deps
    ask_questions

    if [[ "$WEB_SERVER" == "nginx" ]]; then
        configure_nginx
    else
        configure_caddy
    fi

    setup_cron
    finish
}

main "$@"
