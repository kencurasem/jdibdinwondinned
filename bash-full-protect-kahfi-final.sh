#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# KAHFI FULL PROTECT FINAL - PTERODACTYL PANEL
# Dibuat dari alur bash.sh yang kamu upload, tapi dirapikan agar:
#
# ADMIN UTAMA (default ID 1)
# - full akses semua fitur panel.
#
# ADMIN LAIN / ROOT_ADMIN SELAIN ADMIN UTAMA
# - bisa manage server sendiri.
# - bisa create server, tetapi owner server dipaksa menjadi admin itu sendiri.
# - bisa create user biasa/member.
# - tidak bisa create user admin/root_admin.
# - bisa create PTLA/PTLC.
# - tidak bisa revoke/delete API key kecuali admin utama.
# - tidak bisa akses server orang lain, console orang lain, files orang lain,
#   backups orang lain, database/schedule/startup/network/settings server orang lain.
# - tidak bisa akses area global panel: nodes, locations, nests/eggs, mounts,
#   settings, system, user detail/list, semua server list.
#
# USER BIASA / BUKAN ADMIN
# - tetap bisa manage server miliknya sesuai permission Pterodactyl.
# - tetap bisa download file / backup file pada server masing-masing.
# - tidak bisa create PTLC.
#
# INSTALL:
#   MAIN_ADMIN_ID=1 bash bash-full-protect-kahfi-final.sh
#
# Jika folder panel bukan /var/www/pterodactyl:
#   MAIN_ADMIN_ID=1 bash bash-full-protect-kahfi-final.sh /path/panel
# ==========================================================

