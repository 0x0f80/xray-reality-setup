#!/bin/bash
# =============================================================================
#  Протокол: VLESS + Reality (обход DPI в РФ/Китае)
#  Транспорт: TCP (xtls-rprx-vision) или XHTTP (на выбор)
#  Маскировка: www.microsoft.com
#
#  Запуск:
#    bash install_xray.sh
# =============================================================================

set -euo pipefail

# ── Цвета ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
info() { echo -e "${YELLOW}[→]${NC} $1"; }
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
# www.microsoft.com — лучший dest для РФ/Китая:
# корпоративный трафик, не блокируют, TLS 1.3, огромный объём
DEST="www.microsoft.com"

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

# ── 2. Выбор транспорта ───────────────────────────────────────────────────────
hdr "ВЫБОР ТРАНСПОРТА"

echo ""
echo -e "  ${CYAN}1${NC} — TCP + xtls-rprx-vision (классика, максимальная совместимость)"
echo -e "  ${CYAN}2${NC} — XHTTP (новый транспорт, меняет сигнатуру трафика)"
echo ""
echo -e "  ${YELLOW}Примечание:${NC} XHTTP поддерживают не все клиенты (v2rayNG, v2rayN, Hiddify)."
echo -e "  Если не уверены — выберите TCP."
echo ""
read -p "Выберите транспорт (Enter = 1): " TRANSPORT_CHOICE < /dev/tty
TRANSPORT_CHOICE=${TRANSPORT_CHOICE:-1}

if [[ "$TRANSPORT_CHOICE" == "2" ]]; then
  TRANSPORT="xhttp"
  FLOW=""
  ok "Транспорт: XHTTP"
else
  TRANSPORT="tcp"
  FLOW="xtls-rprx-vision"
  ok "Транспорт: TCP + xtls-rprx-vision"
fi

# ── 3. Выбор порта ────────────────────────────────────────────────────────────
hdr "ВЫБОР ПОРТА"

echo ""
echo -e "  ${CYAN}443${NC}  — стандартный HTTPS (лучшая маскировка)"
echo -e "  ${CYAN}8443${NC} — альтернативный (если 443 заблокирован)"
echo -e "  ${CYAN}2053${NC} — Cloudflare-стиль (редко блокируют)"
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
apt-get install -y -qq curl jq qrencode nginx ufw fail2ban
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

cat > /etc/fail2ban/jail.d/xray.conf << 'EOF'
[sshd]
enabled  = true
port     = 22
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
bantime  = 3600
EOF

systemctl enable fail2ban --quiet
systemctl restart fail2ban
ok "Fail2Ban запущен (SSH: макс 3 попытки, бан 1 час)"

# ── 7. BBR ────────────────────────────────────────────────────────────────────
hdr "TCP BBR"

if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
  ok "BBR уже включён"
else
  grep -q 'tcp_congestion_control=bbr' /etc/sysctl.conf || {
    echo "net.core.default_qdisc=fq"           >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
  }
  sysctl -p -q
  ok "BBR включён"
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

if command -v xray &>/dev/null; then
  info "Xray уже установлен, обновляем до последней версии..."
  bash -c "$(curl -4 -fL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ upgrade
else
  bash -c "$(curl -4 -fL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
fi

command -v xray &>/dev/null || err "Xray не установился, проверьте подключение к интернету"
XRAY_VER=$(xray version 2>&1 | head -1)
ok "$XRAY_VER"

# ── 10. Генерация ключей Reality ──────────────────────────────────────────────
hdr "ГЕНЕРАЦИЯ КЛЮЧЕЙ"

mkdir -p "$(dirname "$KEYS_FILE")"

UUID=$(xray uuid)
SHORTSID=$(openssl rand -hex 8)

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
dest: $DEST
port: $VLESS_PORT
transport: $TRANSPORT
EOF
chmod 600 "$KEYS_FILE"

ok "Ключи сгенерированы и сохранены в $KEYS_FILE"

