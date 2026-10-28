#!/bin/bash
# =============================================================================
#  Протокол: VLESS + REALITY (обход DPI/ТСПУ)
#  Транспорты: XHTTP (основной) + TCP/Vision (запасной) — оба на одном порту
#  Маскировка: выбирается при установке и проверяется через xray tls ping
#  Режимы: обычный (свежий Xray, отпечаток chrome) и совместимости
#          (Xray 26.7.28, отпечаток edge — для сетей, где теряется длинное
#          TLS-приветствие)
#  После установки сервер сам проверяет себя клиентом Xray (самопроверка)
#
#  Запуск:
#    bash install_xray.sh
# =============================================================================

set -eu

# ── Цвета ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${YELLOW}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
hdr()  {
  echo -e "\n${BLUE}════════════════════════════════════════${NC}"
  echo -e "${BLUE}  $1${NC}"
  echo -e "${BLUE}════════════════════════════════════════${NC}"
}

# ── Пути ──────────────────────────────────────────────────────────────────────
XRAY_CFG="/usr/local/etc/xray/config.json"
KEYS_FILE="/usr/local/etc/xray/.keys"
LINK_LIB="/usr/local/lib/xray_link.sh"
BACKUP_DIR="/usr/local/etc/xray/backups"
INSTALLER_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# Основная версия Xray (21.10.2026). Срочное исправление безопасности:
# из встроенного списка корневых сертификатов убраны скомпрометированные.
# Сервер новее 26.9.8 пускает только клиентов с постквантовым TLS-приветствием
# (отпечатки chrome, firefox, safari) — оно ~1,8 КБ и уходит двумя пакетами.
XRAY_PIN="v26.10.21"

# Режим совместимости: последняя версия, которая пускает и отпечаток edge.
# Его приветствие ~0,5 КБ и помещается в один пакет. Нужен в сетях, где второй
# пакет большого приветствия теряется (часть мобильных операторов РФ: Xray #7220,
# #7259, LxBox #142). Минус: нет осенних исправлений Xray.
XRAY_COMPAT="v26.7.28"

# Кандидаты для маскировки. Проверены 2026-10-28: TLS 1.3, HTTP/2 (ALPN),
# X25519MLKEM768, нет в реестре блокировок, без редиректа на чужой домен.
# Скрипт перепроверяет их с сервера и берёт случайный из рабочих —
# чтобы все, кто ставит этот скрипт, не светились одним и тем же SNI.
TARGET_CANDIDATES=(www.mozilla.org www.kernel.org www.python.org www.oracle.com www.sony.com www.ikea.com)

# ── 1. Предстартовые проверки ─────────────────────────────────────────────────
hdr "ПРЕДСТАРТОВЫЕ ПРОВЕРКИ"

[ "$EUID" -ne 0 ] && err "Запустите от root: sudo bash $0"
ok "Root-права подтверждены"

ARCH=$(uname -m)
[[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]] && \
  err "Неподдерживаемая архитектура: $ARCH (нужна x86_64 или aarch64)"
ok "Архитектура: $ARCH"