MAIN_ADMIN_ID="${MAIN_ADMIN_ID:-1}"
PANEL_PATH="${1:-}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/pterodactyl_backups}"
TIMESTAMP="$(date -u +"%Y-%m-%d-%H-%M-%S")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log(){ echo -e "${BLUE}[KAHFI]${NC} $*"; }
ok(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
fail(){ echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

if [ "$(id -u)" -ne 0 ]; then
  fail "Jalankan sebagai root di VPS panel, bukan Termux lokal."
fi

if [ -z "$PANEL_PATH" ]; then
  for d in /var/www/pterodactyl /var/www/panel /var/www/html /srv/pterodactyl "$PWD"; do
    if [ -f "$d/artisan" ] && [ -d "$d/app" ]; then
      PANEL_PATH="$d"
      break
    fi
  done
fi

[ -n "$PANEL_PATH" ] || fail "Folder panel tidak ketemu. Contoh: MAIN_ADMIN_ID=1 bash $0 /var/www/pterodactyl"
[ -f "$PANEL_PATH/artisan" ] || fail "File artisan tidak ada di $PANEL_PATH"

cd "$PANEL_PATH"
BACKUP_DIR="$BACKUP_ROOT/kahfi-full-protect-final-$TIMESTAMP"
mkdir -p "$BACKUP_DIR"

log "Panel path: $PANEL_PATH"
log "Backup: $BACKUP_DIR"
log "Main admin ID: $MAIN_ADMIN_ID"

backup_file(){
  local f="$1"
  if [ -f "$f" ]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR/$f"
    ok "Backup $f"
  fi
}

backup_file ".env"
backup_file "app/Providers/AppServiceProvider.php"
backup_file "app/Policies/ServerPolicy.php"
backup_file "app/Http/Controllers/Api/Client/Servers/FileController.php"
backup_file "app/Http/Controllers/Api/Client/Servers/ServerController.php"
backup_file "app/Http/Controllers/Admin/ServersController.php"
backup_file "app/Http/Controllers/Admin/UserController.php"
backup_file "app/Services/Users/UserCreationService.php"
backup_file "app/Services/Users/UserUpdateService.php"
backup_file "app/Services/Servers/ServerCreationService.php"
backup_file "app/Services/Servers/ServerDeletionService.php"
backup_file "app/Services/Servers/DetailsModificationService.php"

if grep -q '^KAHFI_MAIN_ADMIN_ID=' .env 2>/dev/null; then
  sed -i "s/^KAHFI_MAIN_ADMIN_ID=.*/KAHFI_MAIN_ADMIN_ID=${MAIN_ADMIN_ID}/" .env
else
  printf '\nKAHFI_MAIN_ADMIN_ID=%s\n' "$MAIN_ADMIN_ID" >> .env
fi

mkdir -p app/Http/Middleware

cat > app/Http/Middleware/KahfiFullProtectFinal.php <<'PHP'
<?php

namespace Pterodactyl\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Pterodactyl\Models\Server;
use Symfony\Component\HttpFoundation\Response;

class KahfiFullProtectFinal
{
    public function handle(Request $request, Closure $next): Response
    {
        $user = $request->user();
        $path = trim($request->path(), '/');

        /*
         * USER BIASA:
         * PTLC / client API key creation dikunci.
         * User biasa tetap bisa file manager, download file, backup, console,
         * sesuai permission Pterodactyl masing-masing server.
         */
        if ($user && !$user->root_admin && $this->isClientApiKeyCreate($request)) {
            return $this->deny($request, 'User biasa tidak boleh create PTLC/API key.');
        }

        if (!$user || !$user->root_admin) {
            return $next($request);
        }

        $mainAdminId = (int) env('KAHFI_MAIN_ADMIN_ID', 1);

        if ((int) $user->id === $mainAdminId) {
            return $next($request);
        }

        /*
         * ADMIN SELAIN UTAMA:
         * boleh create PTLA/PTLC, tapi tidak boleh revoke/delete API key.
         */
        if ($this->isApiKeyDeleteOrRevoke($request)) {
            return $this->deny($request, 'Revoke/delete API key hanya untuk admin utama.');
        }

        /*
         * Filter list server Client API agar admin selain utama cuma melihat server sendiri.
         */
        if ($this->isClientServerList($request)) {
            $response = $next($request);
            return $this->filterClientServerList($request, $response);
        }

        /*
         * Admin area global khusus admin utama.
         * Catatan:
         * - admin/api tidak diblokir supaya admin selain utama bisa create PTLA.
         * - admin/servers/new tidak diblokir supaya bisa create server.
         * - admin/users/new tidak diblokir supaya bisa create user biasa.
         */
        $adminBlock = $this->blockedAdminArea($request);
        if ($adminBlock !== null) {
            return $adminBlock;
        }

        /*
         * Protect server route: console, files, backups, database, schedule,
         * startup, network, settings, websocket, command, power, dll.
         */
        $server = $this->serverFromRequest($request);

        if ($server instanceof Server && (int) $server->owner_id !== (int) $user->id) {
            return $this->deny($request, 'Akses ditolak. Admin hanya boleh mengakses server miliknya sendiri.');
        }

        return $next($request);
    }

    private function blockedAdminArea(Request $request): ?Response
    {
        $path = trim($request->path(), '/');

        /*
         * List semua server hanya admin utama.
         * Create server tetap boleh.
         */
        if (($path === 'admin/servers' || $path === 'admin/servers/') && $request->isMethod('GET')) {
            return $this->deny($request, 'List semua server hanya untuk admin utama.');
        }

        /*
         * Create server route dibolehkan untuk admin selain utama.
         */
        if (str_starts_with($path, 'admin/servers/new')) {
            return null;
        }

        /*
         * Create user biasa dibolehkan.
         * List/detail/edit/delete user tetap khusus admin utama.
         */
        if (str_starts_with($path, 'admin/users/new')) {
            return null;
        }

        if (($path === 'admin/users' || $path === 'admin/users/') && !$request->isMethod('POST')) {
            return $this->deny($request, 'List user hanya untuk admin utama.');
        }

        /*
         * admin/api dibiarkan agar admin selain utama bisa create PTLA.
         * Delete/revoke API key tetap diblokir di isApiKeyDeleteOrRevoke().
         */
        if (str_starts_with($path, 'admin/api')) {
            return null;
        }

        $mainOnlyPrefixes = [
            'admin/settings',
            'admin/nodes',
            'admin/locations',
            'admin/nests',
            'admin/mounts',
            'admin/databases',
            'admin/users/view',
            'admin/users/edit',
            'admin/users/delete',
            'admin/users/two-factor',
            'admin/system',
            'admin/roles',
        ];

        foreach ($mainOnlyPrefixes as $prefix) {
            if ($path === $prefix || str_starts_with($path, $prefix . '/')) {
                return $this->deny($request, 'Area ini hanya boleh diakses admin utama.');
            }
        }

        return null;
    }

    private function isClientApiKeyCreate(Request $request): bool
    {
        $path = trim($request->path(), '/');

        return $request->isMethod('POST')
            && (
                $path === 'api/client/account/api-keys'
                || $path === 'api/client/account/api-keys/'
                || $path === 'account/api'
                || $path === 'account/api/'
                || str_contains($path, 'api-keys')
            );
    }

    private function isApiKeyDeleteOrRevoke(Request $request): bool
    {
        $path = trim($request->path(), '/');
        $method = strtoupper($request->method());

        if (in_array($method, ['DELETE'], true) && (str_contains($path, 'api') || str_contains($path, 'api-keys'))) {
            return true;
        }

        if (in_array($method, ['POST', 'PUT', 'PATCH'], true)) {
            $action = strtolower((string) ($request->input('action') ?? $request->input('_method') ?? ''));
            if (in_array($action, ['delete', 'destroy', 'revoke', 'remove'], true) && (str_contains($path, 'api') || str_contains($path, 'api-keys'))) {
                return true;
            }
        }

        return false;
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

        if (preg_match('#^api/client/servers/([^/]+)(?:/|$)#', $path, $m)) {
            return $this->findServer($m[1]);
        }

        if (preg_match('#^(server|servers)/([^/]+)(?:/|$)#', $path, $m)) {
            return $this->findServer($m[2]);
        }

        if (preg_match('#^admin/servers/view/([^/]+)(?:/|$)#', $path, $m)) {
            return $this->findServer($m[1]);
        }

        if (preg_match('#^admin/servers/([^/]+)(?:/|$)#', $path, $m)) {
            return $this->findServer($m[1]);
        }

        foreach (['server', 'server_id', 'id', 'uuid', 'identifier', 'uuidShort', 'uuid_short'] as $key) {
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
                    'code' => 'KahfiFullProtectFinal',
                    'status' => '403',
                    'detail' => $message,
                ]],
            ], 403);
        }

        abort(403, $message);
    }
}
PHP

