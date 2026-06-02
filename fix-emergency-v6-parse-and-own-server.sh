#!/bin/bash
set -u

PANEL="/var/www/pterodactyl"
BACKUP="/root/pterodactyl_backups"
TS="$(date -u +%Y-%m-%d-%H-%M-%S)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

say(){ echo -e "${GREEN}$1${NC}"; }
warn(){ echo -e "${YELLOW}$1${NC}"; }
err(){ echo -e "${RED}$1${NC}"; }

[ -d "$PANEL" ] || { err "Folder panel tidak ketemu: $PANEL"; exit 1; }
mkdir -p "$BACKUP"
cd "$PANEL" || exit 1

lint_file() {
  local file="$1"
  php -l "$file" >/tmp/kahfi_php_lint.out 2>&1
}

backup_current() {
  local rel="$1"
  local abs="$PANEL/$rel"
  local safe
  safe="$(echo "$rel" | tr '/.' '__')"
  if [ -f "$abs" ]; then
    cp "$abs" "$BACKUP/${safe}_broken_before_v6_${TS}.bak"
    warn "Backup current: $rel"
  fi
}

restore_latest_good_backup() {
  local rel="$1"
  local abs="$PANEL/$rel"
  local base class tmp candidates f

  base="$(basename "$rel")"
  class="${base%.php}"

  backup_current "$rel"

  tmp="$(mktemp)"
  candidates="$(find "$BACKUP" -type f \( -name "*${class}*.bak" -o -name "*${class}*" \) -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{print $2}')"

  for f in $candidates; do
    cp "$f" "$tmp"
    if ! grep -q "class ${class}" "$tmp"; then
      continue
    fi
    if php -l "$tmp" >/dev/null 2>&1; then
      cp "$tmp" "$abs"
      rm -f "$tmp"
      say "Restored syntax-good backup for $rel from:"
      echo "$f"
      return 0
    fi
  done

  rm -f "$tmp"
  err "Tidak nemu backup syntax-good untuk $rel"
  return 1
}

patch_admin_serverscontroller_safely() {
  local file="$PANEL/app/Http/Controllers/Admin/ServersController.php"

  [ -f "$file" ] || return 0

  if ! lint_file "$file"; then
    err "ServersController masih error sebelum patch:"
    cat /tmp/kahfi_php_lint.out
    return 1
  fi

  php <<'PHP_PATCH'
<?php
$file = '/var/www/pterodactyl/app/Http/Controllers/Admin/ServersController.php';
$backupDir = '/root/pterodactyl_backups';
$ts = gmdate('Y-m-d-H-i-s');

if (!is_file($file)) exit(0);
$src = file_get_contents($file);
if ($src === false) { fwrite(STDERR, "Cannot read ServersController\n"); exit(1); }
copy($file, $backupDir . '/ServersController_before_v6_safe_patch_' . $ts . '.bak');

// Admin reseller harus tetap boleh create server.
$src = preg_replace('/\s*\$this->checkAdmin\("create"\);\s*/', "\n", $src);

if (strpos($src, 'KahfiModTzy V6 :: root or owner server access') === false) {
    $helper = <<<'PHP'

    // KahfiModTzy V6 :: root or owner server access
    private function kahfiRootOrOwner(Server $server, string $action = "access"): void
    {
        $user = Auth::user();

        if (!$user) {
            throw new DisplayException("✖ KahfiModTzy Protection :: unauthorized");
        }

        if ((int) $user->id === 1) {
            return;
        }

        $ownerId = $server->owner_id
            ?? $server->user_id
            ?? ($server->owner?->id ?? null)
            ?? ($server->user?->id ?? null);

        if ((int) $ownerId !== (int) $user->id) {
            throw new DisplayException("✖ KahfiModTzy Protection :: dilarang {$action} server orang lain");
        }
    }

PHP;
    $src = preg_replace('/class\s+ServersController\s+extends\s+Controller\s*\{/', "$0\n" . $helper, $src, 1);
}

$replacements = [
    '$this->checkAdmin("view details of");' => '$this->kahfiRootOrOwner($server, "membuka detail");',
    '$this->checkAdmin("view build config of");' => '$this->kahfiRootOrOwner($server, "membuka build");',
    '$this->checkAdmin("view startup of");' => '$this->kahfiRootOrOwner($server, "membuka startup");',
    '$this->checkAdmin("view database of");' => '$this->kahfiRootOrOwner($server, "membuka database");',
    '$this->checkAdmin("manage");' => '$this->kahfiRootOrOwner($server, "manage");',
    '$this->checkAdmin("delete");' => '$this->kahfiRootOrOwner($server, "delete");',
    '$this->checkAdmin("modify details of");' => '$this->kahfiRootOrOwner($server, "mengubah detail");',
    '$this->checkAdmin("modify container of");' => '$this->kahfiRootOrOwner($server, "mengubah container");',
    '$this->checkAdmin("modify build config of");' => '$this->kahfiRootOrOwner($server, "mengubah build");',
    '$this->checkAdmin("modify startup of");' => '$this->kahfiRootOrOwner($server, "mengubah startup");',
    '$this->checkAdmin("add database to");' => '$this->kahfiRootOrOwner($server, "mengubah database");',
    '$this->checkAdmin("reset database password of");' => '$this->kahfiRootOrOwner($server, "mengubah database");',
    '$this->checkAdmin("delete database from");' => '$this->kahfiRootOrOwner($server, "mengubah database");',
    '$this->checkAdmin("suspend/unsuspend");' => '$this->kahfiRootOrOwner($server, "suspend/unsuspend");',
    '$this->checkAdmin("reinstall");' => '$this->kahfiRootOrOwner($server, "reinstall");',
];
$src = str_replace(array_keys($replacements), array_values($replacements), $src);

file_put_contents($file, $src);
PHP_PATCH

  if ! lint_file "$file"; then
    err "ServersController error setelah patch, restore backup terakhir..."
    restore_latest_good_backup "app/Http/Controllers/Admin/ServersController.php" || true
    return 1
  fi

  say "ServersController syntax OK"
}

