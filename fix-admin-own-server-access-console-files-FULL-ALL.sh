#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# KAHFI FULL ALL PROTECT PTERODACTYL PANEL
# Nama file:
#   fix-admin-own-server-access-console-files.sh
#
# FUNGSI UTAMA:
# - Admin utama bebas akses semua.
# - Admin selain utama hanya boleh akses server miliknya sendiri.
# - Protect console, files, backups, databases, schedules,
#   startup, network, settings, websocket, power, command,
#   reinstall, rename, allocations, subusers, activity, dll.
# - Protect admin panel:
#   admin selain utama tidak boleh lihat list semua server,
#   tidak boleh buka user detail, API key admin, nodes,
#   locations, nests, mounts, settings, system, roles, dll.
# - Admin selain utama tetap boleh:
#   - create user biasa / member
#   - create server manual
#   - manage server miliknya sendiri
#
# CARA INSTALL:
#   MAIN_ADMIN_ID=1 bash fix-admin-own-server-access-console-files.sh
#
# Kalau folder panel bukan /var/www/pterodactyl:
#   MAIN_ADMIN_ID=1 bash fix-admin-own-server-access-console-files.sh /path/panel
#
# ==========================================================

MAIN_ADMIN_ID="${MAIN_ADMIN_ID:-1}"
PANEL_DIR="${1:-}"