ok "Middleware dibuat: app/Http/Middleware/KahfiFullProtectFinal.php"

log "Patch AppServiceProvider agar middleware aktif..."
php <<'PHP_PATCH'
<?php
$file = 'app/Providers/AppServiceProvider.php';
if (!is_file($file)) {
    fwrite(STDERR, "AppServiceProvider.php tidak ditemukan\n");
    exit(1);
}

$s = file_get_contents($file);
$marker = 'KAHFI_FULL_PROTECT_FINAL_BOOT';

if (strpos($s, $marker) !== false) {
    echo "AppServiceProvider sudah terpatch.\n";
    exit(0);
}

$inject = "\n        // {$marker}\n"
    . "        \$this->app['router']->pushMiddlewareToGroup('web', \\Pterodactyl\\Http\\Middleware\\KahfiFullProtectFinal::class);\n"
    . "        \$this->app['router']->pushMiddlewareToGroup('api', \\Pterodactyl\\Http\\Middleware\\KahfiFullProtectFinal::class);\n";

if (preg_match('/public\s+function\s+boot\s*\([^)]*\)\s*(?::\s*void\s*)?\s*\{/m', $s, $m, PREG_OFFSET_CAPTURE)) {
    $pos = $m[0][1] + strlen($m[0][0]);
    $s = substr($s, 0, $pos) . $inject . substr($s, $pos);
} else {
    $pos = strrpos($s, "\n}");
    if ($pos === false) {
        fwrite(STDERR, "Tidak bisa menemukan akhir class AppServiceProvider\n");
        exit(1);
    }

    $method = "\n    public function boot(): void\n    {\n"
        . "        // {$marker}\n"
        . "        \$this->app['router']->pushMiddlewareToGroup('web', \\Pterodactyl\\Http\\Middleware\\KahfiFullProtectFinal::class);\n"
        . "        \$this->app['router']->pushMiddlewareToGroup('api', \\Pterodactyl\\Http\\Middleware\\KahfiFullProtectFinal::class);\n"
        . "    }\n";

    $s = substr($s, 0, $pos) . $method . substr($s, $pos);
}

file_put_contents($file, $s);
echo "OK AppServiceProvider\n";
PHP_PATCH

log "Patch ServerPolicy supaya root_admin selain admin utama tidak bypass semua server..."
if [ -f app/Policies/ServerPolicy.php ]; then
php <<'PHP_PATCH'
<?php
$file = 'app/Policies/ServerPolicy.php';
$s = file_get_contents($file);
$marker = 'KAHFI_FULL_PROTECT_FINAL_SERVER_POLICY';

if (strpos($s, $marker) !== false) {
    echo "ServerPolicy sudah terpatch.\n";
    exit(0);
}

$newBefore = <<<'PHP'
public function before(User $user, string $ability): ?bool
    {
        // KAHFI_FULL_PROTECT_FINAL_SERVER_POLICY
        if ($user->root_admin && (int) $user->id === (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            return true;
        }

        return null;
    }
PHP;

$count = 0;
$patterns = [
    '/public\s+function\s+before\s*\(\s*User\s+\$user\s*,\s*string\s+\$ability\s*\)\s*:\s*\?bool\s*\{\s*return\s+\$user->root_admin\s*\?\s*true\s*:\s*null\s*;\s*\}/s',
    '/public\s+function\s+before\s*\(\s*User\s+\$user\s*,\s*string\s+\$ability\s*\)\s*:\s*\?bool\s*\{.*?return\s+null\s*;\s*\}/s',
];

foreach ($patterns as $pattern) {
    $patched = preg_replace($pattern, $newBefore, $s, 1, $count);
    if ($patched !== null && $count > 0) {
        $s = $patched;
        break;
    }
}

if ($count === 0) {
    $classPos = strpos($s, '{');
    if ($classPos !== false) {
        $s = substr($s, 0, $classPos + 1) . "\n    " . $newBefore . "\n" . substr($s, $classPos + 1);
    }
}

file_put_contents($file, $s);
echo "OK ServerPolicy\n";
PHP_PATCH
else
  warn "ServerPolicy.php tidak ketemu, skip."
fi

log "Patch UserCreationService: admin selain utama boleh create user biasa, bukan admin..."
if [ -f app/Services/Users/UserCreationService.php ]; then
php <<'PHP_PATCH'
<?php
$file = 'app/Services/Users/UserCreationService.php';
$s = file_get_contents($file);
$marker = 'KAHFI_FULL_PROTECT_FINAL_USER_CREATE';

if (strpos($s, $marker) !== false) {
    echo "UserCreationService sudah terpatch.\n";
    exit(0);
}

/* Hapus guard lama yang memblokir semua create user dari admin kedua kalau pernah ada. */
$s = preg_replace('/\n\s*\/\/ KahfiModTzy Protection :: API\/Bot User Creation Security.*?Only Root Admin can create users\/admins via API\/Bot.*?\}\s*/s', "\n", $s) ?? $s;

$guard = <<<'PHP'

        // KAHFI_FULL_PROTECT_FINAL_USER_CREATE
        // Admin selain utama boleh create user biasa, tetapi tidak boleh create admin/root_admin.
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }

        if ($kahfiAuthUser && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            $kahfiRootRaw = is_array($data ?? null) ? ($data['root_admin'] ?? false) : false;
            $kahfiRoot = filter_var($kahfiRootRaw, FILTER_VALIDATE_BOOLEAN);

            if ($kahfiRoot) {
                throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh create admin/root_admin.');
            }

            if (isset($data) && is_array($data)) {
                $data['root_admin'] = false;
            }
        }
