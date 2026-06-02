#!/bin/bash
set -u

PANEL="${PANEL_PATH:-/var/www/pterodactyl}"
BACKUP="${BACKUP_DIR:-/root/pterodactyl_simple_protect_backup}"
TS="$(date -u +%Y-%m-%d-%H-%M-%S)"

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
mkdir -p "$BACKUP"

cd "$PANEL" || exit 1

echo
info "=== KAHFI SIMPLE ADMIN PROTECT ==="
info "Simple rule, tidak utak-atik controller/service."
info "Panel : $PANEL"
echo

echo "1) Cek dulu web tidak ada PHP parse error..."
BROKEN=0
CHECK_TARGETS=(
  "app/Http/Kernel.php"
  "app/Http/Controllers/Admin"
  "app/Http/Controllers/Api/Client"
  "app/Services/Servers"
)

for target in "${CHECK_TARGETS[@]}"; do
  [ -e "$target" ] || continue

  if [ -f "$target" ]; then
    if ! php -l "$target" >/tmp/kahfi_simple_lint.out 2>&1; then
      bad "SYNTAX ERROR: $target"
      cat /tmp/kahfi_simple_lint.out
      BROKEN=1
    fi
  else
    while IFS= read -r file; do
      if ! php -l "$file" >/tmp/kahfi_simple_lint.out 2>&1; then
        bad "SYNTAX ERROR: $file"
        cat /tmp/kahfi_simple_lint.out
        BROKEN=1
      fi
    done < <(find "$target" -type f -name '*.php')
  fi
done

if [ "$BROKEN" -ne 0 ]; then
  bad "STOP. Web masih ada file PHP rusak. Jalankan restore web clean dulu, baru protect ini."
  exit 1
fi

ok "Syntax aman. Lanjut pasang simple protect."

echo
echo "2) Buat middleware simple protect..."
MW="app/Http/Middleware/KahfiSimpleAdminProtect.php"
cp "app/Http/Kernel.php" "$BACKUP/Kernel_before_simple_protect_${TS}.php.bak" 2>/dev/null || true

mkdir -p "$(dirname "$MW")"
cat > "$MW" <<'PHP'
<?php

namespace Pterodactyl\Http\Middleware;

use Closure;
use Illuminate\Http\Request;

class KahfiSimpleAdminProtect
{
    public function handle(Request $request, Closure $next)
    {
        $user = $request->user();

        if (!$user) {
            return $next($request);
        }

        if ((int) $user->id === 1) {
            return $next($request);
        }

        $path = trim($request->path(), '/');
        $method = strtoupper($request->method());
        $spoofMethod = strtoupper((string) $request->input('_method', ''));
        $isDelete = $method === 'DELETE' || $spoofMethod === 'DELETE';

        // Jangan ganggu panel client user sendiri:
        // /server/xxx, /api/client/servers/xxx, console, file, power, dll tetap ikut permission bawaan Pterodactyl.
        // Protect ini hanya area /admin.
        if (!str_starts_with($path, 'admin')) {
            return $next($request);
        }

        // Admin reseller boleh buka dashboard admin.
        if ($path === 'admin') {
            return $next($request);
        }

        // Admin reseller boleh lihat list user dan create user biasa.
        if ($path === 'admin/users' || str_starts_with($path, 'admin/users/new')) {
            // Tapi tetap tidak boleh membuat/menaikkan akun jadi admin/root_admin.
            $rootAdminRaw = $request->input('root_admin', false);
            $rootAdminEnabled = filter_var($rootAdminRaw, FILTER_VALIDATE_BOOLEAN);

            if ($rootAdminEnabled) {
                abort(403, '✖ KahfiModTzy Protection :: admin reseller dilarang membuat akun admin/root_admin.');
            }

            return $next($request);
        }

        // Admin reseller boleh create server manual.
        // Route Pterodactyl beda versi bisa POST /admin/servers atau /admin/servers/new.
        if (str_starts_with($path, 'admin/servers/new')) {
            return $next($request);
        }

        if ($path === 'admin/servers' && $method === 'POST') {
            return $next($request);
        }

        // Admin reseller tidak boleh lihat list server admin, detail server, manage, startup, delete, transfer, dll.
        // Server milik sendiri tetap dibuka lewat menu client /server/xxx, bukan /admin/servers/view/xxx.
        if ($path === 'admin/servers' || str_starts_with($path, 'admin/servers/')) {
            abort(403, '✖ KahfiModTzy Protection :: selain admin utama ID 1 dilarang membuka/mengubah server lewat Admin Panel.');
        }

        // Node, location, nest/egg, settings hanya admin utama.
        if (
            str_starts_with($path, 'admin/nodes') ||
            str_starts_with($path, 'admin/locations') ||
            str_starts_with($path, 'admin/nests') ||
            str_starts_with($path, 'admin/settings')
        ) {
            abort(403, '✖ KahfiModTzy Protection :: fitur ini khusus admin utama ID 1.');
        }

        // Detail/edit/delete user selain halaman list/create user diblok.
        if (str_starts_with($path, 'admin/users/')) {
            abort(403, '✖ KahfiModTzy Protection :: admin reseller dilarang membuka detail/edit/delete user.');
        }

        // PTLA/PTLC: admin reseller boleh create sendiri, tapi tidak boleh revoke/delete lewat admin panel.
        if ((str_starts_with($path, 'admin/api') || str_starts_with($path, 'admin/application-api')) && $isDelete) {
            abort(403, '✖ KahfiModTzy Protection :: admin reseller dilarang revoke/delete API key.');
        }

        return $next($request);
    }
}
PHP

