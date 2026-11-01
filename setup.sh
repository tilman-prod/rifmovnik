#!/usr/bin/env bash
# Рифмовник — установка сервера на чистую Ubuntu (22.04 / 24.04).
# Запуск от root одной строкой:
#   curl -fsSL https://raw.githubusercontent.com/tilman-prod/rifmovnik/main/setup.sh | bash
# Скрипт можно запускать повторно: он ничего не ломает и сохраняет уже введённое.
set -euo pipefail

SRC_REPO="tilman-prod/rifmovnik-src"
DIR=/opt/rifmovnik
ENV=/etc/rifmovnik.env
KEY=/root/.ssh/rifmovnik_deploy
TTY=/dev/tty

say()  { printf '\n\033[1;35m▸ %s\033[0m\n' "$*"; }
ask()  { local v; read -rp "$1" v <"$TTY"; printf '%s' "$v"; }
getenv() { [ -f "$ENV" ] && grep -E "^$1=" "$ENV" | head -1 | cut -d= -f2- || true; }

[ "$(id -u)" = 0 ] || { echo "Нужен root. Зайди в консоль под root и запусти ещё раз."; exit 1; }

say "Рифмовник: установка сервера"

DOMAIN="$(getenv DOMAIN)"
if [ -z "$DOMAIN" ]; then DOMAIN="$(ask 'Домен сайта (например rifmovnik.ru): ')"; fi
DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN%%/*}"
# a Cyrillic domain (рифмовник.рф) is stored in its ASCII form (xn--…) — that is what DNS, certificates and Telegram expect
DOMAIN="$(python3 -c 'import sys; print(sys.argv[1].strip().lower().encode("idna").decode())' "$DOMAIN" 2>/dev/null || echo "$DOMAIN")"
[ -n "$DOMAIN" ] || { echo "Без домена Telegram не откроет приложение (нужен https)."; exit 1; }

BOT_TOKEN="$(getenv BOT_TOKEN)"
if [ -z "$BOT_TOKEN" ]; then
  read -rsp "Токен бота из @BotFather (при вводе не виден, вставь и нажми Enter): " BOT_TOKEN <"$TTY"; echo
fi
[[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { echo "Это не похоже на токен бота (должно быть 123456789:ABC…)."; exit 1; }

ADMIN_IDS="$(getenv ADMIN_IDS)"
if [ -z "$ADMIN_IDS" ]; then ADMIN_IDS="$(ask 'Твой Telegram ID для админки (цифры; можно оставить пустым): ')"; fi

SESSION_SECRET="$(getenv SESSION_SECRET)"
[ -n "$SESSION_SECRET" ] || SESSION_SECRET="$(openssl rand -hex 32)"

say "Ставлю пакеты (пара минут)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -yq git curl ca-certificates gnupg openssl debian-keyring debian-archive-keyring apt-transport-https >/dev/null

if ! command -v node >/dev/null || [ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - >/dev/null
  apt-get install -yq nodejs >/dev/null
fi
echo "node $(node -v)"

if ! command -v caddy >/dev/null; then
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q
  apt-get install -yq caddy >/dev/null
fi
echo "caddy $(caddy version | cut -d' ' -f1)"

say "Ключ доступа к приватному репозиторию"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
[ -f "$KEY" ] || ssh-keygen -t ed25519 -N "" -f "$KEY" -C "rifmovnik-server" -q
if ! grep -q "Host github-rifm" /root/.ssh/config 2>/dev/null; then
  cat >> /root/.ssh/config <<EOF
Host github-rifm
  HostName github.com
  User git
  IdentityFile $KEY
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
  chmod 600 /root/.ssh/config
fi
GIT_URL="git@github-rifm:$SRC_REPO.git"
if ! git ls-remote "$GIT_URL" >/dev/null 2>&1; then
  echo
  echo "Скопируй строку ниже целиком:"
  echo
  cat "$KEY.pub"
  echo
  echo "и добавь её на GitHub: репозиторий rifmovnik-src → Settings → Deploy keys → Add deploy key."
  echo "Title — любое (например «сервер»), галочку «Allow write access» НЕ ставь."
  until git ls-remote "$GIT_URL" >/dev/null 2>&1; do
    ask "Когда добавишь — нажми Enter… " >/dev/null
  done
fi
echo "GitHub пускает ✓"

say "Забираю код"
id rifm >/dev/null 2>&1 || useradd -r -m -d /var/lib/rifmovnik -s /usr/sbin/nologin rifm
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" fetch -q origin && git -C "$DIR" reset -q --hard origin/main
else
  git clone -q "$GIT_URL" "$DIR"
fi
(cd "$DIR/server" && npm ci --omit=dev --no-audit --no-fund --loglevel=error)
chmod +x "$DIR/deploy/update.sh"

say "Настройки"
umask 077
cat > "$ENV" <<EOF
BOT_TOKEN=$BOT_TOKEN
SESSION_SECRET=$SESSION_SECRET
ADMIN_IDS=$ADMIN_IDS
DOMAIN=$DOMAIN
PORT=8080
HOST=127.0.0.1
DATA_DIR=/var/lib/rifmovnik
EOF
umask 022

cat > /etc/systemd/system/rifmovnik.service <<EOF
[Unit]
Description=Rifmovnik server
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=$ENV
User=rifm
WorkingDirectory=$DIR/server
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/rifmovnik
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# every minute: if GitHub has a new commit — take it and restart
cat > /etc/systemd/system/rifmovnik-update.service <<EOF
[Unit]
Description=Rifmovnik: pull updates from GitHub
[Service]
Type=oneshot
ExecStart=$DIR/deploy/update.sh
EOF
cat > /etc/systemd/system/rifmovnik-update.timer <<EOF
[Unit]
Description=Rifmovnik: check GitHub every minute
[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
EOF

cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
  reverse_proxy 127.0.0.1:8080
}
EOF

systemctl daemon-reload
systemctl enable --now rifmovnik >/dev/null
systemctl restart rifmovnik
systemctl enable --now rifmovnik-update.timer >/dev/null
systemctl restart caddy

say "Проверяю"
sleep 3
systemctl is-active --quiet rifmovnik && echo "сервер приложения работает ✓" || { echo "сервер не запустился:"; journalctl -u rifmovnik -n 20 --no-pager; exit 1; }

MYIP="$(curl -fsS4 https://api.ipify.org 2>/dev/null || true)"
DNSIP="$(getent ahostsv4 "$DOMAIN" | awk 'NR==1{print $1}' || true)"
if [ -n "$MYIP" ] && [ "$MYIP" != "$DNSIP" ]; then
  echo
  echo "⚠ Домен $DOMAIN пока смотрит не на этот сервер (${DNSIP:-нет записи}, а нужен $MYIP)."
  echo "  В панели домена поставь A-запись @ → $MYIP. Сертификат появится сам, когда запись обновится (до часа)."
  echo "  После этого запусти эту же команду ещё раз — она проверит и переключит бота."
  exit 0
fi

ok=""
for i in $(seq 1 20); do
  if curl -fsS "https://$DOMAIN/health" >/dev/null 2>&1; then ok=1; break; fi
  sleep 3
done
if [ -z "$ok" ]; then
  echo "https пока не поднялся (сертификат ещё выпускается). Подожди пару минут и запусти команду ещё раз."
  journalctl -u caddy -n 10 --no-pager || true
  exit 0
fi
echo "https://$DOMAIN работает ✓"

echo
SW="$(ask "Переключить кнопку «Открыть» в боте на https://$DOMAIN ? (y/n): ")"
if [ "$SW" = "y" ] || [ "$SW" = "Y" ] || [ "$SW" = "д" ]; then
  R="$(curl -fsS "https://api.telegram.org/bot$BOT_TOKEN/setChatMenuButton" \
    -H 'Content-Type: application/json' \
    -d "{\"menu_button\":{\"type\":\"web_app\",\"text\":\"Рифмовник\",\"web_app\":{\"url\":\"https://$DOMAIN/\"}}}" || true)"
  case "$R" in *'"ok":true'*) echo "кнопка в боте переключена ✓";; *) echo "не получилось: $R";; esac
  echo "Ещё в @BotFather → твой бот → Bot Settings → Configure Mini App → поменяй адрес на https://$DOMAIN/ (если он там задан)."
fi

say "Готово"
echo "Обновления с GitHub подтягиваются сами раз в минуту."
echo "Логи: journalctl -u rifmovnik -f"