PHP;

if (!preg_match('/public\s+function\s+handle\s*\([^)]*\)\s*(?::\s*[^{]+)?\s*\{/m', $s, $m, PREG_OFFSET_CAPTURE)) {
    fwrite(STDERR, "handle() UserCreationService tidak ketemu\n");
    exit(1);
}

$pos = $m[0][1] + strlen($m[0][0]);
$s = substr($s, 0, $pos) . $guard . substr($s, $pos);
file_put_contents($file, $s);
echo "OK UserCreationService\n";
PHP_PATCH
fi

log "Patch UserUpdateService: admin selain utama tidak bisa ubah privilege admin..."
if [ -f app/Services/Users/UserUpdateService.php ]; then
php <<'PHP_PATCH'
<?php
$file = 'app/Services/Users/UserUpdateService.php';
$s = file_get_contents($file);
$marker = 'KAHFI_FULL_PROTECT_FINAL_USER_UPDATE';

if (strpos($s, $marker) !== false) {
    echo "UserUpdateService sudah terpatch.\n";
    exit(0);
}

$guard = <<<'PHP'

        // KAHFI_FULL_PROTECT_FINAL_USER_UPDATE
        // Admin selain utama tidak boleh mengubah root_admin/admin privilege.
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }

        if ($kahfiAuthUser && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            if (isset($data) && is_array($data) && array_key_exists('root_admin', $data)) {
                throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh mengubah privilege admin.');
            }

            if (isset($user) && is_object($user) && !empty($user->root_admin)) {
                throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh edit akun admin.');
            }
        }
PHP;

if (!preg_match('/public\s+function\s+handle\s*\([^)]*\)\s*(?::\s*[^{]+)?\s*\{/m', $s, $m, PREG_OFFSET_CAPTURE)) {
    fwrite(STDERR, "handle() UserUpdateService tidak ketemu\n");
    exit(1);
}

$pos = $m[0][1] + strlen($m[0][0]);
$s = substr($s, 0, $pos) . $guard . substr($s, $pos);
file_put_contents($file, $s);
echo "OK UserUpdateService\n";
PHP_PATCH
fi

log "Patch UserController redirect supaya admin selain utama selesai create user tidak dilempar ke detail user..."
if [ -f app/Http/Controllers/Admin/UserController.php ]; then
php <<'PHP_PATCH'
<?php
$file = 'app/Http/Controllers/Admin/UserController.php';
$s = file_get_contents($file);
$marker = 'KAHFI_FULL_PROTECT_FINAL_USER_CONTROLLER_REDIRECT';

if (strpos($s, $marker) !== false) {
    echo "UserController sudah terpatch.\n";
    exit(0);
}

if (strpos($s, 'use Illuminate\Support\Facades\Auth;') === false) {
    $s = preg_replace('/namespace\s+Pterodactyl\\\\Http\\\\Controllers\\\\Admin;\s*/', "namespace Pterodactyl\\Http\\Controllers\\Admin;\n\nuse Illuminate\\Support\\Facades\\Auth;\n", $s, 1);
}

if (strpos($s, '$this->creationService->handle') !== false) {
    /*
     * Setelah create user, controller bawaan biasanya redirect ke detail user.
     * Admin selain utama tidak boleh buka detail user, jadi diarahkan kembali ke form create user/admin dashboard.
     */
    $s = preg_replace(
        '/(\$user\s*=\s*\$this->creationService->handle\([^;]+;\s*.*?->flash\(\);\s*)(return\s+redirect\(\)->route\([^)]+admin\.users\.view[^;]+;)/s',
        "$1\n        // KAHFI_FULL_PROTECT_FINAL_USER_CONTROLLER_REDIRECT\n        \$kahfiAuthUser = Auth::user();\n        if (\$kahfiAuthUser && (int) \$kahfiAuthUser->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {\n            return redirect()->route('admin.users.new');\n        }\n\n        $2",
        $s,
        1,
        $count
    );

    if (($count ?? 0) === 0 && strpos($s, 'public function store') !== false) {
        echo "WARNING: redirect store UserController tidak cocok pola. Service-level protect tetap aktif.\n";
    }
}