info "Определяем IP сервера..."
SERVER_IP=$(curl -4 -s --max-time 10 https://ifconfig.me 2>/dev/null || \
            curl -4 -s --max-time 10 https://icanhazip.com 2>/dev/null || true)
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(hostname -I | awk '{print $1}')
  [ -z "$SERVER_IP" ] && err "Не удалось определить IP сервера"
  info "Внешний IP не определён, используется локальный: $SERVER_IP"
  info "VLESS-ссылки будут работать только внутри локальной сети"
else
  ok "IP сервера: $SERVER_IP"
fi

# ── 2. Выбор версии Xray ──────────────────────────────────────────────────────
hdr "ВЕРСИЯ XRAY"

echo ""
echo -e "  ${CYAN}1${NC} — $XRAY_PIN (рекомендуется)"
echo -e "      Свежая версия с исправлением безопасности. Ссылки с отпечатком chrome."
echo -e "  ${CYAN}2${NC} — $XRAY_COMPAT, режим совместимости"
echo -e "      Если в вашей сети (чаще мобильной) подключение висит, а диагностика"
echo -e "      показывает «failed to read client hello». Ссылки с отпечатком edge:"
echo -e "      его TLS-приветствие короче и помещается в один пакет."
echo -e "      Минус: старая версия, без осенних исправлений Xray."
echo ""
echo -e "  Клиенты: v2rayN, v2rayNG, Happ на ядре Xray 26.3.27 или новее. NekoBox,"
echo -e "  Hiddify, Throne и Karing (ядро sing-box) не подключатся ни в одном режиме."
echo ""
read -p "Выберите версию (Enter = 1): " VER_CHOICE < /dev/tty
VER_CHOICE=${VER_CHOICE:-1}

if [[ "$VER_CHOICE" == "2" ]]; then
  XRAY_VERSION="$XRAY_COMPAT"
  FP="edge"
  ok "Версия: $XRAY_VERSION (совместимость, отпечаток edge)"
else
  XRAY_VERSION="$XRAY_PIN"
  FP="chrome"
  ok "Версия: $XRAY_VERSION (отпечаток chrome)"
fi

# ── 3. Выбор порта ────────────────────────────────────────────────────────────
hdr "ВЫБОР ПОРТА"

echo ""
echo -e "  ${CYAN}443${NC}  — стандартный HTTPS (рекомендуется)"
echo -e "  ${CYAN}8443${NC} — альтернативный (если 443 занят)"
echo -e "  ${CYAN}2053${NC} — Cloudflare-стиль"
echo ""
echo -e "  ${YELLOW}Примечание:${NC} у части домашних провайдеров ограничение числа"
echo -e "  соединений действует только на 443. Но разработчики Xray предупреждают:"
echo -e "  нестандартный порт выдаёт сервер. Без причины не меняйте."
echo ""
read -p "Введите порт (Enter = 443): " VLESS_PORT < /dev/tty
VLESS_PORT=${VLESS_PORT:-443}

if ! [[ "$VLESS_PORT" =~ ^[0-9]+$ ]] || (( VLESS_PORT < 1 || VLESS_PORT > 65535 )); then
  VLESS_PORT=443
fi
ok "Порт: $VLESS_PORT"

# ── 4. Установка зависимостей ─────────────────────────────────────────────────
hdr "УСТАНОВКА ЗАВИСИМОСТЕЙ"

apt-get update -qq
apt-get install -y -qq curl jq qrencode nginx ufw fail2ban openssl
ok "Зависимости установлены"

# ── 5. UFW ────────────────────────────────────────────────────────────────────
hdr "НАСТРОЙКА FIREWALL (UFW)"

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment "SSH"
ufw allow 80/tcp    comment "HTTP"
ufw allow "$VLESS_PORT/tcp" comment "VLESS/Reality"
ufw --force enable

ok "UFW настроен (открыты: 22, 80, $VLESS_PORT/tcp)"

# ── 6. Fail2Ban ───────────────────────────────────────────────────────────────
hdr "НАСТРОЙКА FAIL2BAN"

# На Debian 12 без rsyslog файла auth.log нет — тогда читаем журнал systemd
if [ -f /var/log/auth.log ]; then
  F2B_SOURCE="logpath  = /var/log/auth.log"
else
  F2B_SOURCE="backend  = systemd"
fi

cat > /etc/fail2ban/jail.d/xray.conf << EOF
[sshd]
enabled  = true
port     = 22
filter   = sshd
$F2B_SOURCE
maxretry = 3
bantime  = 3600
EOF

systemctl enable fail2ban --quiet || true
if systemctl restart fail2ban; then
  ok "Fail2Ban запущен (SSH: макс 3 попытки, бан 1 час)"
else
  warn "Fail2Ban не запустился — на работу VPN это не влияет"
fi

# ── 7. BBR ────────────────────────────────────────────────────────────────────
hdr "TCP BBR"

if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
  ok "BBR уже включён"
else
  grep -q 'tcp_congestion_control=bbr' /etc/sysctl.conf || {
    echo "net.core.default_qdisc=fq"           >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  }
  sysctl -p -q >/dev/null 2>&1 || true
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    ok "BBR включён"
  else
    warn "BBR включить не удалось (ограничение хостинга) — не критично"
  fi
fi

# ── 8. Nginx (порт 80 — сервер выглядит как обычный сайт) ────────────────────
hdr "NGINX (легенда прикрытия)"

# Проверяем, не занят ли порт 80 чем-то кроме nginx
if ss -tlnp | grep ':80 ' | grep -qv nginx; then
  info "Порт 80 занят другим процессом. Nginx может не запуститься."
  read -p "Перезаписать конфиг nginx и перезапустить? (y/n, Enter = y): " NGINX_CONFIRM < /dev/tty
  NGINX_CONFIRM=${NGINX_CONFIRM:-y}
  [[ "$NGINX_CONFIRM" != "y" && "$NGINX_CONFIRM" != "Y" ]] && {
    info "Пропускаем настройку Nginx"
    SKIP_NGINX=1
  }
fi

if [[ "${SKIP_NGINX:-0}" != "1" ]]; then
  mkdir -p /var/www/html

  cat > /var/www/html/index.html << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Welcome</title>
  <style>
    body { font-family: -apple-system, sans-serif; max-width: 600px;
           margin: 120px auto; text-align: center; color: #333; }
    h1   { color: #0078d4; font-weight: 300; }
    p    { color: #666; }
  </style>
</head>
<body>
  <h1>Welcome</h1>
  <p>The server is up and running.</p>
</body>
</html>
EOF

  cat > /etc/nginx/sites-available/default << 'NGINXCFG'
server {
    listen 80 default_server;
    server_name _;
    root /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }
}
NGINXCFG

  nginx -t -q
  systemctl enable nginx --quiet
  systemctl restart nginx
  ok "Nginx запущен на порту 80"
fi

# ── 9. Установка Xray-core ────────────────────────────────────────────────────
hdr "УСТАНОВКА XRAY-CORE"

# -f: поставить выбранную версию, даже если сейчас стоит другая.
# --logrotate: ротацию логов настраивает сам установщик — с октября 2026
# он просит не заводить отдельных задач ротации (иначе возможны проблемы с правами).
bash -c "$(curl -4 -fL "$INSTALLER_URL")" @ install --version "$XRAY_VERSION" -f --logrotate 04:00:00 || true

command -v xray &>/dev/null || err "Xray не установился, проверьте подключение к интернету"
XRAY_VER=$(xray version 2>&1 | head -1 || true)
ok "$XRAY_VER"

# ── 10. Библиотека для утилит ─────────────────────────────────────────────────
hdr "БИБЛИОТЕКА УТИЛИТ"

mkdir -p /usr/local/lib

cat > "$LINK_LIB" << 'LINKLIB'
#!/bin/bash
# =============================================================================
#  Общая библиотека для утилит Xray
#  Использование: source /usr/local/lib/xray_link.sh
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

XRAY_CFG="/usr/local/etc/xray/config.json"
XRAY_KEYS="/usr/local/etc/xray/.keys"

# Настройки XHTTP, которые сервер «спускает» клиенту через параметр extra.
# maxConnections 3 — под правило ТСПУ «больше 3 TLS-соединений к одному SNI».
# Остальное — стандартные значения Xray: при заданном extra они не подставляются сами.
XHTTP_EXTRA='{"xmux":{"maxConnections":3,"hMaxRequestTimes":"600-900","hMaxReusableSecs":"1800-3000"}}'

uri() { jq -rn --arg s "$1" '$s|@uri'; }

# Отпечаток TLS для ссылок: chrome (обычный режим) или edge (режим совместимости)
get_fp() {
  local fp
  fp=$(awk '/^fp:/ {print $2}' "$XRAY_KEYS" 2>/dev/null || true)
  echo "${fp:-chrome}"
}

# Права на конфиг по правилам установщика Xray (с октября 2026): root:xray 640 —
# служба читает, посторонние нет. Если пользователя xray нет — по-старому, 644.
secure_cfg() {
  if id xray >/dev/null 2>&1; then
    chown root:xray "$1" && chmod 640 "$1"
  else
    chmod 644 "$1"
  fi
}

# Служба работает от пользователя xray, а установщик (с октября 2026) больше
# не создаёт файлы логов заранее. Проверка конфига от root создаёт их от root —
# и служба потом не может в них писать и не стартует. Возвращаем логи xray.
fix_log_owner() {
  if id xray >/dev/null 2>&1 && [ -d /var/log/xray ]; then
    chown -R xray:xray /var/log/xray 2>/dev/null || true
  fi
}

# Проверка конфига: test_cfg <файл>. Возвращает 0, если Xray его принимает.
test_cfg() {
  local rc=0
  xray run -test -c "$1" >/dev/null 2>&1 || rc=1
  fix_log_owner
  return $rc
}

server_ip() {
  local ip
  ip=$(timeout 5 curl -4 -s https://ifconfig.me 2>/dev/null || \
       timeout 5 curl -4 -s https://icanhazip.com 2>/dev/null || true)
  [ -z "$ip" ] && ip=$(hostname -I | awk '{print $1}')
  if [ -z "$ip" ]; then
    echo -e "${RED}Не удалось определить IP сервера${NC}" >&2
    return 1
  fi
  echo "$ip"
}

# Проверка сайта для маскировки: check_target <домен>
# Возвращает 0, если подходит. TARGET_WHY — причина отказа,
# TARGET_PQ=1 — сайт поддерживает постквантовый обмен X25519MLKEM768.
check_target() {
  local d="$1" ip4 out grp sans code loc lhost ver
  TARGET_WHY=""; TARGET_PQ=0

  # До 26.9.8 сертификат microsoft не влезает в буфер REALITY (Xray #6356)
  if [[ "$d" == *microsoft.com ]]; then
    ver=$(xray version 2>/dev/null | awk 'NR==1 {print $2}')
    if [ "$(printf '%s\n' "${ver:-0}" 26.9.8 | sort -V | head -1)" != "26.9.8" ]; then
      TARGET_WHY="на Xray ${ver:-?} ломает REALITY (баг #6356)"
      return 1
    fi
  fi

  # Проверяем по IPv4: на хостингах с битым IPv6 иначе завалятся все кандидаты
  ip4=$(getent ahostsv4 "$d" 2>/dev/null | awk 'NR==1 {print $1}')
  if [ -z "$ip4" ]; then TARGET_WHY="домен не резолвится"; return 1; fi

  out=$(timeout 20 xray tls ping -ip "$ip4" "$d" 2>&1 | sed -n '/Pinging with SNI/,$p')
  echo "$out" | grep -q "Handshake succeeded" || { TARGET_WHY="нет TLS-рукопожатия"; return 1; }
  echo "$out" | grep -q "TLS 1.3"             || { TARGET_WHY="нет TLS 1.3"; return 1; }

  # REALITY прячет ключ в X25519: сайт с другим обменом (например P-256)
  # отвечает HelloRetryRequest, и подключения не работают (Xray #6861)
  grp=$(echo "$out" | sed -n 's/.*Post-Quantum key exchange:[[:space:]]*[a-z]*[[:space:]]*(\(.*\)).*/\1/p' | head -1)
  case "$grp" in
    X25519MLKEM768) TARGET_PQ=1 ;;
    X25519)         TARGET_PQ=0 ;;
    *) TARGET_WHY="обмен ключами ${grp:-неизвестен}, а нужен X25519"; return 1 ;;
  esac

  sans=" $(echo "$out" | grep "allowed domains" | sed 's/.*\[//; s/\].*//') "
  if [[ "$sans" != *" $d "* && "$sans" != *" *.${d#*.} "* ]]; then
    TARGET_WHY="домена нет в сертификате"; return 1
  fi

  if curl -V 2>/dev/null | grep -q HTTP2; then
    code=$(curl -4 -s -o /dev/null --http2 -w '%{http_version}' --max-time 10 "https://$d/" 2>/dev/null || true)
    [[ "$code" == "2" ]] || { TARGET_WHY="нет HTTP/2"; return 1; }
  fi

  loc=$(curl -4 -sI --max-time 10 "https://$d/" 2>/dev/null | \
        awk 'tolower($1)=="location:" {print $2; exit}' | tr -d '\r' || true)
  if [[ "$loc" == http* ]]; then
    lhost=$(echo "$loc" | awk -F/ '{print tolower($3)}')
    [[ "$lhost" == "$d" ]] || { TARGET_WHY="уводит на $lhost"; return 1; }
  fi

  return 0
}

# Ссылка пользователя: gen_link <email> <xhttp|vision> <ip>
gen_link() {
  local email="$1" kind="$2" ip="$3"
  local uuid port sni pbk sid fp xpath base

  uuid=$(jq -r --arg e "$email" \
    '.inbounds[] | select(.tag=="vless-in") | .settings.clients[] | select(.email==$e) | .id' \
    "$XRAY_CFG" 2>/dev/null)
  if [ -z "$uuid" ]; then
    echo -e "${RED}Пользователь '$email' не найден${NC}" >&2
    return 1
  fi

  port=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .port' "$XRAY_CFG")
  sni=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .streamSettings.realitySettings.serverNames[0]' "$XRAY_CFG")
  pbk=$(awk '/^PublicKey:/ {print $2}' "$XRAY_KEYS")
  sid=$(awk '/^shortsid:/ {print $2}' "$XRAY_KEYS")
  fp=$(get_fp)

  base="vless://${uuid}@${ip}:${port}?encryption=none&security=reality&sni=${sni}&fp=${fp}&pbk=${pbk}&sid=${sid}"

  if [[ "$kind" == "vision" ]]; then
    echo "${base}&type=tcp&flow=xtls-rprx-vision#${email}-vision"
  else
    xpath=$(jq -r '.inbounds[] | select(.tag=="xhttp-in") | .streamSettings.xhttpSettings.path' "$XRAY_CFG")
    echo "${base}&type=xhttp&path=$(uri "$xpath")&mode=auto&extra=$(uri "$XHTTP_EXTRA")#${email}-xhttp"
  fi
}

# Обе ссылки пользователя и QR-коды: show_links <email>
show_links() {
  local email="$1" ip x v answer
  ip=$(server_ip) || return 1
  x=$(gen_link "$email" xhttp "$ip") || return 1
  v=$(gen_link "$email" vision "$ip") || return 1

  echo -e "${GREEN}Основная — XHTTP${NC} (не больше 3 соединений, как у браузера):"
  echo "$x"
  echo ""
  echo -e "${YELLOW}Запасная — Vision${NC} (если XHTTP не подключается; быстрее на больших загрузках):"
  echo "$v"
  echo ""
  echo -e "${GREEN}QR-код основной ссылки (XHTTP):${NC}"
  echo "$x" | qrencode -t ansiutf8
  echo ""
  read -p "Показать QR-код запасной ссылки (Vision)? (y/N): " answer < /dev/tty || answer=""
  if [[ "$answer" == "y" || "$answer" == "Y" ]]; then
    echo ""
    echo "$v" | qrencode -t ansiutf8
  fi
  echo ""
}

# Список пользователей в массив emails
load_emails() {
  mapfile -t emails < <(jq -r '.inbounds[] | select(.tag=="vless-in") | .settings.clients[].email' \
                        "$XRAY_CFG" 2>/dev/null)
}

print_emails() {
  local i marker
  for i in "${!emails[@]}"; do
    marker=""
    [[ "${emails[$i]}" == "main" ]] && marker=" ${YELLOW}(основной)${NC}"
    echo -e "  $((i+1)). ${emails[$i]}$marker"
  done
}

# Самопроверка: клиент Xray на самом сервере подключается к себе через 127.0.0.1
# по обеим ссылкам (Vision и XHTTP), с тем же отпечатком, что в ссылках.
# Ловит неподходящий сайт маскировки, сломанный конфиг и несовместимость версий
# (например Xray #7243: на v26.10.21 часть сайтов маскировки перестала работать).
# Возвращает 0, если работают оба варианта. Итог — в SELFTEST_RESULT.
selftest() {
  local port uuid sni pbk sid xpath fp kind label sp ss flow code p1="" p2="" rc=0
  port=$(jq -r '.inbounds[]|select(.tag=="vless-in")|.port' "$XRAY_CFG")
  uuid=$(jq -r '.inbounds[]|select(.tag=="vless-in")|.settings.clients[]|select(.email=="main")|.id' "$XRAY_CFG")
  sni=$(jq -r '.inbounds[]|select(.tag=="vless-in")|.streamSettings.realitySettings.serverNames[0]' "$XRAY_CFG")
  xpath=$(jq -r '.inbounds[]|select(.tag=="xhttp-in")|.streamSettings.xhttpSettings.path' "$XRAY_CFG")
  pbk=$(awk '/^PublicKey:/ {print $2}' "$XRAY_KEYS")
  sid=$(awk '/^shortsid:/ {print $2}' "$XRAY_KEYS")
  fp=$(get_fp)
  SELFTEST_RESULT=""

  for kind in vision xhttp; do
    if [ "$kind" = vision ]; then
      sp=39101; flow="xtls-rprx-vision"; ss='{"network":"tcp"}'
    else
      sp=39102; flow=""
      ss=$(jq -nc --arg p "$xpath" --argjson e "$XHTTP_EXTRA" \
             '{network:"xhttp",xhttpSettings:{path:$p,mode:"auto",extra:$e}}')
    fi
    jq -n --argjson sp "$sp" --argjson port "$port" --arg id "$uuid" --arg flow "$flow" \
          --arg sni "$sni" --arg fp "$fp" --arg pbk "$pbk" --arg sid "$sid" --argjson ss "$ss" '{
      log: {loglevel: "warning"},
      inbounds: [{listen: "127.0.0.1", port: $sp, protocol: "socks"}],
      outbounds: [{protocol: "vless",
        settings: {address: "127.0.0.1", port: $port, id: $id, flow: $flow, encryption: "none"},
        streamSettings: ($ss + {security: "reality",
          realitySettings: {serverName: $sni, fingerprint: $fp, password: $pbk, shortId: $sid}})}]
    }' > "/tmp/xselftest_$kind.json"
    xray run -c "/tmp/xselftest_$kind.json" > "/tmp/xselftest_$kind.log" 2>&1 &
    if [ "$kind" = vision ]; then p1=$!; else p2=$!; fi
  done
  sleep 2

  for kind in vision xhttp; do
    if [ "$kind" = vision ]; then sp=39101; label="Vision"; else sp=39102; label="XHTTP"; fi
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
                --retry 2 --retry-connrefused --retry-delay 1 \
                -x "socks5h://127.0.0.1:$sp" https://www.gstatic.com/generate_204 2>/dev/null || true)
    if [ "$code" = 204 ]; then
      SELFTEST_RESULT+="$label работает; "
    else
      SELFTEST_RESULT+="$label НЕ работает; "; rc=1
    fi
  done

  kill "$p1" "$p2" 2>/dev/null || true
  wait "$p1" "$p2" 2>/dev/null || true
  rm -f /tmp/xselftest_vision.json /tmp/xselftest_xhttp.json
  SELFTEST_RESULT="${SELFTEST_RESULT%; }"
  return $rc
}
LINKLIB

