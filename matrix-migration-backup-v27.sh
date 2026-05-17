#!/bin/bash
# ============================================================
#  Matrix v2.7  →  v0.7.0 migration backup
#  Делает архив со старого сервера (matrix-install-v2.7),
#  совместимый с пунктом 7 нового install.sh
#  (Восстановление с другого сервера).
#
#  Использование:
#    bash matrix-migration-backup-v27.sh           # сделать бэкап
#    bash matrix-migration-backup-v27.sh --purge   # стереть сервер
#                                                  # (архивы сохраняются)
# ============================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
info()    { echo -e "${BLUE}[i]${NC} $1"; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }
die()     { echo -e "${RED}[✗]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && die "Запускай от root"

BACKUP_DIR="/root/backup"

# ══════════════════════════════════════════════════════════
#  PURGE — стереть сервер (архивы остаются)
# ══════════════════════════════════════════════════════════
if [ "$1" = "--purge" ]; then
  section "Очистка старого сервера"
  echo ""
  warn "ВНИМАНИЕ: будут удалены:"
  echo "    • matrix-synapse (пакет + /etc/matrix-synapse + /var/lib/matrix-synapse)"
  echo "    • БД synapse в PostgreSQL"
  echo "    • Element Web + Synapse Admin (/var/www/html/{element,admin})"
  echo "    • nginx-конфиг matrix, well-known, сертификаты Let's Encrypt"
  echo "    • coturn (/etc/turnserver.conf)"
  echo "    • /root/.matrix_secrets, /root/.matrix_pg_pass"
  echo "    • cron-задачи matrix/element/certbot"
  echo "    • утилиты matrix-* в /usr/local/bin"
  echo ""
  echo "  Папка $BACKUP_DIR с архивами останется нетронутой."
  echo ""
  read -rp "  Точно стереть? Напиши 'erase' для подтверждения: " CONFIRM
  [ "$CONFIRM" != "erase" ] && die "Отмена"

  systemctl stop matrix-synapse 2>/dev/null || true
  systemctl stop coturn 2>/dev/null || true
  systemctl disable matrix-synapse 2>/dev/null || true
  systemctl disable coturn 2>/dev/null || true

  DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq matrix-synapse-py3 2>/dev/null || true

  if systemctl is-active --quiet postgresql; then
    su -c "dropdb --if-exists synapse" postgres 2>/dev/null || true
    su -c "psql -c \"DROP USER IF EXISTS synapse;\"" postgres 2>/dev/null || true
  fi

  rm -rf /etc/matrix-synapse /var/lib/matrix-synapse
  rm -rf /var/www/html/element /var/www/html/admin /var/www/html/.well-known
  rm -f  /etc/nginx/sites-enabled/matrix /etc/nginx/sites-available/matrix
  rm -f  /etc/nginx/sites-enabled/matrix-temp /etc/nginx/sites-available/matrix-temp
  rm -rf /etc/letsencrypt
  rm -f  /etc/turnserver.conf
  rm -f  /root/.matrix_secrets /root/.matrix_pg_pass
  rm -f  /etc/cron.d/matrix-media-cleanup /etc/cron.d/element-update /etc/cron.d/certbot-renew
  rm -f  /usr/local/bin/matrix-* /usr/local/bin/update-element
  rm -f  /etc/apt/sources.list.d/matrix-org.list /usr/share/keyrings/matrix-org-archive-keyring.gpg

  systemctl reload nginx 2>/dev/null || true

  echo ""
  log "Сервер очищен. Архивы в $BACKUP_DIR не тронуты."
  ls -lh "$BACKUP_DIR" 2>/dev/null || true
  exit 0
fi

# ══════════════════════════════════════════════════════════
#  BACKUP
# ══════════════════════════════════════════════════════════
section "Бэкап для переезда (v2.7 → v0.7.0)"

# ── Проверки наличия ────────────────────────────────────────
[ -f /etc/matrix-synapse/homeserver.yaml ] \
  || die "Не найден /etc/matrix-synapse/homeserver.yaml — это точно старый сервер?"
[ -f /root/.matrix_secrets ]  || die "Не найден /root/.matrix_secrets"
[ -f /root/.matrix_pg_pass ]  || die "Не найден /root/.matrix_pg_pass"

# Зависимости (на случай чистой системы)
command -v jq      >/dev/null || apt-get install -y -qq jq
command -v pg_dump >/dev/null || warn "pg_dump не найден — БД попадёт через postgres user"

# ── Извлечение текущих параметров ───────────────────────────
DOMAIN=$(grep '^server_name:' /etc/matrix-synapse/homeserver.yaml \
  | head -1 | sed 's/server_name: *"\?\([^"]*\)"\?/\1/' | tr -d ' ')
[ -z "$DOMAIN" ] && die "Не удалось определить DOMAIN из homeserver.yaml"

PG_PASS=$(cat /root/.matrix_pg_pass)
# REGISTRATION_SECRET, MACAROON_SECRET, TURN_SECRET
. /root/.matrix_secrets

info "Текущий домен Matrix: $DOMAIN"
echo ""

# ── Опросные данные ────────────────────────────────────────
echo "  Новый install.sh при восстановлении требует домен LiveKit."
echo "  Можно указать любой свободный поддомен — LiveKit на новом сервере"
echo "  поднимется отдельно, пользователи Element продолжат работать."
echo ""
read -rp "  Домен LiveKit для нового сервера (например livekit.${DOMAIN}): " LIVEKIT_DOMAIN
[ -z "$LIVEKIT_DOMAIN" ] && LIVEKIT_DOMAIN="livekit.${DOMAIN}"
info "LIVEKIT_DOMAIN = $LIVEKIT_DOMAIN"

read -rp "  Email для Let's Encrypt (был использован при установке): " LE_EMAIL
[ -z "$LE_EMAIL" ] && die "Email обязателен"

read -rp "  Имя администратора (без @ и :домен), например admin: " ADMIN_USER
[ -z "$ADMIN_USER" ] && die "Имя админа обязательно"

echo ""
read -rp "  Включить медиафайлы в архив? Может быть много гигабайт. (y/n): " WM
WITH_MEDIA="no"
[[ "$WM" =~ ^[yY]$ ]] && WITH_MEDIA="yes"

# ── Подготовка ─────────────────────────────────────────────
mkdir -p "$BACKUP_DIR"
TS=$(date +%Y-%m-%d_%H-%M)
TMP=$(mktemp -d)
OUT="$BACKUP_DIR/matrix-migration-$TS.tar.gz"

# ── matrix_secrets в новом формате ─────────────────────────
info "Формирую matrix_secrets в новом формате..."
cat > "$TMP/matrix_secrets" <<EOF
DOMAIN='$DOMAIN'
LIVEKIT_DOMAIN='$LIVEKIT_DOMAIN'
LE_EMAIL='$LE_EMAIL'
ADMIN_USER='$ADMIN_USER'
PG_PASS='$PG_PASS'
REGISTRATION_SECRET='$REGISTRATION_SECRET'
MACAROON_SECRET='$MACAROON_SECRET'
TURN_SECRET='$TURN_SECRET'
EOF
chmod 600 "$TMP/matrix_secrets"

# ── Дамп PostgreSQL ────────────────────────────────────────
section "PostgreSQL"
info "Дамп БД synapse..."
su -c "pg_dump -Fc synapse" postgres > "$TMP/synapse.dump"
DBSIZE=$(du -sh "$TMP/synapse.dump" | cut -f1)
log "synapse.dump — $DBSIZE"

# ── Конфиги Synapse (включая signing.key) ──────────────────
section "Конфиги"
info "Копирую /etc/matrix-synapse → matrix-synapse-conf"
cp -r /etc/matrix-synapse "$TMP/matrix-synapse-conf"
log "Конфиги скопированы (signing.key включён)"

# ── Сертификаты ────────────────────────────────────────────
if [ -d /etc/letsencrypt ]; then
  info "Сертификаты Let's Encrypt..."
  cp -a /etc/letsencrypt "$TMP/letsencrypt"
  log "Сертификаты добавлены"
fi

# ── Nginx конфиг ───────────────────────────────────────────
if [ -f /etc/nginx/sites-available/matrix ]; then
  info "Nginx конфиг (убираю блок Synapse Admin /admin/)..."
  # Synapse Admin не переносится — убираем location /admin/ из конфига
  awk '
    /location \/admin\/ {/ { skip = 1; depth = 1; next }
    skip {
      n_open  = gsub(/{/, "{")
      n_close = gsub(/}/, "}")
      depth += n_open - n_close
      if (depth <= 0) { skip = 0 }
      next
    }
    { print }
  ' /etc/nginx/sites-available/matrix > "$TMP/nginx-matrix"
  log "nginx-matrix готов"
fi

# ── coturn ─────────────────────────────────────────────────
if [ -f /etc/turnserver.conf ]; then
  info "coturn..."
  cp /etc/turnserver.conf "$TMP/turnserver.conf"
  log "turnserver.conf добавлен"
fi

# ── Element Web (с config.json) ────────────────────────────
if [ -d /var/www/html/element ]; then
  section "Element Web"
  info "Копирую /var/www/html/element..."
  cp -r /var/www/html/element "$TMP/element-web"
  log "Element Web добавлен"
fi

# ── Well-known ─────────────────────────────────────────────
if [ -d /var/www/html/.well-known ]; then
  info "well-known..."
  cp -r /var/www/html/.well-known "$TMP/well-known"
fi

# ── Cron-задачи ────────────────────────────────────────────
section "Cron"
mkdir -p "$TMP/cron"
for f in /etc/cron.d/matrix-* /etc/cron.d/certbot-renew /etc/cron.d/element-update; do
  [ -f "$f" ] && cp "$f" "$TMP/cron/"
done
log "Cron-задачи добавлены"

# ── Утилиты matrix-* ───────────────────────────────────────
mkdir -p "$TMP/utilities"
for f in /usr/local/bin/matrix-* /usr/local/bin/update-element; do
  [ -f "$f" ] && cp "$f" "$TMP/utilities/"
done
log "Утилиты добавлены"

# ── Медиа ──────────────────────────────────────────────────
section "Медиа"
if [ "$WITH_MEDIA" = "yes" ] && [ -d /var/lib/matrix-synapse/media ]; then
  MEDIASIZE=$(du -sh /var/lib/matrix-synapse/media | cut -f1)
  info "Копирую медиа ($MEDIASIZE)..."
  cp -r /var/lib/matrix-synapse/media "$TMP/media"
  log "Медиа добавлено"
else
  warn "Медиа НЕ включено — старые картинки/видео в чатах будут битые"
fi

# ── Маркер версии ──────────────────────────────────────────
cat > "$TMP/MIGRATION_INFO" <<EOF
source_version=matrix-install-v2.7
target_version=install.sh-v0.7.0
created=$(date -Iseconds)
domain=$DOMAIN
livekit_domain=$LIVEKIT_DOMAIN
admin_user=$ADMIN_USER
with_media=$WITH_MEDIA
EOF

# ── Упаковка ───────────────────────────────────────────────
section "Упаковка"
info "Создаю $OUT ..."
tar -czf "$OUT" -C "$TMP" .
rm -rf "$TMP"
chmod 600 "$OUT"

SIZE=$(du -sh "$OUT" | cut -f1)
echo ""
log "Готово: $OUT ($SIZE)"
echo ""

# ── Итог ───────────────────────────────────────────────────
cat <<EOF
${CYAN}${BOLD}Что дальше:${NC}

  1. Скачай архив на новый сервер:
     ${BOLD}scp $OUT root@НОВЫЙ_IP:/root/${NC}

  2. На новом сервере направь DNS:
     • $DOMAIN          → IP нового сервера
     • $LIVEKIT_DOMAIN  → IP нового сервера

  3. На новом сервере запусти новый install.sh:
     ${BOLD}bash install.sh${NC}
     → пункт ${BOLD}7${NC} (Восстановление с другого сервера)
     → укажи путь: /root/$(basename "$OUT")

  4. После того как новый сервер заработает и пользователи зайдут —
     стирай старый сервер:
     ${BOLD}bash $(basename "$0") --purge${NC}
     (архивы в $BACKUP_DIR останутся)

EOF