file_put_contents($file, $s);
echo "OK UserController\n";
PHP_PATCH
fi

log "Patch ServerCreationService: admin selain utama create server hanya untuk diri sendiri..."
if [ -f app/Services/Servers/ServerCreationService.php ]; then
php <<'PHP_PATCH'
<?php
$file = 'app/Services/Servers/ServerCreationService.php';
$s = file_get_contents($file);
$marker = 'KAHFI_FULL_PROTECT_FINAL_SERVER_CREATE';

if (strpos($s, $marker) !== false) {
    echo "ServerCreationService sudah terpatch.\n";
    exit(0);
}

$guard = <<<'PHP'

        // KAHFI_FULL_PROTECT_FINAL_SERVER_CREATE
        // Admin selain utama boleh create server, tetapi owner_id dipaksa menjadi dirinya sendiri.
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }

        if ($kahfiAuthUser && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            if (isset($data) && is_array($data)) {
                $data['owner_id'] = (int) $kahfiAuthUser->id;
                $data['user_id'] = (int) $kahfiAuthUser->id;
            }
        }
PHP;

if (!preg_match('/public\s+function\s+handle\s*\([^)]*\)\s*(?::\s*[^{]+)?\s*\{/m', $s, $m, PREG_OFFSET_CAPTURE)) {
    fwrite(STDERR, "handle() ServerCreationService tidak ketemu\n");
    exit(1);
}

$pos = $m[0][1] + strlen($m[0][0]);
$s = substr($s, 0, $pos) . $guard . substr($s, $pos);
file_put_contents($file, $s);
echo "OK ServerCreationService\n";
PHP_PATCH
fi

log "Patch ServerDeletionService: delete server tetap admin utama saja..."
if [ -f app/Services/Servers/ServerDeletionService.php ]; then
php <<'PHP_PATCH'
<?php
$file = 'app/Services/Servers/ServerDeletionService.php';
$s = file_get_contents($file);
$marker = 'KAHFI_FULL_PROTECT_FINAL_SERVER_DELETE';

if (strpos($s, $marker) !== false) {
    echo "ServerDeletionService sudah terpatch.\n";
    exit(0);
}

if (strpos($s, 'use Illuminate\Support\Facades\Auth;') === false) {
    $s = preg_replace('/namespace\s+Pterodactyl\\\\Services\\\\Servers;\s*/', "namespace Pterodactyl\\Services\\Servers;\n\nuse Illuminate\\Support\\Facades\\Auth;\n", $s, 1);
}
if (strpos($s, 'use Pterodactyl\Exceptions\DisplayException;') === false) {
    $s = preg_replace('/namespace\s+Pterodactyl\\\\Services\\\\Servers;\s*/', "namespace Pterodactyl\\Services\\Servers;\n\nuse Pterodactyl\\Exceptions\\DisplayException;\n", $s, 1);
}

$guard = <<<'PHP'

        // KAHFI_FULL_PROTECT_FINAL_SERVER_DELETE
        // Delete server hanya admin utama. Admin lain tetap bisa manage server sendiri tanpa delete.
        $kahfiAuthUser = Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }

        if (!$kahfiAuthUser || (int) $kahfiAuthUser->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            throw new DisplayException('Hanya admin utama yang boleh delete server.');
        }
PHP;

if (!preg_match('/public\s+function\s+handle\s*\([^)]*\)\s*(?::\s*[^{]+)?\s*\{/m', $s, $m, PREG_OFFSET_CAPTURE)) {
    fwrite(STDERR, "handle() ServerDeletionService tidak ketemu\n");
    exit(1);
}

$pos = $m[0][1] + strlen($m[0][0]);
$s = substr($s, 0, $pos) . $guard . substr($s, $pos);
file_put_contents($file, $s);
echo "OK ServerDeletionService\n";
PHP_PATCH
fi

log "Patch DetailsModificationService: admin selain utama boleh edit server sendiri, tapi tidak bisa ganti owner..."
if [ -f app/Services/Servers/DetailsModificationService.php ]; then
php <<'PHP_PATCH'
<?php
$file = 'app/Services/Servers/DetailsModificationService.php';
$s = file_get_contents($file);
$marker = 'KAHFI_FULL_PROTECT_FINAL_DETAILS_MODIFY';

if (strpos($s, $marker) !== false) {
    echo "DetailsModificationService sudah terpatch.\n";
    exit(0);
}

if (strpos($s, 'use Illuminate\Support\Facades\Auth;') === false) {
    $s = preg_replace('/namespace\s+Pterodactyl\\\\Services\\\\Servers;\s*/', "namespace Pterodactyl\\Services\\Servers;\n\nuse Illuminate\\Support\\Facades\\Auth;\n", $s, 1);
}

/* Hapus guard lama yang memblokir semua admin selain ID 1 jika ada. */
$s = preg_replace('/\n\s*\/\/ KahfiModTzy Protection :: Server Modification Security\s*\n\s*\$user\s*=\s*Auth::user\(\);\s*\n\s*if\s*\([^}]+Server modification denied[^}]+\}\s*/s', "\n", $s) ?? $s;