# ── 11. Бэкап старой конфигурации ─────────────────────────────────────────────
hdr "БЭКАП"

mkdir -p "$BACKUP_DIR"

if [ -f "$XRAY_CFG" ]; then
  TS=$(date +%Y%m%d_%H%M%S)
  cp "$XRAY_CFG"  "$BACKUP_DIR/config.json.$TS"
  [ -f "$KEYS_FILE" ] && cp "$KEYS_FILE" "$BACKUP_DIR/keys.$TS"
  ok "Бэкап сохранён: $BACKUP_DIR/config.json.$TS"
else
  ok "Новая установка, бэкап не требуется"
fi

# ── 12. Конфигурация Xray ─────────────────────────────────────────────────────
hdr "СОЗДАНИЕ КОНФИГУРАЦИИ XRAY"

mkdir -p /var/log/xray

# Формируем streamSettings в зависимости от транспорта
if [[ "$TRANSPORT" == "xhttp" ]]; then
  STREAM_SETTINGS=$(cat << STREAM
        "network": "xhttp",
        "xhttpSettings": {
          "path": "/"
        },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "target": "${DEST}:443",
          "serverNames": ["$DEST"],
          "privateKey": "$PRIVATEKEY",
          "maxTimeDiff": 0,
          "shortIds": ["$SHORTSID"]
        }
STREAM
)
  CLIENT_ENTRY=$(cat << CLIENT
          {
            "email": "main",
            "id": "$UUID",
            "flow": "",
            "level": 0
          }
CLIENT
)
else
  STREAM_SETTINGS=$(cat << STREAM
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST}:443",
          "xver": 0,
          "serverNames": ["$DEST"],
          "privateKey": "$PRIVATEKEY",
          "maxTimeDiff": 0,
          "shortIds": ["$SHORTSID"]
        }
STREAM
)
  CLIENT_ENTRY=$(cat << CLIENT
          {
            "email": "main",
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "level": 0
          }
CLIENT
)
fi

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
      "listen": "0.0.0.0",
      "port": $VLESS_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
$CLIENT_ENTRY
        ],
        "decryption": "none"
      },
      "streamSettings": {
$STREAM_SETTINGS
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
chmod 644 "$XRAY_CFG"
ok "Конфигурация создана и проверена (транспорт: $TRANSPORT)"

# ── 13. Ротация логов ─────────────────────────────────────────────────────────
hdr "РОТАЦИЯ ЛОГОВ"

cat > /etc/logrotate.d/xray << 'EOF'
/var/log/xray/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    postrotate
        kill -HUP $(pidof xray) 2>/dev/null || true
    endscript
}
EOF

ok "Logrotate настроен (7 дней, с компрессией)"

# ── 14. Библиотека генерации ссылок ───────────────────────────────────────────
hdr "БИБЛИОТЕКА ССЫЛОК"

mkdir -p /usr/local/lib

cat > "$LINK_LIB" << 'LINKLIB'
#!/bin/bash
# =============================================================================
#  Общая библиотека для утилит Xray
#  Использование: source /usr/local/lib/xray_link.sh
# =============================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
export RED GREEN YELLOW CYAN NC