remove_bad_root_only_message_in_client_api() {
  php <<'PHP_PATCH'
<?php
$base = '/var/www/pterodactyl/app/Http/Controllers/Api/Client/Servers';
$backupDir = '/root/pterodactyl_backups';
$ts = gmdate('Y-m-d-H-i-s');
if (!is_dir($base)) exit(0);

$it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($base, FilesystemIterator::SKIP_DOTS));
foreach ($it as $info) {
    if (!$info->isFile() || substr($info->getFilename(), -4) !== '.php') continue;
    $file = $info->getPathname();
    $src = file_get_contents($file);
    if ($src === false) continue;
    $old = $src;

    // Ganti pesan blocker root-only yang membuat server sendiri ikut tidak bisa dibuka.
    $src = str_replace(
        '✖ KahfiModTzy Protection :: selain admin utama ID 1 dilarang membuka console/file/server.',
        '✖ KahfiModTzy Protection :: dilarang membuka server orang lain.',
        $src
    );
    $src = str_replace(
        '✖ KahfiModTzy Protection :: console, file, power, command, backup, dan client server API khusus admin utama ID 1.',
        '✖ KahfiModTzy Protection :: dilarang membuka server orang lain.',
        $src
    );

    if ($src !== $old) {
        $safe = str_replace(['/', '.'], '_', trim(str_replace('/var/www/pterodactyl/', '', $file), '/'));
        copy($file, $backupDir . '/' . $safe . '_before_v6_message_fix_' . $ts . '.bak');
        file_put_contents($file, $src);
        echo "Fixed old root-only message: $file\n";
    }
}
PHP_PATCH
}

echo "== KAHFI EMERGENCY FIX V6 =="
echo "1) Cek syntax file penting..."

BROKEN=0
FILES=(
  "app/Http/Controllers/Admin/ServersController.php"
  "app/Http/Controllers/Admin/Servers/ServerViewController.php"
  "app/Http/Controllers/Admin/Servers/CreateServerController.php"
  "app/Http/Controllers/Api/Client/ClientController.php"
)

for rel in "${FILES[@]}"; do
  if [ -f "$PANEL/$rel" ]; then
    if ! lint_file "$PANEL/$rel"; then
      warn "BROKEN: $rel"
      cat /tmp/kahfi_php_lint.out
      restore_latest_good_backup "$rel" || BROKEN=1
    fi
  fi
done

echo
echo "2) Bersihkan pesan blocker root-only lama di Client API..."
remove_bad_root_only_message_in_client_api

echo
echo "3) Patch Admin ServersController aman: create boleh, server sendiri boleh, server orang dilarang..."
patch_admin_serverscontroller_safely || BROKEN=1

echo
echo "4) Final syntax check controller/service yang sering kena patch..."
CHECK_FILES="$(find "$PANEL/app/Http/Controllers/Admin" "$PANEL/app/Http/Controllers/Api/Client" "$PANEL/app/Services/Servers" -type f -name '*.php' 2>/dev/null)"
for file in $CHECK_FILES; do
  if ! php -l "$file" >/tmp/kahfi_php_lint.out 2>&1; then
    err "SYNTAX ERROR: $file"
    cat /tmp/kahfi_php_lint.out
    BROKEN=1
  fi
done

if [ "$BROKEN" -ne 0 ]; then
  err "Masih ada syntax error. Kirim output di atas. Panel belum aman untuk lanjut."
  exit 1
fi

echo
echo "5) Clear cache..."
php artisan optimize:clear >/dev/null 2>&1 || true
php artisan view:clear >/dev/null 2>&1 || true
php artisan route:clear >/dev/null 2>&1 || true
php artisan config:clear >/dev/null 2>&1 || true
php artisan cache:clear >/dev/null 2>&1 || true
php artisan queue:restart >/dev/null 2>&1 || true

chown -R www-data:www-data "$PANEL" >/dev/null 2>&1 || true

say "DONE. Panel syntax sudah aman."
echo
echo "Rule final:"
echo "- Admin utama ID 1: full akses."
echo "- Admin reseller: boleh create server/user biasa dan boleh manage server milik sendiri."
echo "- Admin reseller: dilarang buka/manage server orang lain."
echo
echo "Wajib logout admin reseller lalu login ulang / buka incognito."