$guard = <<<'PHP'

        // KAHFI_FULL_PROTECT_FINAL_DETAILS_MODIFY
        // Admin selain utama boleh edit server sendiri, tapi tidak boleh pindah owner.
        $kahfiAuthUser = Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }

        if ($kahfiAuthUser && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            if ((int) $server->owner_id !== (int) $kahfiAuthUser->id) {
                abort(403, 'Admin hanya boleh modify server miliknya sendiri.');
            }

            if (isset($data) && is_array($data)) {
                unset($data['owner_id'], $data['user_id'], $data['external_id']);
            }
        }
PHP;

if (!preg_match('/public\s+function\s+handle\s*\([^)]*\)\s*(?::\s*[^{]+)?\s*\{/m', $s, $m, PREG_OFFSET_CAPTURE)) {
    fwrite(STDERR, "handle() DetailsModificationService tidak ketemu\n");
    exit(1);
}

$pos = $m[0][1] + strlen($m[0][0]);
$s = substr($s, 0, $pos) . $guard . substr($s, $pos);
file_put_contents($file, $s);
echo "OK DetailsModificationService\n";
PHP_PATCH
fi

log "Patch ServersController lama yang terlalu ketat agar admin lain bisa create/manage server sendiri..."
if [ -f app/Http/Controllers/Admin/ServersController.php ]; then
php <<'PHP_PATCH'
<?php
$file = 'app/Http/Controllers/Admin/ServersController.php';
$s = file_get_contents($file);
$marker = 'KAHFI_FULL_PROTECT_FINAL_SERVERS_CONTROLLER';

if (strpos($s, $marker) !== false) {
    echo "ServersController sudah terpatch.\n";
    exit(0);
}

/*
 * Jika file ini pernah ditimpa script lama dan punya checkAdmin yang memblokir admin kedua,
 * jadikan checkAdmin no-op untuk root_admin. Middleware akan tetap memblokir server orang lain.
 */
if (preg_match('/private\s+function\s+checkAdmin\s*\([^)]*\)\s*:\s*void\s*\{.*?\n\s*\}/s', $s, $m, PREG_OFFSET_CAPTURE)) {
    $new = <<<'PHP'
private function checkAdmin(string $action = "access"): void
    {
        // KAHFI_FULL_PROTECT_FINAL_SERVERS_CONTROLLER
        $user = Auth::user();

        if (!$user || !$user->root_admin) {
            throw new DisplayException("Kahfi Protection :: admin access required");
        }

        // Admin selain utama boleh create/manage server sendiri.
        // Akses server orang lain tetap diblokir oleh middleware KahfiFullProtectFinal.
    }
PHP;
    $s = substr($s, 0, $m[0][1]) . $new . substr($s, $m[0][1] + strlen($m[0][0]));
} else {
    $s .= "\n// KAHFI_FULL_PROTECT_FINAL_SERVERS_CONTROLLER\n";
}

file_put_contents($file, $s);
echo "OK ServersController\n";
PHP_PATCH
fi

log "Patch FileController custom supaya download/backup/file manager tetap jalan untuk semua user sesuai server masing-masing..."
if [ -f app/Http/Controllers/Api/Client/Servers/FileController.php ]; then
php <<'PHP_PATCH'
<?php
$file = 'app/Http/Controllers/Api/Client/Servers/FileController.php';
$s = file_get_contents($file);
$marker = 'KAHFI_FULL_PROTECT_FINAL_FILE_ACCESS';

if (strpos($s, $marker) !== false) {
    echo "FileController sudah terpatch.\n";
    exit(0);
}

function findPrivateMethodBlock(string $s, string $name): ?array {
    if (!preg_match('/private\s+function\s+' . preg_quote($name, '/') . '\s*\([^)]*\)\s*(?::\s*[^{]+)?\s*\{/m', $s, $m, PREG_OFFSET_CAPTURE)) {
        return null;
    }

    $start = $m[0][1];
    $i = $start + strlen($m[0][0]);
    $depth = 1;
    $len = strlen($s);

    for (; $i < $len; $i++) {
        if ($s[$i] === '{') $depth++;
        if ($s[$i] === '}') $depth--;
        if ($depth === 0) return [$start, $i + 1];
    }

    return null;
}