log() { echo "[KAHFI-FULL-PROTECT] $*"; }
warn() { echo "[KAHFI-FULL-PROTECT-WARN] $*" >&2; }
fail() { echo "[KAHFI-FULL-PROTECT-ERROR] $*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  fail "Jalankan sebagai root di VPS panel, bukan Termux lokal."
fi

# Deteksi folder panel otomatis.
if [ -z "$PANEL_DIR" ]; then
  for d in /var/www/pterodactyl /var/www/panel /var/www/html /srv/pterodactyl "$PWD"; do
    if [ -f "$d/artisan" ] && [ -d "$d/app" ] && [ -d "$d/routes" ]; then
      PANEL_DIR="$d"
      break
    fi
  done
fi

[ -n "$PANEL_DIR" ] || fail "Folder panel tidak ketemu. Contoh: MAIN_ADMIN_ID=1 bash $0 /var/www/pterodactyl"
[ -f "$PANEL_DIR/artisan" ] || fail "File artisan tidak ada di $PANEL_DIR"

cd "$PANEL_DIR"
log "Panel directory: $PANEL_DIR"
log "Main admin ID: $MAIN_ADMIN_ID"

TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="/root/kahfi-pterodactyl-full-protect-backup-$TS"
mkdir -p "$BACKUP_DIR"

backup_file() {
  local f="$1"
  if [ -f "$f" ]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR/$f"
    log "Backup: $f"
  fi
}

backup_file ".env"
backup_file "app/Providers/AppServiceProvider.php"
backup_file "app/Policies/ServerPolicy.php"
backup_file "app/Http/Kernel.php"

# Simpan ID admin utama di .env
if grep -q '^KAHFI_MAIN_ADMIN_ID=' .env 2>/dev/null; then
  sed -i "s/^KAHFI_MAIN_ADMIN_ID=.*/KAHFI_MAIN_ADMIN_ID=${MAIN_ADMIN_ID}/" .env
else
  printf '\nKAHFI_MAIN_ADMIN_ID=%s\n' "$MAIN_ADMIN_ID" >> .env
fi

mkdir -p app/Http/Middleware

cat > app/Http/Middleware/KahfiFullAdminProtect.php <<'PHP'
<?php

namespace Pterodactyl\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Arr;
use Pterodactyl\Models\Server;
use Symfony\Component\HttpFoundation\Response;

class KahfiFullAdminProtect
{
    public function handle(Request $request, Closure $next): Response
    {
        $user = $request->user();

        if (!$user || !$user->root_admin) {
            return $next($request);
        }

        $mainAdminId = (int) env('KAHFI_MAIN_ADMIN_ID', 1);

        if ((int) $user->id === $mainAdminId) {
            return $next($request);
        }

        /*
         * Admin selain utama:
         * root_admin bawaan Pterodactyl biasanya bisa tembus semua.
         * Middleware ini memaksa admin selain utama hanya boleh ke server owner_id miliknya.
         */

        $adminBlock = $this->blockedAdminArea($request);
        if ($adminBlock !== null) {
            return $adminBlock;
        }

        $createUserBlock = $this->blockCreatingAnotherAdmin($request);
        if ($createUserBlock !== null) {
            return $createUserBlock;
        }

        $server = $this->serverFromRequest($request);

        if ($server instanceof Server && (int) $server->owner_id !== (int) $user->id) {
            return $this->deny($request, 'Akses ditolak. Admin hanya boleh mengakses server miliknya sendiri.');
        }

        /*
         * Filter list server di client API.
         * Ini mencegah admin selain utama melihat semua server dari dashboard client.
         */
        if ($this->isClientServerList($request)) {
            $response = $next($request);
            return $this->filterClientServerList($request, $response);
        }

        return $next($request);
    }

    private function blockedAdminArea(Request $request): ?Response
    {
        $path = trim($request->path(), '/');

        /*
         * Admin selain utama tidak boleh lihat semua server.
         * Tetap boleh:
         * - /admin/servers/new
         * - POST /admin/servers/new
         * - /admin/servers/view/{server} kalau owner_id server itu miliknya sendiri
         */
        if ($path === 'admin/servers' || $path === 'admin/servers/') {
            return $this->deny($request, 'Akses list semua server hanya untuk admin utama.');
        }

        /*
         * Area admin yang wajib khusus admin utama.
         * Ini biar admin selain utama tidak bisa utak-atik panel global,
         * node, nests/eggs, mounts, settings, API key, system, dll.
         */
        $mainOnlyPrefixes = [
            'admin/api',
            'admin/api/',
            'admin/settings',
            'admin/settings/',
            'admin/nodes',
            'admin/nodes/',
            'admin/locations',
            'admin/locations/',
            'admin/nests',
            'admin/nests/',
            'admin/mounts',
            'admin/mounts/',
            'admin/databases',
            'admin/databases/',
            'admin/users/view',
            'admin/users/view/',
            'admin/users/edit',
            'admin/users/edit/',
            'admin/users/delete',
            'admin/users/delete/',
            'admin/users/two-factor',
            'admin/users/two-factor/',
            'admin/system',
            'admin/system/',
            'admin/roles',
            'admin/roles/',
        ];

        foreach ($mainOnlyPrefixes as $prefix) {
            if ($path === rtrim($prefix, '/') || str_starts_with($path, $prefix)) {
                return $this->deny($request, 'Area ini hanya boleh diakses admin utama.');
            }
        }

        /*
         * Admin selain utama boleh buka form create user,
         * tapi tidak boleh membuka list/detail semua user.
         * Kalau route create user beda di versi panel tertentu, ini tetap aman.
         */
        if (($path === 'admin/users' || $path === 'admin/users/') && $request->isMethod('GET')) {
            return $this->deny($request, 'List semua user hanya untuk admin utama.');
        }

        return null;
    }

    private function blockCreatingAnotherAdmin(Request $request): ?Response
    {
        $path = trim($request->path(), '/');

        /*
         * Admin selain utama boleh create user biasa/member,
         * tapi tidak boleh create user root_admin/admin.
         */
        $isUserCreate = (
            ($path === 'admin/users/new' || $path === 'admin/users/new/' || $path === 'admin/users')
            && in_array(strtoupper($request->method()), ['POST', 'PUT', 'PATCH'], true)
        );

        if (!$isUserCreate) {
            return null;
        }

        $rootFlag = $request->input('root_admin');
        $adminFlag = $request->input('admin');
        $isRoot = $this->truthy($rootFlag) || $this->truthy($adminFlag);

        if ($isRoot) {
            return $this->deny($request, 'Admin selain utama tidak boleh membuat admin baru.');
        }

        return null;
    }

    private function truthy($value): bool
    {
        if (is_bool($value)) return $value;
        if (is_numeric($value)) return (int) $value === 1;

        $value = strtolower((string) $value);
        return in_array($value, ['1', 'true', 'on', 'yes', 'admin', 'root'], true);
    }

    private function isClientServerList(Request $request): bool
    {
        if (!$request->isMethod('GET')) {
            return false;
        }

        $path = trim($request->path(), '/');

        return $path === 'api/client'
            || $path === 'api/client/'
            || $path === 'api/client/servers'
            || $path === 'api/client/servers/';
    }

    private function serverFromRequest(Request $request): ?Server
    {
        $path = trim($request->path(), '/');

        /*
         * CLIENT API FULL PROTECT:
         * /api/client/servers/{identifier}/...
         * Semua endpoint di bawah ini otomatis kena:
         * - websocket
         * - resources
         * - command
         * - power
         * - files/list
         * - files/contents
         * - files/write
         * - files/upload
         * - files/download
         * - files/delete
         * - files/rename
         * - files/copy
         * - files/compress
         * - files/decompress
         * - backups
         * - databases
         * - schedules
         * - network/allocations
         * - startup
         * - settings
         * - activity
         * - subusers
         */
        if (preg_match('#^api/client/servers/([^/]+)(?:/|$)#', $path, $m)) {
            return $this->findServer($m[1]);
        }

        /*
         * Halaman client panel:
         * /server/{identifier}
         * /server/{identifier}/files
         * /server/{identifier}/console
         * /servers/{identifier}
         */
        if (preg_match('#^(server|servers)/([^/]+)(?:/|$)#', $path, $m)) {
            return $this->findServer($m[2]);
        }

        /*
         * Admin panel server route.
         * Create server manual tetap dibolehkan.
         */
        if ($path === 'admin/servers' || $path === 'admin/servers/' || str_starts_with($path, 'admin/servers/new')) {
            return null;
        }

        if (preg_match('#^admin/servers/view/([^/]+)(?:/|$)#', $path, $m)) {
            return $this->findServer($m[1]);
        }

        if (preg_match('#^admin/servers/([^/]+)(?:/|$)#', $path, $m)) {
            return $this->findServer($m[1]);
        }

        /*
         * Beberapa versi panel/plugin kadang kirim server id/uuid lewat input.
         * Ini tambahan jaga-jaga untuk request admin/client yang membawa server.
         */
        $possibleKeys = [
            'server',
            'server_id',
            'id',
            'uuid',
            'identifier',
            'uuidShort',
            'uuid_short',
        ];

        foreach ($possibleKeys as $key) {
            $value = $request->route($key) ?: $request->input($key);
            if ($value) {
                $server = $this->findServer((string) $value);
                if ($server instanceof Server) {
                    return $server;
                }
            }
        }

        return null;
    }

    private function findServer(?string $identifier): ?Server
    {
        if (!$identifier) {
            return null;
        }

        $identifier = trim((string) $identifier);
        if ($identifier === '') {
            return null;
        }

        $query = Server::query()
            ->where('uuidShort', $identifier)
            ->orWhere('uuid', $identifier);

        if (ctype_digit($identifier)) {
            $query->orWhere('id', (int) $identifier);
        }

        return $query->first();
    }

    private function filterClientServerList(Request $request, Response $response): Response
    {
        if ($response->getStatusCode() !== 200 || !method_exists($response, 'getContent')) {
            return $response;
        }

        $user = $request->user();
        $payload = json_decode($response->getContent(), true);

        if (!is_array($payload) || !isset($payload['data']) || !is_array($payload['data'])) {
            return $response;
        }

        $filtered = [];

        foreach ($payload['data'] as $item) {
            $attr = $item['attributes'] ?? [];

            $identifier = $attr['identifier']
                ?? $attr['uuidShort']
                ?? $attr['uuid_short']
                ?? $attr['uuid']
                ?? Arr::get($attr, 'relationships.server.attributes.uuid')
                ?? null;

            if (!$identifier) {
                continue;
            }

            $server = $this->findServer((string) $identifier);

            if ($server instanceof Server && (int) $server->owner_id === (int) $user->id) {
                $filtered[] = $item;
            }
        }

        $payload['data'] = array_values($filtered);

        if (isset($payload['meta']['pagination']) && is_array($payload['meta']['pagination'])) {
            $payload['meta']['pagination']['total'] = count($filtered);
            $payload['meta']['pagination']['count'] = count($filtered);
            $payload['meta']['pagination']['per_page'] = max(count($filtered), 1);
            $payload['meta']['pagination']['current_page'] = 1;
            $payload['meta']['pagination']['total_pages'] = 1;
        }

        return response()->json($payload, 200);
    }

    private function deny(Request $request, string $message): Response
    {
        $path = trim($request->path(), '/');

        if ($request->expectsJson() || $request->ajax() || str_starts_with($path, 'api/')) {
            return response()->json([
                'errors' => [[
                    'code' => 'KahfiFullProtectedAccess',
                    'status' => '403',
                    'detail' => $message,
                ]],
            ], 403);
        }

        abort(403, $message);
    }
}
PHP

log "Middleware dibuat: app/Http/Middleware/KahfiFullAdminProtect.php"

# Patch AppServiceProvider supaya middleware aktif di web + api.
php <<'PHP'
<?php

$file = 'app/Providers/AppServiceProvider.php';

if (!is_file($file)) {
    fwrite(STDERR, "[KAHFI-FULL-PROTECT-ERROR] AppServiceProvider.php tidak ditemukan.\n");
    exit(1);
}

$contents = file_get_contents($file);
$marker = 'KAHFI_FULL_ADMIN_PROTECT_BOOT';

if (strpos($contents, $marker) !== false) {
    echo "[KAHFI-FULL-PROTECT] AppServiceProvider sudah pernah dipatch.\n";
    exit(0);
}

$inject = <<<CODE

        // {$marker}
        \$this->app['router']->pushMiddlewareToGroup('web', \\Pterodactyl\\Http\\Middleware\\KahfiFullAdminProtect::class);
        \$this->app['router']->pushMiddlewareToGroup('api', \\Pterodactyl\\Http\\Middleware\\KahfiFullAdminProtect::class);
CODE;

if (preg_match('/public\s+function\s+boot\s*\([^)]*\)\s*(?::\s*void\s*)?\{/m', $contents, $m, PREG_OFFSET_CAPTURE)) {
    $pos = $m[0][1] + strlen($m[0][0]);
    $contents = substr($contents, 0, $pos) . $inject . substr($contents, $pos);
} else {
    $pos = strrpos($contents, "\n}");
    if ($pos === false) {
        fwrite(STDERR, "[KAHFI-FULL-PROTECT-ERROR] Gagal menemukan akhir class AppServiceProvider.\n");
        exit(1);
    }

    $method = <<<CODE

    public function boot(): void
    {
        // {$marker}
        \$this->app['router']->pushMiddlewareToGroup('web', \\Pterodactyl\\Http\\Middleware\\KahfiFullAdminProtect::class);
        \$this->app['router']->pushMiddlewareToGroup('api', \\Pterodactyl\\Http\\Middleware\\KahfiFullAdminProtect::class);
    }

CODE;

    $contents = substr($contents, 0, $pos) . $method . substr($contents, $pos);
}

file_put_contents($file, $contents);
echo "[KAHFI-FULL-PROTECT] AppServiceProvider berhasil dipatch.\n";
PHP

# Patch ServerPolicy agar root_admin selain admin utama tidak bypass policy server.
if [ -f app/Policies/ServerPolicy.php ]; then
php <<'PHP'
<?php

$file = 'app/Policies/ServerPolicy.php';
$contents = file_get_contents($file);
$marker = 'KAHFI_MAIN_ADMIN_ONLY_SERVER_POLICY_BYPASS';

if (strpos($contents, $marker) !== false) {
    echo "[KAHFI-FULL-PROTECT] ServerPolicy sudah pernah dipatch.\n";
    exit(0);
}

$newBefore = <<<'CODE'
public function before(User $user, string $ability): ?bool
    {
        // KAHFI_MAIN_ADMIN_ONLY_SERVER_POLICY_BYPASS
        if ($user->root_admin && (int) $user->id === (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            return true;
        }

        return null;
    }
CODE;

$count = 0;

$patterns = [
    '/public\s+function\s+before\s*\(\s*User\s+\$user\s*,\s*string\s+\$ability\s*\)\s*:\s*\?bool\s*\{\s*return\s+\$user->root_admin\s*\?\s*true\s*:\s*null\s*;\s*\}/s',
    '/public\s+function\s+before\s*\(\s*User\s+\$user\s*,\s*string\s+\$ability\s*\)\s*:\s*\?bool\s*\{\s*if\s*\(\s*\$user->root_admin\s*\)\s*\{\s*return\s+true\s*;\s*\}\s*return\s+null\s*;\s*\}/s',
];

foreach ($patterns as $pattern) {
    $new = preg_replace($pattern, $newBefore, $contents, 1, $count);
    if ($count > 0) {
        $contents = $new;
        break;
    }
}

if ($count === 0) {
    if (strpos($contents, 'function before') !== false) {
        echo "[KAHFI-FULL-PROTECT] ServerPolicy punya before custom. Tidak ditimpa otomatis. Middleware tetap aktif.\n";
        file_put_contents($file . '.kahfi-before-custom-note', "before custom tidak ditimpa otomatis. Middleware full protect tetap aktif.\n");
        exit(0);
    }

    $classPos = strpos($contents, '{');
    if ($classPos === false) {
        echo "[KAHFI-FULL-PROTECT] Struktur ServerPolicy tidak dikenali. Skip policy patch.\n";
        exit(0);
    }

    $contents = substr($contents, 0, $classPos + 1) . "\n    " . $newBefore . "\n" . substr($contents, $classPos + 1);
}

file_put_contents($file, $contents);
echo "[KAHFI-FULL-PROTECT] ServerPolicy berhasil dipatch.\n";
PHP
else
  warn "ServerPolicy.php tidak ditemukan. Middleware tetap aktif."
fi

# Bersihkan class lama kalau dari versi sebelumnya masih ada, tapi jangan hapus file backup.
if [ -f app/Http/Middleware/KahfiAdminOwnServerAccess.php ]; then
  mv app/Http/Middleware/KahfiAdminOwnServerAccess.php "app/Http/Middleware/KahfiAdminOwnServerAccess.php.disabled-$TS" || true
  log "Middleware lama dinonaktifkan agar tidak bentrok."
fi

# Fix permission.
if id www-data >/dev/null 2>&1; then
  chown -R www-data:www-data \
    app/Http/Middleware/KahfiFullAdminProtect.php \
    app/Providers/AppServiceProvider.php \
    app/Policies/ServerPolicy.php \
    .env 2>/dev/null || true
fi

log "Clear cache Laravel..."
php artisan optimize:clear || true
php artisan config:clear || true
php artisan route:clear || true
php artisan view:clear || true

# Restart service umum.
log "Restart nginx/php-fpm jika ada..."
for svc in php8.4-fpm php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm; do
  if systemctl list-unit-files "$svc.service" >/dev/null 2>&1; then
    systemctl restart "$svc" >/dev/null 2>&1 || true
  fi
done
systemctl restart nginx >/dev/null 2>&1 || true

cat <<EOF

============================================================
KAHFI FULL PROTECT SELESAI
============================================================

Backup:
$BACKUP_DIR

Aktif:
- Admin utama ID $MAIN_ADMIN_ID full akses semua.
- Admin selain utama hanya boleh akses server owner_id dia sendiri.
- Console/files/backups/database/schedules/startup/network/settings/websocket server orang lain kena 403.
- Admin selain utama tidak bisa lihat list semua server.
- Admin selain utama tidak bisa buka user detail/list user.
- Admin selain utama tidak bisa buat admin baru.
- Admin selain utama tidak bisa masuk API key admin, settings, nodes, locations, nests, mounts, system.
- Admin selain utama tetap bisa create user biasa/member.
- Admin selain utama tetap bisa create server manual.
- Admin selain utama tetap bisa manage server miliknya sendiri.

TEST WAJIB:
1. Login admin utama, buka semua server: harus bisa.
2. Login admin selain utama, buka server sendiri: harus bisa.
3. Login admin selain utama, buka server orang lain langsung via URL: harus 403.
4. Login admin selain utama, buka console/files server orang lain: harus 403.
5. Login admin selain utama, buka /admin/servers: harus 403.
6. Login admin selain utama, buka /admin/servers/new: harus bisa.

RESTORE kalau error:
cd $PANEL_DIR
cp -a $BACKUP_DIR/app/Providers/AppServiceProvider.php app/Providers/AppServiceProvider.php
[ -f $BACKUP_DIR/app/Policies/ServerPolicy.php ] && cp -a $BACKUP_DIR/app/Policies/ServerPolicy.php app/Policies/ServerPolicy.php
[ -f $BACKUP_DIR/.env ] && cp -a $BACKUP_DIR/.env .env
rm -f app/Http/Middleware/KahfiFullAdminProtect.php
php artisan optimize:clear
systemctl restart nginx
systemctl restart php8.3-fpm 2>/dev/null || systemctl restart php8.2-fpm 2>/dev/null || systemctl restart php8.1-fpm 2>/dev/null || true

============================================================
EOF