php -l "$MW" || { bad "Middleware syntax error"; exit 1; }
ok "Middleware dibuat: $MW"

echo
echo "3) Register middleware ke Kernel.php secara aman..."
php <<'PHP_PATCH'
<?php
$file = '/var/www/pterodactyl/app/Http/Kernel.php';
$backupDir = '/root/pterodactyl_simple_protect_backup';
$ts = gmdate('Y-m-d-H-i-s');

if (!is_file($file)) {
    fwrite(STDERR, "Kernel.php tidak ditemukan\n");
    exit(1);
}

$src = file_get_contents($file);
if ($src === false) {
    fwrite(STDERR, "Gagal baca Kernel.php\n");
    exit(1);
}

if (strpos($src, 'KahfiSimpleAdminProtect::class') !== false) {
    echo "Kernel sudah terpasang middleware.\n";
    exit(0);
}

copy($file, rtrim($backupDir, '/') . '/Kernel_before_register_simple_protect_' . $ts . '.php.bak');

$line = "        \\Pterodactyl\\Http\\Middleware\\KahfiSimpleAdminProtect::class,\n";

$pattern = '/protected\s+\$middleware\s*=\s*\[\s*/m';
if (!preg_match($pattern, $src, $m, PREG_OFFSET_CAPTURE)) {
    fwrite(STDERR, "Tidak ketemu protected \$middleware di Kernel.php\n");
    exit(1);
}

$pos = $m[0][1] + strlen($m[0][0]);
$patched = substr($src, 0, $pos) . "\n" . $line . substr($src, $pos);

file_put_contents($file, $patched);
echo "Kernel patched.\n";
PHP_PATCH

php -l "app/Http/Kernel.php" || {
  bad "Kernel.php syntax error setelah patch. Restore backup..."
  latest="$(ls -t "$BACKUP"/Kernel_before_* 2>/dev/null | head -n 1 || true)"
  if [ -n "$latest" ]; then
    cp "$latest" "app/Http/Kernel.php"
    bad "Kernel sudah direstore dari: $latest"
  fi
  exit 1
}

ok "Kernel syntax OK."

echo
echo "4) Clear cache..."
php artisan optimize:clear >/dev/null 2>&1 || true
php artisan view:clear >/dev/null 2>&1 || true
php artisan route:clear >/dev/null 2>&1 || true
php artisan config:clear >/dev/null 2>&1 || true
php artisan cache:clear >/dev/null 2>&1 || true
php artisan queue:restart >/dev/null 2>&1 || true

chown -R www-data:www-data "$PANEL" >/dev/null 2>&1 || true

echo
ok "DONE. Simple protect aktif."
echo
echo "Rule:"
echo "- Admin utama ID 1: bebas semua."
echo "- Admin reseller: boleh create user biasa."
echo "- Admin reseller: boleh create server manual."
echo "- Admin reseller: boleh create PTLA/PTLC sendiri."
echo "- Admin reseller: server sendiri tetap lewat /server/xxx client panel."
echo "- Admin reseller: dilarang buka Admin > Servers list/detail/manage."
echo "- Admin reseller: dilarang node/location/nest/settings/detail user."
echo
echo "Wajib logout admin reseller lalu login ulang / buka incognito."
