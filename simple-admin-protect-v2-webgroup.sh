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
info "=== KAHFI SIMPLE PROTECT V2 - WEB GROUP ==="
info "Fix ini memasang middleware di web group, bukan global."
info "Jadi Auth/session kebaca dan protect benar-benar aktif."
echo

echo "1) Precheck syntax Kernel..."
php -l app/Http/Kernel.php >/tmp/kahfi_kernel_lint.out 2>&1 || {
  bad "Kernel.php masih syntax error. Benerin web dulu."
  cat /tmp/kahfi_kernel_lint.out
  exit 1
}

echo
echo "2) Buat middleware protect..."
MW="app/Http/Middleware/KahfiSimpleAdminProtect.php"
cp -a app/Http/Kernel.php "$BACKUP/Kernel_before_simple_protect_v2_${TS}.php.bak" 2>/dev/null || true
[ -f "$MW" ] && cp -a "$MW" "$BACKUP/KahfiSimpleAdminProtect_before_v2_${TS}.php.bak" 2>/dev/null || true

cat > "$MW" <<'PHP'
<?php

namespace Pterodactyl\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;

class KahfiSimpleAdminProtect
{
    public function handle(Request $request, Closure $next)
    {
        $user = Auth::user() ?: $request->user();

        // Kalau belum login, biarkan auth bawaan Pterodactyl yang proses.
        if (!$user) {
            return $next($request);
        }

        // Admin utama ID 1 bebas semua.
        if ((int) $user->id === 1) {
            return $next($request);
        }

        $path = trim($request->path(), '/');
        $method = strtoupper($request->method());
        $spoof = strtoupper((string) $request->input('_method', ''));
        $isDelete = $method === 'DELETE' || $spoof === 'DELETE';
        $isPost = $method === 'POST' || $method === 'PUT' || $method === 'PATCH' || $spoof === 'PUT' || $spoof === 'PATCH';

        // Jangan ganggu client panel.
        // Server milik sendiri tetap ikut permission bawaan Pterodactyl di /server/xxx dan /api/client/servers/xxx.
        if (!str_starts_with($path, 'admin')) {
            return $next($request);
        }

        // Dashboard admin reseller masih boleh.
        if ($path === 'admin') {
            return $next($request);
        }

        // Create user biasa boleh, tapi root_admin/admin dilarang.
        if ($path === 'admin/users' || str_starts_with($path, 'admin/users/new')) {
            $rootAdminRaw = $request->input('root_admin', false);
            $rootAdminEnabled = filter_var($rootAdminRaw, FILTER_VALIDATE_BOOLEAN);

            if ($rootAdminEnabled) {
                abort(403, '✖ KahfiModTzy Protection :: admin reseller dilarang membuat admin/root_admin.');
            }

            return $next($request);
        }

        // Detail/edit/delete user dilarang.
        if (str_starts_with($path, 'admin/users/')) {
            abort(403, '✖ KahfiModTzy Protection :: admin reseller dilarang membuka detail/edit/delete user.');
        }

        // Create server manual boleh.
        if (str_starts_with($path, 'admin/servers/new')) {
            return $next($request);
        }

        // Submit create server manual boleh.
        if ($path === 'admin/servers' && $method === 'POST') {
            return $next($request);
        }

        // Endpoint pembantu create server manual, kalau dipakai theme/panel.
        if ($method === 'GET' && preg_match('#^admin/nodes/view/[^/]+/allocations#', $path)) {
            return $next($request);
        }

        if ($method === 'GET' && preg_match('#^admin/nests/[^/]+/eggs#', $path)) {
            return $next($request);
        }

        if ($method === 'GET' && preg_match('#^admin/nests/egg/[^/]+#', $path)) {
            return $next($request);
        }

        // Admin reseller tidak boleh buka list/detail/manage server dari Admin Panel.
        // Server sendiri tetap dibuka lewat client panel /server/xxx.
        if ($path === 'admin/servers' || str_starts_with($path, 'admin/servers/')) {
            abort(403, '✖ KahfiModTzy Protection :: admin reseller dilarang membuka/mengubah server lewat Admin Panel.');
        }

        // Node/location/nest/settings page dilarang.
        // Pengecualian endpoint create-server helper di atas sudah di-allow.
        if (
            str_starts_with($path, 'admin/nodes') ||
            str_starts_with($path, 'admin/locations') ||
            str_starts_with($path, 'admin/nests') ||
            str_starts_with($path, 'admin/settings')
        ) {
            abort(403, '✖ KahfiModTzy Protection :: fitur ini khusus admin utama ID 1.');
        }

        // Admin reseller boleh create PTLA/PTLC sendiri, tapi revoke/delete dilarang.
        if ((str_starts_with($path, 'admin/api') || str_starts_with($path, 'admin/application-api')) && $isDelete) {
            abort(403, '✖ KahfiModTzy Protection :: admin reseller dilarang revoke/delete API key.');
        }

        return $next($request);
    }
}
PHP

