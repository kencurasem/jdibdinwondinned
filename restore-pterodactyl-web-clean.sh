#!/bin/bash
set -u

PANEL="${PANEL_PATH:-/var/www/pterodactyl}"
BACKUP="${BACKUP_DIR:-/root/pterodactyl_repair_backup}"
VERSION="${PTERO_VERSION:-v1.12.3}"
TS="$(date -u +%Y-%m-%d-%H-%M-%S)"
WORK="/tmp/ptero_web_restore_${TS}_$$"
TAR="$WORK/panel.tar.gz"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok(){ echo -e "${GREEN}$1${NC}"; }
warn(){ echo -e "${YELLOW}$1${NC}"; }
info(){ echo -e "${CYAN}$1${NC}"; }
bad(){ echo -e "${RED}$1${NC}"; }

[ -d "$PANEL" ] || { bad "Panel tidak ketemu: $PANEL"; exit 1; }

mkdir -p "$BACKUP" "$WORK"
cd "$PANEL" || exit 1

echo
info "=== RESTORE WEB PANEL PTERODACTYL KE FILE RESMI ==="
info "INI BUKAN PATCH PROTECT."
info "Tujuan: balikin web dari 500 / syntax error dulu."
info "Panel   : $PANEL"
info "Backup  : $BACKUP"
info "Version : $VERSION"
echo

download_panel_source() {
  local urls=(
    "https://github.com/pterodactyl/panel/releases/download/${VERSION}/panel.tar.gz"
    "https://github.com/pterodactyl/panel/archive/refs/tags/${VERSION}.tar.gz"
    "https://codeload.github.com/pterodactyl/panel/tar.gz/refs/tags/${VERSION}"
  )

  for url in "${urls[@]}"; do
    info "Mencoba download source:"
    echo "$url"

    rm -f "$TAR"

    if command -v curl >/dev/null 2>&1; then
      curl -L --fail --connect-timeout 20 --max-time 240 "$url" -o "$TAR" && [ -s "$TAR" ] && return 0
    elif command -v wget >/dev/null 2>&1; then
      wget -O "$TAR" "$url" && [ -s "$TAR" ] && return 0
    else
      bad "curl/wget tidak ada."
      return 1
    fi
  done

  return 1
}

find_source_root() {
  tar -xzf "$TAR" -C "$WORK" || return 1

  if [ -d "$WORK/app/Http/Controllers" ]; then
    echo "$WORK"
    return 0
  fi

  find "$WORK" -type d -path "*/app/Http/Controllers" -print -quit | sed 's#/app/Http/Controllers##'
}

backup_path() {
  local rel="$1"
  local src="$PANEL/$rel"
  local safe
  safe="$(echo "$rel" | tr '/.' '__')"

  if [ -e "$src" ]; then
    mkdir -p "$BACKUP/$TS"
    cp -a "$src" "$BACKUP/$TS/${safe}"
    warn "Backup: $rel"
  fi
}

restore_file() {
  local srcroot="$1"
  local rel="$2"

  if [ ! -f "$srcroot/$rel" ]; then
    warn "Skip file, tidak ada di source resmi: $rel"
    return 0
  fi

  backup_path "$rel"
  mkdir -p "$(dirname "$PANEL/$rel")"
  cp -a "$srcroot/$rel" "$PANEL/$rel"
  chown www-data:www-data "$PANEL/$rel" 2>/dev/null || true
  chmod 644 "$PANEL/$rel" 2>/dev/null || true
  ok "Restore file: $rel"
}

restore_dir() {
  local srcroot="$1"
  local rel="$2"

  if [ ! -d "$srcroot/$rel" ]; then
    warn "Skip folder, tidak ada di source resmi: $rel"
    return 0
  fi

  backup_path "$rel"
  rm -rf "$PANEL/$rel"
  mkdir -p "$(dirname "$PANEL/$rel")"
  cp -a "$srcroot/$rel" "$PANEL/$rel"
  chown -R www-data:www-data "$PANEL/$rel" 2>/dev/null || true
  find "$PANEL/$rel" -type f -name '*.php' -exec chmod 644 {} \; 2>/dev/null || true
  ok "Restore folder: $rel"
}

lint_scope() {
  local failed=0

  echo
  info "Cek syntax PHP di bagian yang tadi rusak..."

  local targets=(
    "$PANEL/app/Http/Controllers/Api/Client/ClientController.php"
    "$PANEL/app/Http/Controllers/Api/Client/Servers"
    "$PANEL/app/Http/Controllers/Admin/ServersController.php"
    "$PANEL/app/Http/Controllers/Admin/Servers"
    "$PANEL/app/Services/Servers"
  )

  for t in "${targets[@]}"; do
    [ -e "$t" ] || continue

    if [ -f "$t" ]; then
      if ! php -l "$t" >/tmp/ptero_lint.out 2>&1; then
        bad "SYNTAX ERROR: ${t#$PANEL/}"
        cat /tmp/ptero_lint.out
        failed=1
      fi
    else
      while IFS= read -r f; do
        if ! php -l "$f" >/tmp/ptero_lint.out 2>&1; then
          bad "SYNTAX ERROR: ${f#$PANEL/}"
          cat /tmp/ptero_lint.out
          failed=1
        fi
      done < <(find "$t" -type f -name '*.php')
    fi
  done

  return "$failed"
}

echo "1) Download source resmi Pterodactyl..."
if ! download_panel_source; then
  bad "Gagal download source resmi."
  echo
  echo "Coba cek internet VPS:"
  echo "curl -I https://github.com"
  exit 1
fi

SRCROOT="$(find_source_root)"
if [ -z "$SRCROOT" ] || [ ! -d "$SRCROOT/app" ]; then
  bad "Gagal menemukan folder source setelah extract."
  exit 1
fi

ok "Source resmi ditemukan: $SRCROOT"
echo

echo "2) Restore bagian web/controller/service yang rusak..."
restore_file "$SRCROOT" "app/Http/Controllers/Api/Client/ClientController.php"
restore_dir  "$SRCROOT" "app/Http/Controllers/Api/Client/Servers"
restore_file "$SRCROOT" "app/Http/Controllers/Admin/ServersController.php"
restore_dir  "$SRCROOT" "app/Http/Controllers/Admin/Servers"
restore_dir  "$SRCROOT" "app/Services/Servers"

echo
echo "3) Cek syntax..."
if ! lint_scope; then
  bad "Masih ada syntax error. Panel belum aman."
  echo "Backup ada di: $BACKUP/$TS"
  exit 1
fi

ok "Syntax PHP bagian web/controller/service sudah aman."

echo
echo "4) Clear cache Laravel/Pterodactyl..."
php artisan optimize:clear || true
php artisan view:clear || true
php artisan route:clear || true
php artisan config:clear || true
php artisan cache:clear || true
php artisan queue:restart || true

chown -R www-data:www-data "$PANEL" 2>/dev/null || true

echo
ok "SELESAI. Sekarang web panel harusnya sudah tidak 500."
echo
echo "Kalau masih 500, jalankan ini lalu kirim outputnya:"
echo "cd $PANEL && tail -n 120 storage/logs/laravel-*.log"
echo
echo "Catatan:"
echo "- Script ini hanya restore web supaya normal."
echo "- Tidak memasang proteksi apa pun."
echo "- Jangan jalankan script protect lama dulu."
