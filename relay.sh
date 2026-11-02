#!/usr/bin/env bash
# Рифмовник — посредник к Telegram на сервере за границей (чистая Ubuntu 22.04 / 24.04).
# Основной сервер в России не достаёт до api.telegram.org, поэтому бот не может написать первым
# (уведомления, рассылка). Этот маленький сервер пересылает запросы основного сервера в Telegram.
# Запуск от root одной строкой:
#   curl -fsSL https://raw.githubusercontent.com/tilman-prod/rifmovnik/main/relay.sh | bash
# Секретный адрес создаётся здесь же, на сервере; токен бота сюда не нужен и тут не хранится.
# Повторный запуск ничего не ломает и оставляет тот же адрес.
set -euo pipefail

say() { printf '\n\033[1;35m▸ %s\033[0m\n' "$*"; }
[ "$(id -u)" = 0 ] || { echo "Нужен root. Зайди в консоль под root и запусти ещё раз."; exit 1; }

say "Рифмовник: посредник к Telegram"
export DEBIAN_FRONTEND=noninteractive

if ! command -v caddy >/dev/null; then
  say "Ставлю Caddy (веб-сервер с автоматическим https)"
  apt-get update -q >/dev/null
  apt-get install -yq debian-keyring debian-archive-keyring apt-transport-https curl gpg >/dev/null
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -q >/dev/null
  apt-get install -yq caddy >/dev/null
fi

# the server's own address; the domain comes for free from sslip.io (1-2-3-4.sslip.io → 1.2.3.4), so https works without buying a domain
IP="$(curl -4fsS https://api.ipify.org || curl -4fsS https://ifconfig.me)"
[ -n "$IP" ] || { echo "Не смог узнать адрес сервера."; exit 1; }
HOST="${IP//./-}.sslip.io"

SECRET_FILE=/etc/rifmovnik-relay.secret
[ -s "$SECRET_FILE" ] || (umask 077; head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 28 > "$SECRET_FILE")
SECRET="$(cat "$SECRET_FILE")"

say "Настраиваю пересылку"
cat > /etc/caddy/Caddyfile <<EOF
$HOST {
  # only requests that know the secret path are passed on to Telegram; everything else gets 404
  handle_path /$SECRET/* {
    reverse_proxy https://api.telegram.org {
      header_up Host api.telegram.org
    }
  }
  respond 404
}
EOF
if command -v ufw >/dev/null && ufw status | grep -q active; then ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; fi
systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy

say "Проверяю (до минуты: сертификат https выпускается в первый раз)"
OK=""
for i in $(seq 1 30); do
  if curl -sS -m 10 "https://$HOST/$SECRET/" -o /dev/null -w '%{http_code}' 2>/dev/null | grep -qE '^(200|302|404)$'; then OK=1; break; fi
  sleep 2
done
[ -n "$OK" ] && echo "Посредник отвечает." || echo "Пока не отвечает — подожди минуту и запусти скрипт ещё раз."

cat <<EOF

────────────────────────────────────────────────────────────
Готово. Теперь на ОСНОВНОМ сервере Рифмовника (в Москве/Новосибирске),
в его консоли, выполни одну строку:

  echo 'TG_API=https://$HOST/$SECRET/' >> /etc/rifmovnik.env && systemctl restart rifmovnik

Потом в приложении: Админка → Настройки → Бот → «Исходящие в Telegram» → «Проверить».
Должно быть «Работают».

Адрес с секретом никому не пересылай: через него можно говорить с Telegram от имени сервера
(без токена бота это бесполезно, но всё равно).
────────────────────────────────────────────────────────────
EOF