# Генерация VLESS + Reality ссылки по email пользователя
gen_link() {
  local email="$1"
  local cfg="/usr/local/etc/xray/config.json"
  local keys="/usr/local/etc/xray/.keys"

  local index
  index=$(jq --arg e "$email" \
    '.inbounds[0].settings.clients | to_entries[] | select(.value.email == $e) | .key' \
    "$cfg" 2>/dev/null)

  if [ -z "$index" ]; then
    echo -e "${RED}Пользователь '$email' не найден${NC}" >&2
    return 1
  fi

  local uuid port sni pbk sid ip transport network flow_param
  uuid=$(jq --argjson i "$index" -r '.inbounds[0].settings.clients[$i].id' "$cfg")
  port=$(jq -r '.inbounds[0].port' "$cfg")
  sni=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$cfg")
  pbk=$(awk '/^PublicKey:/ {print $2}' "$keys")
  sid=$(awk -F': ' '/^shortsid:/ {print $2}' "$keys")
  network=$(jq -r '.inbounds[0].streamSettings.network' "$cfg")

  ip=$(timeout 5 curl -4 -s https://ifconfig.me 2>/dev/null || \
       timeout 5 curl -4 -s https://icanhazip.com 2>/dev/null || true)
  if [ -z "$ip" ]; then
    ip=$(hostname -I | awk '{print $1}')
    [ -z "$ip" ] && { echo -e "${RED}Не удалось определить IP сервера${NC}" >&2; return 1; }
  fi

  if [[ "$network" == "xhttp" ]]; then
    echo "vless://${uuid}@${ip}:${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=xhttp&path=%2F&mode=auto#${email}"
  else
    echo "vless://${uuid}@${ip}:${port}?security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp&flow=xtls-rprx-vision#${email}"
  fi
}

export -f gen_link
LINKLIB

chmod +x "$LINK_LIB"
ok "Библиотека: $LINK_LIB"

# ── 15. Утилиты управления ────────────────────────────────────────────────────
hdr "СОЗДАНИЕ УТИЛИТ"

# ── mainuser ──────────────────────────────────────────────────────────────────
cat > /usr/local/bin/mainuser << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh
link=$(gen_link "main") || exit 1
echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  Основной пользователь (main)${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}Ссылка:${NC}"
echo "$link"
echo ""
echo -e "${GREEN}QR-код:${NC}"
echo "$link" | qrencode -t ansiutf8
echo ""
SCRIPT
chmod +x /usr/local/bin/mainuser

# ── newuser ───────────────────────────────────────────────────────────────────
cat > /usr/local/bin/newuser << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh
cfg="/usr/local/etc/xray/config.json"

echo ""
read -p "Введите имя пользователя: " email

if [[ ! "$email" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo -e "${RED}Ошибка: допустимы только буквы, цифры, _ и -${NC}"
  exit 1
fi

if jq -e --arg e "$email" \
  '.inbounds[0].settings.clients[] | select(.email == $e)' \
  "$cfg" >/dev/null 2>&1; then
  echo -e "${RED}Пользователь '$email' уже существует${NC}"
  exit 1
fi

uuid=$(xray uuid)

# Определяем flow из текущего конфига (пустой для xhttp, xtls-rprx-vision для tcp)
network=$(jq -r '.inbounds[0].streamSettings.network' "$cfg")
if [[ "$network" == "xhttp" ]]; then
  flow_val=""
else
  flow_val="xtls-rprx-vision"
fi

tmpfile=$(mktemp)
jq --arg e "$email" --arg u "$uuid" --arg f "$flow_val" \
  '.inbounds[0].settings.clients += [{"email":$e,"id":$u,"flow":$f,"level":0}]' \
  "$cfg" > "$tmpfile" && mv "$tmpfile" "$cfg" && chmod 644 "$cfg"

systemctl restart xray

link=$(gen_link "$email") || exit 1
echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  Пользователь '$email' создан!${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo -e "${GREEN}Ссылка:${NC}"
echo "$link"
echo ""
echo -e "${GREEN}QR-код:${NC}"
echo "$link" | qrencode -t ansiutf8
echo ""
SCRIPT
chmod +x /usr/local/bin/newuser

# ── rmuser ────────────────────────────────────────────────────────────────────
cat > /usr/local/bin/rmuser << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh
cfg="/usr/local/etc/xray/config.json"

mapfile -t emails < <(jq -r '.inbounds[0].settings.clients[].email' "$cfg" 2>/dev/null)

if [[ ${#emails[@]} -eq 0 ]]; then
  echo -e "${RED}Нет клиентов для удаления${NC}"; exit 1
fi

echo ""
echo -e "${CYAN}Список клиентов:${NC}"
for i in "${!emails[@]}"; do
  marker=""
  [[ "${emails[$i]}" == "main" ]] && marker=" ${YELLOW}(основной)${NC}"
  echo -e "  $((i+1)). ${emails[$i]}$marker"
done
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

tmpfile=$(mktemp)
jq --arg e "$selected" \
  '(.inbounds[0].settings.clients) |= map(select(.email != $e))' \
  "$cfg" > "$tmpfile" && mv "$tmpfile" "$cfg" && chmod 644 "$cfg"

systemctl restart xray
echo -e "${GREEN}Клиент '$selected' удалён${NC}"
SCRIPT
chmod +x /usr/local/bin/rmuser

# ── sharelink ─────────────────────────────────────────────────────────────────
cat > /usr/local/bin/sharelink << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh
cfg="/usr/local/etc/xray/config.json"

mapfile -t emails < <(jq -r '.inbounds[0].settings.clients[].email' "$cfg" 2>/dev/null)

if [[ ${#emails[@]} -eq 0 ]]; then
  echo -e "${RED}Нет клиентов${NC}"; exit 1
fi

echo ""
echo -e "${CYAN}Список клиентов:${NC}"
for i in "${!emails[@]}"; do
  marker=""
  [[ "${emails[$i]}" == "main" ]] && marker=" ${YELLOW}(основной)${NC}"
  echo -e "  $((i+1)). ${emails[$i]}$marker"
done
echo ""

read -p "Выберите номер: " choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#emails[@]} )); then
  echo -e "${RED}Неверный номер${NC}"; exit 1
fi

selected="${emails[$((choice - 1))]}"
link=$(gen_link "$selected") || exit 1

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  Ссылка для: $selected${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo "$link"
echo ""
echo -e "${CYAN}QR-код:${NC}"
echo "$link" | qrencode -t ansiutf8
echo ""
SCRIPT
chmod +x /usr/local/bin/sharelink

# ── userlist ──────────────────────────────────────────────────────────────────
cat > /usr/local/bin/userlist << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh
cfg="/usr/local/etc/xray/config.json"

mapfile -t emails < <(jq -r '.inbounds[0].settings.clients[].email' "$cfg" 2>/dev/null)

if [[ ${#emails[@]} -eq 0 ]]; then
  echo -e "${RED}Список пуст${NC}"; exit 1
fi

echo ""
echo -e "${CYAN}════════════════════════════════════════${NC}"
echo -e "${CYAN}  Клиенты (всего: ${#emails[@]})${NC}"
echo -e "${CYAN}════════════════════════════════════════${NC}"
for i in "${!emails[@]}"; do
  marker=""
  [[ "${emails[$i]}" == "main" ]] && marker=" ${YELLOW}(основной)${NC}"
  echo -e "  $((i+1)). ${emails[$i]}$marker"
done
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
cp /usr/local/etc/xray/config.json "$BACKUP_DIR/config.json.$TS"
cp /usr/local/etc/xray/.keys       "$BACKUP_DIR/keys.$TS"
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
echo -e "${CYAN}Версия:${NC} $(xray version 2>&1 | head -1)"
transport=$(jq -r '.inbounds[0].streamSettings.network' /usr/local/etc/xray/config.json 2>/dev/null)
port=$(jq -r '.inbounds[0].port' /usr/local/etc/xray/config.json 2>/dev/null)
echo -e "${CYAN}Транспорт:${NC} $transport"
echo -e "${CYAN}Порт:${NC} $port"
echo ""
SCRIPT
chmod +x /usr/local/bin/xraystatus

# ── x (главное меню) ──────────────────────────────────────────────────────────
cat > /usr/local/bin/x << 'SCRIPT'
#!/bin/bash
source /usr/local/lib/xray_link.sh

show_menu() {
  echo ""
  echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║     Xray VLESS + Reality — Меню        ║${NC}"
  echo -e "${CYAN}╠════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║${NC}  1. Ссылка основного пользователя      ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  2. Создать пользователя               ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  3. Удалить пользователя               ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  4. Ссылка для пользователя            ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  5. Список пользователей               ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  6. Статус Xray                        ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  7. Перезапустить Xray                 ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  8. Создать бэкап                      ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  9. Помощь                             ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  0. Выход                              ${CYAN}║${NC}"
  echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
  echo ""
}

show_help() {
  echo ""
  echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║          Xray VLESS + Reality — Справка              ║${NC}"
  echo -e "${CYAN}╠════════════════════════════════════════════════════════╣${NC}"
  echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}КОМАНДЫ (можно вызывать напрямую):${NC}                    ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    x          — это меню                                ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    mainuser   — ссылка и QR основного пользователя      ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    newuser    — создать нового пользователя             ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    rmuser     — удалить пользователя                    ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    sharelink  — ссылка для выбранного пользователя      ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    userlist   — список всех пользователей               ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    xraybackup — создать бэкап конфигурации              ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    xraystatus — статус и версия Xray                    ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}ФАЙЛЫ:${NC}                                                ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    /usr/local/etc/xray/config.json  — конфиг Xray       ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    /usr/local/etc/xray/.keys        — ключи Reality     ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    /usr/local/etc/xray/backups/     — бэкапы            ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    /var/log/xray/                   — логи              ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}СЕРВИС:${NC}                                               ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    systemctl restart xray  — перезапустить              ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    systemctl stop xray     — остановить                 ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    journalctl -u xray -f   — логи в реальном времени    ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}  ${GREEN}КЛИЕНТЫ:${NC}                                              ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    Android:  v2rayNG, Hiddify                           ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    iOS:      Shadowrocket, Streisand                    ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    Windows:  Hiddify, v2rayN                            ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}    macOS:    Hiddify, V2Box                             ${CYAN}║${NC}"
  echo -e "${CYAN}║${NC}                                                        ${CYAN}║${NC}"
  echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

while true; do
  show_menu
  read -p "Выберите действие: " action
  case "$action" in
    1) mainuser ;;
    2) newuser ;;
    3) rmuser ;;
    4) sharelink ;;
    5) userlist ;;
    6) xraystatus ;;
    7) systemctl restart xray && echo -e "${GREEN}Xray перезапущен${NC}" ;;
    8) xraybackup ;;
    9) show_help ;;
    0) echo ""; exit 0 ;;
    *) echo -e "${RED}Неверный выбор${NC}" ;;
  esac