$newMethod = <<<'PHP'
    private function checkServerAccess($request, Server $server)
    {
        // KAHFI_FULL_PROTECT_FINAL_FILE_ACCESS
        // Jangan blokir user biasa/subuser. FormRequest Pterodactyl tetap menangani permission file.
        // Admin utama bebas semua. Admin selain utama hanya server owner miliknya.
        $user = $request->user();

        if (!$user) {
            abort(403, 'Unauthorized');
        }

        if (!empty($user->root_admin)) {
            if ((int) $user->id === (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
                return;
            }

            if ((int) $server->owner_id !== (int) $user->id) {
                abort(403, 'Admin hanya boleh akses file server miliknya sendiri.');
            }

            return;
        }

        return;
    }
PHP;

$block = findPrivateMethodBlock($s, 'checkServerAccess');
if ($block) {
    [$a, $b] = $block;
    $s = substr($s, 0, $a) . $newMethod . substr($s, $b);
} else {
    echo "checkServerAccess tidak ada di FileController, skip replace.\n";
}

file_put_contents($file, $s);
echo "OK FileController\n";
PHP_PATCH
fi

log "Patch ServerController custom supaya user biasa/subuser tidak ikut keblokir..."
if [ -f app/Http/Controllers/Api/Client/Servers/ServerController.php ]; then
php <<'PHP_PATCH'
<?php
$file = 'app/Http/Controllers/Api/Client/Servers/ServerController.php';
$s = file_get_contents($file);
$marker = 'KAHFI_FULL_PROTECT_FINAL_CLIENT_SERVER_CONTROLLER';

if (strpos($s, $marker) !== false) {
    echo "ServerController sudah terpatch.\n";
    exit(0);
}

$oldPatterns = [
    '/\n\s*\/\/ KahfiModTzy Protection :: Server Access Security\s*\n\s*\$authUser\s*=\s*Auth::user\(\);\s*\n\s*if\s*\(\$authUser->id\s*!==\s*1\s*&&\s*\(int\)\s*\$server->owner_id\s*!==\s*\(int\)\s*\$authUser->id\s*\)\s*\{\s*abort\(403,[^;]+;\s*\}\s*/s',
    '/\n\s*\$authUser\s*=\s*Auth::user\(\);\s*\n\s*if\s*\(\$authUser->id\s*!==\s*1\s*&&\s*\(int\)\s*\$server->owner_id\s*!==\s*\(int\)\s*\$authUser->id\s*\)\s*\{\s*abort\(403,[^;]+;\s*\}\s*/s',
];

$guard = <<<'PHP'

        // KAHFI_FULL_PROTECT_FINAL_CLIENT_SERVER_CONTROLLER
        // User biasa/subuser jangan diblokir di sini; permission bawaan Pterodactyl tetap jalan.
        // Admin selain utama hanya boleh akses server yang owner_id-nya dirinya.
        $authUser = Auth::user();
        if ($authUser && !empty($authUser->root_admin) && (int) $authUser->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            if ((int) $server->owner_id !== (int) $authUser->id) {
                abort(403, 'Admin hanya boleh akses server miliknya sendiri.');
            }
        }
PHP;

$count = 0;
foreach ($oldPatterns as $pattern) {
    $patched = preg_replace($pattern, $guard, $s, 1, $count);
    if ($patched !== null && $count > 0) {
        $s = $patched;
        break;
    }
}

if ($count === 0) {
    if (preg_match('/public\s+function\s+index\s*\([^)]*\)\s*(?::\s*[^{]+)?\s*\{/m', $s, $m, PREG_OFFSET_CAPTURE)) {
        $pos = $m[0][1] + strlen($m[0][0]);
        $s = substr($s, 0, $pos) . $guard . substr($s, $pos);
    }
}

file_put_contents($file, $s);
echo "OK ServerController\n";
PHP_PATCH
fi

log "Patch API key revoke/delete service: create PTLA/PTLC boleh untuk admin, delete/revoke hanya admin utama..."
php <<'PHP_PATCH'
<?php
$panel = getcwd();
$backupMarker = 'KAHFI_FULL_PROTECT_FINAL_APIKEY_DELETE';

$guard = <<<'PHP'

        // KAHFI_FULL_PROTECT_FINAL_APIKEY_DELETE
        // Create PTLA/PTLC boleh untuk admin. Revoke/delete hanya admin utama.
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }

        if ($kahfiAuthUser && (int) $kahfiAuthUser->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            throw new \Pterodactyl\Exceptions\DisplayException('Revoke/delete API key hanya untuk admin utama.');
        }
PHP;

function patchMethods(string $file, string $marker, string $guard, array $methods): void {
    if (!is_file($file)) return;

    $s = file_get_contents($file);
    if ($s === false || strpos($s, $marker) !== false) return;

    $regex = implode('|', array_map(fn($m) => preg_quote($m, '/'), $methods));
    $pattern = '/public\s+function\s+(' . $regex . ')\s*\([^)]*\)\s*(?::\s*[^{]+)?\s*\{/m';

    $count = 0;
    $s2 = preg_replace_callback($pattern, function ($m) use ($guard, &$count) {
        $count++;
        return $m[0] . $guard;
    }, $s, -1, $count);

    if ($s2 !== null && $count > 0) {
        file_put_contents($file, $s2);
        echo "OK API key delete/revoke guard: {$file}\n";
    }
}

$candidates = [
    $panel . '/app/Http/Controllers/Admin/ApiController.php',
    $panel . '/app/Http/Controllers/Admin/ApiKeyController.php',
    $panel . '/app/Http/Controllers/Admin/ApiKeysController.php',
    $panel . '/app/Http/Controllers/Api/Client/Account/ApiKeyController.php',
    $panel . '/app/Http/Controllers/Api/Client/Account/ApiKeysController.php',
    $panel . '/app/Http/Controllers/Api/Application/ApiKeyController.php',
    $panel . '/app/Http/Controllers/Api/Application/ApiKeysController.php',
];