php -l "$MW" || { bad "Middleware syntax error"; exit 1; }
ok "Middleware OK."

echo
echo "3) Register middleware ke Kernel web group..."
php <<'PHP_PATCH'
<?php
$file = '/var/www/pterodactyl/app/Http/Kernel.php';
$backupDir = '/root/pterodactyl_simple_protect_backup';
$ts = gmdate('Y-m-d-H-i-s');
$line = '            \Pterodactyl\Http\Middleware\KahfiSimpleAdminProtect::class,';

$src = file_get_contents($file);
if ($src === false) {
    fwrite(STDERR, "Gagal baca Kernel.php\n");
    exit(1);
}

copy($file, $backupDir . '/Kernel_before_register_webgroup_v2_' . $ts . '.php.bak');

// Hapus duplicate line lama di mana pun, lalu kita pasang tepat di web group.
$src = str_replace([
    "        \\Pterodactyl\\Http\\Middleware\\KahfiSimpleAdminProtect::class,\n",
    "            \\Pterodactyl\\Http\\Middleware\\KahfiSimpleAdminProtect::class,\n",
], '', $src);

$needle = "'web' => [";
$pos = strpos($src, $needle);
if ($pos === false) {
    $needle = '"web" => [';
    $pos = strpos($src, $needle);
}

if ($pos === false) {
    fwrite(STDERR, "Tidak ketemu middlewareGroups web di Kernel.php\n");
    exit(1);
}

$open = strpos($src, '[', $pos);
if ($open === false) {
    fwrite(STDERR, "Tidak ketemu bracket web group\n");
    exit(1);
}

// Cari penutup array web group dengan hitung bracket.
$depth = 0;
$end = null;
$len = strlen($src);
for ($i = $open; $i < $len; $i++) {
    $ch = $src[$i];
    if ($ch === '[') {
        $depth++;
    } elseif ($ch === ']') {
        $depth--;
        if ($depth === 0) {
            $end = $i;
            break;
        }
    }
}

if ($end === null) {
    fwrite(STDERR, "Tidak ketemu akhir web group\n");
    exit(1);
}

// Pasang di akhir web group agar session/auth sudah kebaca.
$src = substr($src, 0, $end) . "\n" . $line . "\n        " . substr($src, $end);

file_put_contents($file, $src);
echo "Registered in web group.\n";
PHP_PATCH

php -l app/Http/Kernel.php >/tmp/kahfi_kernel_lint2.out 2>&1 || {
  bad "Kernel.php syntax error setelah patch. Restore backup."
  cat /tmp/kahfi_kernel_lint2.out
  latest="$(ls -t "$BACKUP"/Kernel_before_register_webgroup_v2_* 2>/dev/null | head -n 1 || true)"
  if [ -n "$latest" ]; then
    cp -a "$latest" app/Http/Kernel.php
    warn "Restored Kernel dari: $latest"
  fi
  exit 1
}
ok "Kernel OK."

echo
echo "4) Clear cache + restart service supaya opcache tidak pakai file lama..."
php artisan optimize:clear >/dev/null 2>&1 || true
php artisan view:clear >/dev/null 2>&1 || true
php artisan route:clear >/dev/null 2>&1 || true
php artisan config:clear >/dev/null 2>&1 || true
php artisan cache:clear >/dev/null 2>&1 || true
php artisan queue:restart >/dev/null 2>&1 || true

# Restart PHP-FPM jika tersedia, supaya opcache pasti reload.
for svc in php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm; do
  if systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
    systemctl restart "$svc" >/dev/null 2>&1 && ok "Restarted $svc"
  fi
done

systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || true

chown -R www-data:www-data "$PANEL" >/dev/null 2>&1 || true

echo
ok "DONE. Protect V2 aktif di WEB GROUP."
echo
echo "Tes cepat:"
echo "1. Login admin selain ID 1."
echo "2. Buka /admin/servers"
echo "   Harus 403 / Protection."
echo "3. Buka /admin/servers/new"
echo "   Harus boleh create server."
echo "4. Buka /server/xxx milik sendiri"
echo "   Harus tetap bisa."
echo
echo "Cek middleware terpasang:"
echo "grep -n \"KahfiSimpleAdminProtect\" $PANEL/app/Http/Kernel.php"
echo
echo "Wajib logout admin reseller lalu login ulang / pakai incognito."