chmod +x "$LINK_LIB"
source "$LINK_LIB"
ok "Библиотека: $LINK_LIB"

# ── 11. Выбор сайта для маскировки ────────────────────────────────────────────
hdr "САЙТ ДЛЯ МАСКИРОВКИ (target)"

echo ""
echo -e "  Сервер будет выдавать себя за этот сайт. Требования: TLS 1.3, HTTP/2,"
echo -e "  доступен из РФ. Лучший вариант — сайт в той же стране, что и сервер."
echo -e "  Не берите microsoft, apple, google — их используют все подряд."
echo ""
info "Проверяем кандидатов с этого сервера..."

GOOD_TARGETS=()
for d in "${TARGET_CANDIDATES[@]}"; do
  if check_target "$d"; then
    GOOD_TARGETS+=("$d")
    echo -e "  ${GREEN}✓${NC} $d"
  else
    echo -e "  ${RED}✗${NC} $d — $TARGET_WHY"
  fi
done
echo ""

DEFAULT_TARGET=""
if (( ${#GOOD_TARGETS[@]} > 0 )); then
  DEFAULT_TARGET="${GOOD_TARGETS[RANDOM % ${#GOOD_TARGETS[@]}]}"
fi

while true; do
  if [ -n "$DEFAULT_TARGET" ]; then
    read -p "Домен для маскировки (Enter = $DEFAULT_TARGET): " TARGET < /dev/tty
    TARGET=${TARGET:-$DEFAULT_TARGET}
  else
    read -p "Ни один кандидат не подошёл. Введите свой домен: " TARGET < /dev/tty
  fi
  TARGET=$(echo "$TARGET" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#/.*##')
  [ -z "$TARGET" ] && continue
  if check_target "$TARGET"; then
    break
  fi
  echo -e "  ${RED}✗${NC} $TARGET не подходит: $TARGET_WHY"
done

[ "$TARGET_PQ" = "1" ] || \
  warn "$TARGET без постквантового обмена — работать будет, но маскировка хуже"
ok "Маскировка: $TARGET"

# ── 12. Бэкап старой конфигурации ─────────────────────────────────────────────
# До генерации ключей — иначе в бэкап попадут уже новые ключи
hdr "БЭКАП"

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"   # в бэкапах лежит приватный ключ REALITY

# На свежей системе установщик Xray кладёт пустой конфиг «{}» — бэкапить нечего
if [ -s "$XRAY_CFG" ] && [ "$(tr -d ' \n\r\t' < "$XRAY_CFG")" != "{}" ]; then
  TS=$(date +%Y%m%d_%H%M%S)
  cp "$XRAY_CFG"  "$BACKUP_DIR/config.json.$TS"
  [ -f "$KEYS_FILE" ] && cp "$KEYS_FILE" "$BACKUP_DIR/keys.$TS"
  ok "Бэкап сохранён: $BACKUP_DIR/config.json.$TS"
else
  ok "Новая установка, бэкап не требуется"
fi

# ── 13. Генерация ключей Reality ──────────────────────────────────────────────
hdr "ГЕНЕРАЦИЯ КЛЮЧЕЙ"

mkdir -p "$(dirname "$KEYS_FILE")"

UUID=$(xray uuid)
SHORTSID=$(openssl rand -hex 8)
XHTTP_PATH="/$(openssl rand -hex 6)"

# xray x25519 в v26+ выводит:
#   PrivateKey: XXXXX
#   Password (PublicKey): XXXXX
# в старых версиях:
#   Private key: XXXXX
#   Public key:  XXXXX
X25519=$(xray x25519)

# Пробуем новый формат v26+, затем старый
PRIVATEKEY=$(echo "$X25519" | awk '/^PrivateKey:/       {print $2}')
PUBLICKEY=$(echo "$X25519"  | awk '/^Password \(PublicKey\):/ {print $3}')

# Fallback на старый формат
[ -z "$PRIVATEKEY" ] && PRIVATEKEY=$(echo "$X25519" | awk '/Private key:/ {print $3}')
[ -z "$PUBLICKEY"  ] && PUBLICKEY=$(echo "$X25519"  | awk '/Public key:/  {print $3}')

[ -z "$PRIVATEKEY" ] && err "Не удалось сгенерировать приватный ключ"
[ -z "$PUBLICKEY"  ] && err "Не удалось сгенерировать публичный ключ"

# Записываем в нормализованном формате (всегда PublicKey:, PrivateKey:)
cat > "$KEYS_FILE" << EOF
uuid: $UUID
shortsid: $SHORTSID
PrivateKey: $PRIVATEKEY
PublicKey: $PUBLICKEY
target: $TARGET
port: $VLESS_PORT
xhttp_path: $XHTTP_PATH
fp: $FP
EOF
chmod 600 "$KEYS_FILE"

ok "Ключи сгенерированы и сохранены в $KEYS_FILE"

# ── 14. Конфигурация Xray ─────────────────────────────────────────────────────
hdr "СОЗДАНИЕ КОНФИГУРАЦИИ XRAY"

mkdir -p /var/log/xray

# Схема: один порт, два транспорта.
#   vless-in  — TCP + REALITY + Vision на внешнем порту;
#   xhttp-in  — XHTTP на внутреннем сокете @xray-xhttp.
# XHTTP-клиент тоже проходит REALITY на внешнем порту, но внутри шлёт HTTP/2,
# а не VLESS — такой трафик vless-in отдаёт через fallback в xhttp-in.
cat > "$XRAY_CFG" << XRAYCFG
{
  "log": {
    "loglevel": "warning",
    "access": "/var/log/xray/access.log",
    "error":  "/var/log/xray/error.log"
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "localhost"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "type": "field",
        "ip": ["geoip:cn"],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "email": "main",
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "level": 0
          }
        ],
        "decryption": "none",
        "fallbacks": [
          { "dest": "@xray-xhttp" }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${TARGET}:443",
          "xver": 0,
          "serverNames": ["$TARGET"],
          "privateKey": "$PRIVATEKEY",
          "shortIds": ["$SHORTSID"]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    },
    {
      "tag": "xhttp-in",
      "listen": "@xray-xhttp",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "email": "main",
            "id": "$UUID",
            "flow": "",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "$XHTTP_PATH",
          "mode": "auto"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom",   "tag": "direct" },
    { "protocol": "blackhole", "tag": "block"  }
  ],
  "policy": {
    "levels": {
      "0": {
        "handshake":    4,
        "connIdle":     300,
        "uplinkOnly":   1,
        "downlinkOnly": 1
      }
    }
  }
}
XRAYCFG

jq empty "$XRAY_CFG" || err "Ошибка в JSON конфигурации!"
test_cfg "$XRAY_CFG" || \
  err "Xray не принял конфигурацию!\nПроверка: xray run -test -c $XRAY_CFG"
secure_cfg "$XRAY_CFG"
ok "Конфигурация создана и проверена Xray (XHTTP + Vision на порту $VLESS_PORT)"

# ── 15. Ротация логов ─────────────────────────────────────────────────────────
hdr "РОТАЦИЯ ЛОГОВ"

# Ротацию настроил установщик Xray (флаг --logrotate): каждый день в 04:00,
# хранит 7 дней, сжимает старые. Своих задач не заводим — он просит этого не делать.
if [ -f /etc/logrotate.d/xray ]; then
  ok "Ротация логов настроена установщиком Xray (ежедневно в 04:00, хранит 7 дней)"
else
  warn "Установщик Xray не настроил ротацию логов — логи могут разрастаться"
fi

# ── 16. Утилиты управления ────────────────────────────────────────────────────
hdr "СОЗДАНИЕ УТИЛИТ"

# ── mainuser ──────────────────────────────────────────────────────────────────
cat > /usr/local/bin/mainuser << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh
echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  Основной пользователь (main)${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo ""
show_links "main"
SCRIPT
chmod +x /usr/local/bin/mainuser

# ── newuser ───────────────────────────────────────────────────────────────────
cat > /usr/local/bin/newuser << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh

echo ""
read -p "Введите имя пользователя: " email

if [[ ! "$email" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo -e "${RED}Ошибка: допустимы только буквы, цифры, _ и -${NC}"
  exit 1
fi

if jq -e --arg e "$email" \
  '.inbounds[] | select(.tag=="vless-in") | .settings.clients[] | select(.email == $e)' \
  "$XRAY_CFG" >/dev/null 2>&1; then
  echo -e "${RED}Пользователь '$email' уже существует${NC}"
  exit 1
fi

uuid=$(xray uuid)

# Один UUID в обоих входах: Vision — с flow, XHTTP — без
tmpfile=$(mktemp)
if jq --arg e "$email" --arg u "$uuid" '
     (.inbounds[] | select(.tag=="vless-in") | .settings.clients) += [{"email":$e,"id":$u,"flow":"xtls-rprx-vision","level":0}]
   | (.inbounds[] | select(.tag=="xhttp-in") | .settings.clients) += [{"email":$e,"id":$u,"flow":"","level":0}]
   ' "$XRAY_CFG" > "$tmpfile" && test_cfg "$tmpfile"; then
  mv "$tmpfile" "$XRAY_CFG" && secure_cfg "$XRAY_CFG"
else
  rm -f "$tmpfile"
  echo -e "${RED}Не удалось обновить конфиг, ничего не изменено${NC}"
  exit 1
fi

systemctl restart xray

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  Пользователь '$email' создан!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
show_links "$email"
SCRIPT
chmod +x /usr/local/bin/newuser

# ── rmuser ────────────────────────────────────────────────────────────────────
cat > /usr/local/bin/rmuser << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh

load_emails
if [[ ${#emails[@]} -eq 0 ]]; then
  echo -e "${RED}Нет клиентов для удаления${NC}"; exit 1
fi

echo ""
echo -e "${CYAN}Список клиентов:${NC}"
print_emails
echo ""

read -p "Номер для удаления: " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
  echo -e "${RED}Неверный номер${NC}"; exit 1
fi

selected="${emails[$((choice - 1))]}"

if [[ "$selected" == "main" ]]; then
  echo -e "${RED}Нельзя удалить основного пользователя${NC}"; exit 1
fi

read -p "Удалить '$selected'? (y/n): " confirm
[[ "$confirm" != "y" && "$confirm" != "Y" ]] && { echo "Отменено"; exit 0; }

# Удаляем из обоих входов (Vision и XHTTP)
tmpfile=$(mktemp)
jq --arg e "$selected" \
  '(.inbounds[].settings.clients) |= map(select(.email != $e))' \
  "$XRAY_CFG" > "$tmpfile" && mv "$tmpfile" "$XRAY_CFG" && secure_cfg "$XRAY_CFG"

systemctl restart xray
echo -e "${GREEN}Клиент '$selected' удалён${NC}"
SCRIPT
chmod +x /usr/local/bin/rmuser

# ── sharelink ─────────────────────────────────────────────────────────────────
cat > /usr/local/bin/sharelink << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh

load_emails
if [[ ${#emails[@]} -eq 0 ]]; then
  echo -e "${RED}Нет клиентов${NC}"; exit 1
fi

echo ""
echo -e "${CYAN}Список клиентов:${NC}"
print_emails
echo ""

read -p "Выберите номер: " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
  echo -e "${RED}Неверный номер${NC}"; exit 1
fi

selected="${emails[$((choice - 1))]}"

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  Ссылки для: $selected${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
show_links "$selected"
SCRIPT
chmod +x /usr/local/bin/sharelink

# ── userlist ──────────────────────────────────────────────────────────────────
cat > /usr/local/bin/userlist << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh

load_emails
if [[ ${#emails[@]} -eq 0 ]]; then
  echo -e "${RED}Список пуст${NC}"; exit 1
fi

echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  Клиенты (всего: ${#emails[@]})${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
print_emails
echo ""
SCRIPT
chmod +x /usr/local/bin/userlist

# ── xraybackup ────────────────────────────────────────────────────────────────
cat > /usr/local/bin/xraybackup << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh
BACKUP_DIR="/usr/local/etc/xray/backups"
mkdir -p "$BACKUP_DIR"
TS=$(date +%Y%m%d_%H%M%S)
cp "$XRAY_CFG"  "$BACKUP_DIR/config.json.$TS"
cp "$XRAY_KEYS" "$BACKUP_DIR/keys.$TS"
echo ""
echo -e "${GREEN}Бэкап создан:${NC}"
echo "  $BACKUP_DIR/config.json.$TS"
echo ""
SCRIPT
chmod +x /usr/local/bin/xraybackup

# ── xraystatus ────────────────────────────────────────────────────────────────
cat > /usr/local/bin/xraystatus << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh
echo ""
echo -e "${CYAN}════ Статус Xray ════${NC}"
systemctl status xray --no-pager -l
echo ""
port=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .port' "$XRAY_CFG" 2>/dev/null)
target=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .streamSettings.realitySettings.serverNames[0]' "$XRAY_CFG" 2>/dev/null)
users=$(jq '[.inbounds[] | select(.tag=="vless-in") | .settings.clients[]] | length' "$XRAY_CFG" 2>/dev/null)
echo -e "${CYAN}Версия:${NC}        $(xray version 2>&1 | head -1)"
echo -e "${CYAN}Порт:${NC}          $port"
echo -e "${CYAN}Транспорты:${NC}    XHTTP (основной) + TCP/Vision (запасной)"
echo -e "${CYAN}Маскировка:${NC}    $target   (проверить или сменить: xtarget)"
if [ "$(get_fp)" = edge ]; then
  echo -e "${CYAN}Отпечаток:${NC}     edge — режим совместимости (короткое TLS-приветствие)"
else
  echo -e "${CYAN}Отпечаток:${NC}     chrome"
fi
echo -e "${CYAN}Пользователей:${NC} $users"
echo ""
echo -n "Самопроверка подключения... "
if selftest; then
  echo -e "${GREEN}$SELFTEST_RESULT${NC}"
else
  echo -e "${RED}$SELFTEST_RESULT${NC}"
  echo -e "${YELLOW}Сервер не принимает подключения даже изнутри. Попробуйте сменить сайт: xtarget${NC}"
fi
echo ""
SCRIPT
chmod +x /usr/local/bin/xraystatus

# ── xupdate ───────────────────────────────────────────────────────────────────
cat > /usr/local/bin/xupdate << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh
URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

# ver_ge A B — версия A не ниже B
ver_ge() { [ "$(printf '%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]; }

cur=$(xray version 2>/dev/null | awk 'NR==1 {print $2}')
fp=$(get_fp)

echo ""
echo -e "${CYAN}Текущая версия Xray:${NC} ${cur:-неизвестно}   ${CYAN}Отпечаток в ссылках:${NC} $fp"
echo ""
echo -e "  ${CYAN}1${NC} — последняя стабильная версия"
echo -e "  ${CYAN}2${NC} — последняя prerelease (свежие исправления, но меньше проверены)"
echo -e "  ${CYAN}3${NC} — конкретная версия (например 26.10.21)"
echo -e "  ${CYAN}4${NC} — только geo-файлы (полные списки для маршрутизации)"
echo -e "  ${CYAN}0${NC} — отмена"
echo ""
echo -e "${YELLOW}Важно:${NC} версии сервера и клиентов должны быть близки."
echo -e "Обновили сервер — обновите и v2rayN / v2rayNG."
echo -e "После обновления — самопроверка. Не пройдёт — верну прежнюю версию."
echo ""
read -p "Выбор: " c

case "$c" in
  1) args=(install -f) ;;
  2) args=(install --beta) ;;
  3) read -p "Версия: " v
     if ! [[ "$v" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
       echo -e "${RED}Неверный формат версии${NC}"; exit 1
     fi
     args=(install --version "v${v#v}" -f) ;;
  4) args=(update-geodata) ;;
  *) echo "Отменено"; exit 0 ;;
esac

# Отпечаток edge принимают только версии до 26.9.8 (Xray #7259)
switch_fp=""
if [ "$fp" = edge ] && [ "$c" != 4 ]; then
  echo ""
  echo -e "${YELLOW}Ссылки сейчас с отпечатком edge, а версии Xray с 26.9.8 его не принимают.${NC}"
  echo -e "Если новая версия окажется новее, ссылки нужно перевести на chrome"
  echo -e "и заново раздать всем (sharelink). Без этого обновление откатится."
  read -p "Перевести ссылки на chrome, если понадобится? (y/N): " sw
  [[ "$sw" == "y" || "$sw" == "Y" ]] && switch_fp=chrome
fi

xraybackup >/dev/null

if ! bash -c "$(curl -4 -fsSL "$URL")" @ "${args[@]}"; then
  echo -e "${RED}Установщик завершился с ошибкой${NC}"; exit 1
fi

rollback() {
  echo -e "${RED}$1 — откатываюсь на $cur${NC}"
  # -f: переустановить ту же версию (нужно и после обновления geo-файлов)
  bash -c "$(curl -4 -fsSL "$URL")" @ install --version "v$cur" -f >/dev/null 2>&1
  sed -i "s/^fp: .*/fp: $fp/" "$XRAY_KEYS"
  systemctl restart xray
  exit 1
}

new=$(xray version 2>/dev/null | awk 'NR==1 {print $2}')

if [ "$fp" = edge ] && [ -n "$new" ] && ver_ge "$new" 26.9.8; then
  if [ "$switch_fp" = chrome ]; then
    if grep -q '^fp:' "$XRAY_KEYS"; then
      sed -i 's/^fp: .*/fp: chrome/' "$XRAY_KEYS"
    else
      echo "fp: chrome" >> "$XRAY_KEYS"
    fi
    echo -e "${YELLOW}Ссылки переведены на отпечаток chrome${NC}"
  elif [ -n "$cur" ]; then
    rollback "Версия $new не принимает отпечаток edge"
  fi
fi

if ! test_cfg "$XRAY_CFG"; then
  [ -n "$cur" ] && rollback "Новая версия не принимает конфиг"
  exit 1
fi

systemctl restart xray
sleep 2
if ! systemctl is-active --quiet xray; then
  [ -n "$cur" ] && rollback "Xray не запустился"
  exit 1
fi

echo -n "Самопроверка подключения... "
if ! selftest; then
  echo -e "${RED}$SELFTEST_RESULT${NC}"
  [ -n "$cur" ] && rollback "Самопроверка не прошла"
  exit 1
fi
echo -e "${GREEN}$SELFTEST_RESULT${NC}"

echo ""
echo -e "${GREEN}Готово: ${cur:-?} → ${new:-?}${NC}"
[ "$(get_fp)" != "$fp" ] && echo -e "${YELLOW}Раздайте всем новые ссылки: sharelink${NC}"
echo ""
SCRIPT
chmod +x /usr/local/bin/xupdate

# ── xtarget ───────────────────────────────────────────────────────────────────
cat > /usr/local/bin/xtarget << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh

cur=$(jq -r '.inbounds[] | select(.tag=="vless-in") | .streamSettings.realitySettings.serverNames[0]' "$XRAY_CFG")

echo ""
echo -e "${CYAN}Сайт маскировки сейчас:${NC} $cur"
echo -n "Проверка... "
if check_target "$cur"; then
  echo -e "${GREEN}в порядке${NC}"
else
  echo -e "${RED}не подходит: $TARGET_WHY${NC}"
fi
echo ""

read -p "Новый домен (Enter = оставить как есть): " new
new=$(echo "$new" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#/.*##')
[ -z "$new" ] && exit 0
[ "$new" == "$cur" ] && { echo "Это тот же домен"; exit 0; }

echo -n "Проверка $new... "
if ! check_target "$new"; then
  echo -e "${RED}не подходит: $TARGET_WHY${NC}"; exit 1
fi
echo -e "${GREEN}подходит${NC}"
[ "$TARGET_PQ" = "1" ] || \
  echo -e "${YELLOW}Без постквантового обмена — работать будет, но маскировка хуже${NC}"

xraybackup >/dev/null

tmpfile=$(mktemp)
jq --arg d "$new" \
  '(.inbounds[] | select(.tag=="vless-in") | .streamSettings.realitySettings) |= (.target = ($d + ":443") | .serverNames = [$d])' \
  "$XRAY_CFG" > "$tmpfile"
if ! test_cfg "$tmpfile"; then
  rm -f "$tmpfile"
  echo -e "${RED}Конфиг не прошёл проверку, ничего не изменено${NC}"; exit 1
fi
oldcfg=$(mktemp); cp "$XRAY_CFG" "$oldcfg"
mv "$tmpfile" "$XRAY_CFG" && secure_cfg "$XRAY_CFG"
sed -i "s/^target: .*/target: $new/" "$XRAY_KEYS"
systemctl restart xray
sleep 2

# Некоторые сайты проходят проверку, но с REALITY всё равно не работают
# (Xray #7243, #6861) — проверяем подключение по-настоящему
echo -n "Самопроверка подключения... "
if ! selftest; then
  echo -e "${RED}не прошла: $SELFTEST_RESULT${NC}"
  cp "$oldcfg" "$XRAY_CFG" && secure_cfg "$XRAY_CFG"
  sed -i "s/^target: .*/target: $cur/" "$XRAY_KEYS"
  systemctl restart xray
  rm -f "$oldcfg"
  echo -e "${YELLOW}Вернул прежний сайт: $cur. Попробуйте другой домен.${NC}"
  exit 1
fi
rm -f "$oldcfg"
echo -e "${GREEN}$SELFTEST_RESULT${NC}"

echo ""
echo -e "${GREEN}Сайт маскировки: $cur → $new${NC}"
echo -e "${YELLOW}Ссылки изменились (параметр sni) — раздайте всем новые: sharelink${NC}"
echo ""
SCRIPT
chmod +x /usr/local/bin/xtarget

# ── x (главное меню) ──────────────────────────────────────────────────────────
cat > /usr/local/bin/x << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh

show_menu() {
  echo ""
  echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║      Xray VLESS + Reality — Меню       ║${NC}"
  echo -e "${CYAN}╠════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║${NC}  1. Ссылки основного пользователя      ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  2. Создать пользователя               ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  3. Удалить пользователя               ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  4. Ссылки для пользователя            ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  5. Список пользователей               ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  6. Статус Xray                        ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  7. Перезапустить Xray                 ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  8. Создать бэкап                      ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  9. Обновить Xray                      ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC} 10. Сайт маскировки: проверить/сменить ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC} 11. Помощь                             ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  0. Выход                              ${CYAN}║${NC}"
  echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
  echo ""
}

show_help() {
  echo ""
  echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║             Xray VLESS + Reality — Справка             ║${NC}"
  echo -e "${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}КОМАНДЫ (можно вызывать напрямую):${NC}                    ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    x          — это меню                               ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    mainuser   — ссылки и QR основного пользователя     ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    newuser    — создать нового пользователя            ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    rmuser     — удалить пользователя                   ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    sharelink  — ссылки для выбранного пользователя     ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    userlist   — список всех пользователей              ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    xraybackup — создать бэкап конфигурации             ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    xraystatus — статус, версия, сайт маскировки        ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    xupdate    — обновить Xray (с откатом при сбое)     ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    xtarget    — проверить или сменить сайт маскировки  ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}ССЫЛКИ:${NC} у каждого пользователя их две                 ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    XHTTP  — основная, не больше 3 соединений           ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    Vision — запасная, быстрее на больших загрузках     ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}ФАЙЛЫ:${NC}                                                ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    /usr/local/etc/xray/config.json  — конфиг Xray      ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    /usr/local/etc/xray/.keys        — ключи Reality    ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    /usr/local/etc/xray/backups/     — бэкапы           ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    /var/log/xray/                   — логи             ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}СЕРВИС:${NC}                                               ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    systemctl restart xray  — перезапустить             ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    systemctl stop xray     — остановить                ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    journalctl -u xray -f   — логи в реальном времени   ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}КЛИЕНТЫ (нужно ядро Xray 26.3.27+):${NC}                   ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    Android:  v2rayNG, Happ                             ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    iOS:      Happ                                      ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    Windows:  v2rayN                                    ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    Не подходят: NekoBox, Hiddify, Throne, Karing       ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}ЕСЛИ ПОДКЛЮЧЕНИЕ ВИСИТ:${NC}                               ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    xraystatus — внизу будет самопроверка сервера       ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    Сервер работает, а с телефона нет — в части сетей   ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    теряется длинное TLS-приветствие chrome. Поможет    ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    переустановка в режиме совместимости (edge)         ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
  echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

while true; do
  show_menu
  read -p "Выберите действие: " action
  case "$action" in
    1)  mainuser ;;
    2)  newuser ;;
    3)  rmuser ;;
    4)  sharelink ;;
    5)  userlist ;;
    6)  xraystatus ;;
    7)  systemctl restart xray && echo -e "${GREEN}Xray перезапущен${NC}" ;;
    8)  xraybackup ;;
    9)  xupdate ;;
    10) xtarget ;;
    11) show_help ;;
    0)  echo ""; exit 0 ;;
    *)  echo -e "${RED}Неверный выбор${NC}" ;;
  esac
done
SCRIPT
chmod +x /usr/local/bin/x

ok "Все утилиты созданы (главное меню: x)"

# ── 17. Запуск Xray ───────────────────────────────────────────────────────────
hdr "ЗАПУСК XRAY"

fix_log_owner
systemctl enable xray --quiet
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
  ok "Xray работает"
else
  echo -e "${RED}--- последние строки журнала Xray ---${NC}"
  journalctl -u xray -n 8 --no-pager -o cat 2>/dev/null || true
  err "Xray не запустился! Полный журнал: journalctl -u xray -n 50 --no-pager"
fi

# ── 18. Самопроверка ──────────────────────────────────────────────────────────
# Клиент на самом сервере подключается к себе по обеим ссылкам. Так видно,
# что сервер исправен, ещё до того, как вы импортируете ссылки в приложение.
hdr "САМОПРОВЕРКА"

SELFTEST_OK=1
if selftest; then
  ok "Самопроверка пройдена: $SELFTEST_RESULT"
else
  SELFTEST_OK=0
  warn "Самопроверка НЕ пройдена: $SELFTEST_RESULT"
  warn "Сервер не принимает подключения даже изнутри. Чаще всего виноват сайт"
  warn "маскировки — смените его командой xtarget (она проверит новый сайт сама)."
  warn "Журналы клиента самопроверки: /tmp/xselftest_vision.log, /tmp/xselftest_xhttp.log"
fi

# ── 19. Итог ──────────────────────────────────────────────────────────────────
hdr "УСТАНОВКА ЗАВЕРШЕНА"

echo ""
echo -e "  ${GREEN}IP сервера:${NC}  $SERVER_IP"
echo -e "  ${GREEN}Порт:${NC}        $VLESS_PORT"
echo -e "  ${GREEN}Протокол:${NC}    VLESS + REALITY"
echo -e "  ${GREEN}Транспорты:${NC}  XHTTP (основной) + TCP/Vision (запасной)"
echo -e "  ${GREEN}Маскировка:${NC}  $TARGET"
echo -e "  ${GREEN}Xray:${NC}        $(xray version 2>/dev/null | awk 'NR==1 {print $2}')"
if [[ "$FP" == "edge" ]]; then
  echo -e "  ${GREEN}Отпечаток:${NC}   edge (режим совместимости)"
else
  echo -e "  ${GREEN}Отпечаток:${NC}   chrome"
fi
echo ""

mainuser

echo -e "${YELLOW}Следующие шаги:${NC}"
echo "  1. Импортируйте ОСНОВНУЮ ссылку (XHTTP) в v2rayN / v2rayNG / Happ"
echo "  2. Vision — запасная: если XHTTP не подключается или нужна макс. скорость"
echo "  3. Меню управления: x   (обновление: xupdate, сайт маскировки: xtarget)"
echo ""
echo -e "  ${YELLOW}NekoBox, Hiddify, Throne, Karing к этому серверу не подключатся.${NC}"
if [[ "$FP" == "chrome" ]]; then
  echo -e "  ${YELLOW}Если с телефона подключение висит, а xraystatus показывает, что сервер${NC}"
  echo -e "  ${YELLOW}исправен, — переустановите в режиме совместимости (вариант 2).${NC}"
fi
echo ""
if [[ "$SELFTEST_OK" == "1" ]]; then
  echo -e "${GREEN}✓ Готово!${NC}"
else
  echo -e "${YELLOW}Установка завершена, но самопроверка не прошла — см. выше.${NC}"
fi
echo ""