foreach ($candidates as $file) {
    patchMethods($file, $backupMarker, $guard, ['delete', 'destroy', 'revoke', 'remove']);
}

$serviceDir = $panel . '/app/Services';
if (is_dir($serviceDir)) {
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($serviceDir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $f) {
        if (!$f->isFile()) continue;
        $path = $f->getPathname();
        $base = $f->getBasename();

        if (preg_match('/(KeyDeletionService|ApiKeyDeletionService|ApplicationApiKeyDeletionService|ClientApiKeyDeletionService)\.php$/i', $base)) {
            patchMethods($path, $backupMarker, $guard, ['handle', 'delete', 'destroy', 'revoke', 'remove']);
        }
    }
}
PHP_PATCH

log "Cek syntax PHP file yang dipatch..."
php -l app/Http/Middleware/KahfiFullProtectFinal.php
[ -f app/Providers/AppServiceProvider.php ] && php -l app/Providers/AppServiceProvider.php
[ -f app/Policies/ServerPolicy.php ] && php -l app/Policies/ServerPolicy.php || true
[ -f app/Services/Users/UserCreationService.php ] && php -l app/Services/Users/UserCreationService.php || true
[ -f app/Services/Users/UserUpdateService.php ] && php -l app/Services/Users/UserUpdateService.php || true
[ -f app/Services/Servers/ServerCreationService.php ] && php -l app/Services/Servers/ServerCreationService.php || true
[ -f app/Services/Servers/ServerDeletionService.php ] && php -l app/Services/Servers/ServerDeletionService.php || true
[ -f app/Services/Servers/DetailsModificationService.php ] && php -l app/Services/Servers/DetailsModificationService.php || true
[ -f app/Http/Controllers/Api/Client/Servers/FileController.php ] && php -l app/Http/Controllers/Api/Client/Servers/FileController.php || true
[ -f app/Http/Controllers/Api/Client/Servers/ServerController.php ] && php -l app/Http/Controllers/Api/Client/Servers/ServerController.php || true
[ -f app/Http/Controllers/Admin/ServersController.php ] && php -l app/Http/Controllers/Admin/ServersController.php || true
[ -f app/Http/Controllers/Admin/UserController.php ] && php -l app/Http/Controllers/Admin/UserController.php || true

log "Set permission + clear cache..."
if id www-data >/dev/null 2>&1; then
  chown -R www-data:www-data "$PANEL_PATH" || true
fi

php artisan optimize:clear || true
php artisan view:clear || true
php artisan route:clear || true
php artisan config:clear || true
php artisan cache:clear || true
php artisan queue:restart || true

log "Restart service..."
for svc in $(systemctl list-units --type=service --all | awk '{print $1}' | grep -E '^php[0-9.]+-fpm\.service$' || true); do
  systemctl restart "$svc" || true
done
systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true

cat <<EOF

============================================================
KAHFI FULL PROTECT FINAL SELESAI
============================================================

Backup:
$BACKUP_DIR

RULE AKTIF:

Admin utama ID $MAIN_ADMIN_ID:
- full akses semua.

Admin selain utama/root_admin lain:
- bisa manage server sendiri.
- bisa create server, owner server dipaksa ke akun admin itu sendiri.
- bisa create user biasa/member.
- tidak bisa create admin/root_admin.
- bisa create PTLA/PTLC.
- tidak bisa revoke/delete API key.
- tidak bisa akses server orang lain.
- tidak bisa console/files/backups/database/schedule/startup/network/settings server orang lain.
- tidak bisa akses nodes, locations, nests/eggs, mounts, settings, system, user detail/list, semua server list.

User biasa:
- tidak bisa create PTLC.
- tetap bisa file manager, download file, dan backup file pada server masing-masing sesuai permission Pterodactyl.
- tidak dibuat jadi admin.

Delete server:
- hanya admin utama.

TEST WAJIB:
1. Login admin utama: buka semua server harus bisa.
2. Login admin lain: create server harus bisa, server owner menjadi admin itu sendiri.
3. Login admin lain: server sendiri console/files/backups harus bisa.
4. Login admin lain: server orang lain harus 403.
5. Login admin lain: create user biasa harus bisa.
6. Login admin lain: create user admin/root_admin harus gagal.
7. Login admin lain: create PTLA/PTLC harus bisa.
8. Login user biasa: create PTLC harus gagal.
9. Login user biasa/owner server: download file/backup file harus bisa.

RESTORE:
cp -a "$BACKUP_DIR"/app/* "$PANEL_PATH"/app/ 2>/dev/null || true
[ -f "$BACKUP_DIR/.env" ] && cp -a "$BACKUP_DIR/.env" "$PANEL_PATH/.env"
cd "$PANEL_PATH" && php artisan optimize:clear
systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true

Kalau masih error, kirim:
tail -n 120 $PANEL_PATH/storage/logs/laravel-*.log

============================================================
EOF