done
SCRIPT
chmod +x /usr/local/bin/x

ok "Все утилиты созданы (главное меню: x)"

# ── 16. Запуск Xray ───────────────────────────────────────────────────────────
hdr "ЗАПУСК XRAY"

systemctl enable xray --quiet
systemctl restart xray
sleep 2

if systemctl is-active --quiet xray; then
  ok "Xray работает"
else
  err "Xray не запустился!\nЛоги: journalctl -u xray -n 50\nКонфиг: jq . $XRAY_CFG"
fi

# ── 17. Итог ──────────────────────────────────────────────────────────────────
hdr "УСТАНОВКА ЗАВЕРШЕНА"

echo ""
echo -e "  ${GREEN}IP сервера:${NC}  $SERVER_IP"
echo -e "  ${GREEN}Порт:${NC}        $VLESS_PORT"
echo -e "  ${GREEN}Протокол:${NC}    VLESS + Reality"
echo -e "  ${GREEN}Транспорт:${NC}   $TRANSPORT"
echo -e "  ${GREEN}Маскировка:${NC}  $DEST"
echo ""

mainuser

echo -e "${YELLOW}Следующие шаги:${NC}"
echo "  1. Скопируйте ссылку в v2rayNG / Hiddify / Shadowrocket"
echo "  2. Меню управления:     x"
echo "  3. Создать пользователя: newuser"
echo "  4. Список пользователей: userlist"
echo ""
echo -e "${GREEN}✓ Готово!${NC}"
echo ""
