#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# kahfimoodtzyy Full Protect + Same Admin Theme v12
#
# RULE FINAL:
# Admin utama:
# - full akses semua
#
# Admin selain utama:
# - boleh create user biasa, bukan admin/root_admin
# - boleh create server lewat panel/PTLA untuk user manapun
# - boleh create server untuk akun admin dia sendiri
# - tidak boleh create server untuk admin/root_admin lain termasuk admin utama
# - tidak boleh list/detail/delete/delsrv server lewat dashboard/PTLA/PTLC
# - TIDAK boleh list server lewat dashboard/PTLA/PTLC
# - TIDAK boleh detail server orang lewat PTLA/PTLC
# - TIDAK boleh delete/delsrv server lewat panel/PTLA/PTLC
# - boleh create PTLA/PTLC
# - tidak boleh revoke/delete API key
# - nodes/nests/settings tetap khusus admin utama
#
# User biasa:
# - tidak boleh create PTLC
# - tetap bisa file manager/download/backup server masing-masing sesuai permission
#
# Install:
#   MAIN_ADMIN_ID=1 bash kahfi-full-protect-same-theme-final-v12.sh
# atau:
#   MAIN_ADMIN_ID=1 bash kahfi-full-protect-same-theme-final-v12.sh /var/www/pterodactyl
# ==========================================================

MAIN_ADMIN_ID="${MAIN_ADMIN_ID:-1}"
PANEL_PATH="${1:-/var/www/pterodactyl}"
BACKUP_DIR="/root/pterodactyl_backups"
TIMESTAMP="$(date -u +"%Y-%m-%d-%H-%M-%S")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

print_status(){ echo -e "${BLUE}${NC}$1"; }
print_success(){ echo -e "${GREEN}${NC}$1"; }
print_warning(){ echo -e "${YELLOW}${NC}$1"; }
print_error(){ echo -e "${RED}${NC}$1"; }
fail(){ print_error "$1"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Jalankan sebagai root di VPS panel."
[ -f "$PANEL_PATH/artisan" ] || fail "Folder panel tidak benar / artisan tidak ketemu: $PANEL_PATH"

mkdir -p "$BACKUP_DIR"
cd "$PANEL_PATH"

print_status "Starting kahfimoodtzyy Full Protect v12..."
print_status "Panel: $PANEL_PATH"
print_status "Main admin ID: $MAIN_ADMIN_ID"
print_status "Backup: $BACKUP_DIR"
echo ""

backup_file(){
    local file_path="$1"
    local backup_name="$2"
    if [ -f "$file_path" ]; then
        cp -a "$file_path" "$BACKUP_DIR/${backup_name}_${TIMESTAMP}.bak"
        print_status "Backed up: $backup_name"
    fi
}

backup_file ".env" "env"
backup_file "app/Providers/AppServiceProvider.php" "AppServiceProvider"
backup_file "app/Http/Kernel.php" "Kernel"
backup_file "app/Services/Servers/ServerCreationService.php" "ServerCreationService"
backup_file "app/Services/Servers/ServerDeletionService.php" "ServerDeletionService"
backup_file "app/Services/Users/UserCreationService.php" "UserCreationService"
backup_file "app/Services/Users/UserUpdateService.php" "UserUpdateService"
backup_file "app/Http/Controllers/Admin/UserController.php" "UserController"
backup_file "resources/views/layouts/admin.blade.php" "admin_layout"

if grep -q '^KAHFI_MAIN_ADMIN_ID=' .env 2>/dev/null; then
    sed -i "s/^KAHFI_MAIN_ADMIN_ID=.*/KAHFI_MAIN_ADMIN_ID=${MAIN_ADMIN_ID}/" .env
else
    printf '\nKAHFI_MAIN_ADMIN_ID=%s\n' "$MAIN_ADMIN_ID" >> .env
fi

# Disable old owner restriction guards that were installed by previous versions.
# v12 rule:
# - admin selain utama boleh create server untuk user biasa mana pun
# - admin selain utama boleh create server untuk akun admin dia sendiri
# - admin selain utama tidak boleh create server untuk admin/root_admin lain, termasuk admin utama
if [ -f app/Services/Servers/ServerCreationService.php ]; then
    perl -0777 -i -pe 's/if \(\$kahfiShouldCheckServerCreate && \(int\) \$kahfiActorId !== \$kahfiMainAdminId\) \{/if (false && \$kahfiShouldCheckServerCreate && (int) \$kahfiActorId !== \$kahfiMainAdminId) {/g' app/Services/Servers/ServerCreationService.php 2>/dev/null || true

    php <<'PHP_CLEAN_LEGACY_SERVER_CREATE'
<?php
$file = 'app/Services/Servers/ServerCreationService.php';
if (!is_file($file)) {
    exit(0);
}

$s = file_get_contents($file);
if ($s === false) {
    exit(0);
}

$before = $s;

/*
 * Fix legacy v5/v7 blocks that threw:
 * "Pilih user biasa"
 * Those old blocks blocked self-admin server creation. v12 allows self-admin.
 */
$legacyThrows = [
    "throw new \\Pterodactyl\\Exceptions\\DisplayException('Admin selain utama tidak boleh create server untuk admin/root_admin lain termasuk admin utama.');",
    'throw new \\Pterodactyl\\Exceptions\\DisplayException("Admin selain utama tidak boleh create server untuk admin/root_admin lain termasuk admin utama.");',
];

$newThrow = "if ((int) (\$kahfiOwner->id ?? 0) !== (int) ((\$kahfiAuthUser->id ?? null) ?? (\$kahfiActorId ?? 0))) { throw new \\Pterodactyl\\Exceptions\\DisplayException('Admin selain utama tidak boleh create server untuk admin/root_admin lain termasuk admin utama.'); }";

foreach ($legacyThrows as $oldThrow) {
    $s = str_replace($oldThrow, $newThrow, $s);
}

/*
 * If old v5 guard says "owner user biasa", keep it only as a normal missing-owner error.
 * The root_admin block above is changed to allow self-admin.
 */

if ($s !== $before) {
    file_put_contents($file, $s);
    echo "Cleaned legacy ServerCreationService self-admin blocker.\n";
}
PHP_CLEAN_LEGACY_SERVER_CREATE
fi

# Remove older middleware files from previous broken experiments so only v12 class is active.
rm -f app/Http/Middleware/KahfiFullAdminProtect.php
rm -f app/Http/Middleware/KahfiAdminOwnServerAccess.php
rm -f app/Http/Middleware/KahfiPanelFullProtect.php

# Remove old AppServiceProvider middleware registrations from previous experiments.
if [ -f app/Providers/AppServiceProvider.php ]; then
    perl -0777 -i -pe "s/\\n\\s*\\\$this->app\\['router'\\]->pushMiddlewareToGroup\\('web', \\\\Pterodactyl\\\\Http\\\\Middleware\\\\KahfiFullAdminProtect::class\\);\\s*//g" app/Providers/AppServiceProvider.php 2>/dev/null || true
    perl -0777 -i -pe "s/\\n\\s*\\\$this->app\\['router'\\]->pushMiddlewareToGroup\\('api', \\\\Pterodactyl\\\\Http\\\\Middleware\\\\KahfiFullAdminProtect::class\\);\\s*//g" app/Providers/AppServiceProvider.php 2>/dev/null || true
    perl -0777 -i -pe "s/\\n\\s*\\\$this->app\\['router'\\]->pushMiddlewareToGroup\\('web', \\\\Pterodactyl\\\\Http\\\\Middleware\\\\KahfiAdminOwnServerAccess::class\\);\\s*//g" app/Providers/AppServiceProvider.php 2>/dev/null || true
    perl -0777 -i -pe "s/\\n\\s*\\\$this->app\\['router'\\]->pushMiddlewareToGroup\\('api', \\\\Pterodactyl\\\\Http\\\\Middleware\\\\KahfiAdminOwnServerAccess::class\\);\\s*//g" app/Providers/AppServiceProvider.php 2>/dev/null || true
fi

mkdir -p app/Http/Middleware

cat > app/Http/Middleware/KahfiMoodTzyPanelProtect.php <<'PHP'
<?php

namespace Pterodactyl\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Pterodactyl\Models\Server;
use Symfony\Component\HttpFoundation\Response;

class KahfiMoodTzyPanelProtect
{
    public function handle(Request $request, Closure $next): Response
    {
        $path = trim($request->path(), '/');
        $method = strtoupper($request->method());
        $mainAdminId = (int) env('KAHFI_MAIN_ADMIN_ID', 1);

        /*
         * PTLA/Application API server guard:
         * Admin selain utama:
         * - BOLEH create server untuk user manapun.
         * - BOLEH create server untuk akun admin dia sendiri.
         * - TIDAK BOLEH create server untuk admin/root_admin lain termasuk admin utama.
         * - TIDAK BOLEH list/detail/update/delete/delsrv server.
         * Jika owner token tidak terbaca, dianggap bukan admin utama.
         */
        if ($this->starts($path, 'api/application/servers')) {
            $actorId = $this->actingUserId($request);
            $isMain = $actorId !== null && (int) $actorId === $mainAdminId;
            $isCreate = $method === 'POST' && ($path === 'api/application/servers' || $path === 'api/application/servers/');

            if (!$isMain) {
                if ($isCreate) {
                    // Admin selain utama boleh create server untuk user manapun,
                    // tapi jika owner adalah admin/root_admin, hanya boleh untuk akun admin dia sendiri.
                    $ownerId = $this->requestedServerOwnerId($request);

                    if (!$ownerId) {
                        return $this->deny($request, 'Create server wajib memilih owner.');
                    }

                    if ($this->isRootAdminUserId($ownerId) && (int) $ownerId !== (int) $actorId) {
                        return $this->deny($request, 'Admin selain utama tidak boleh create server untuk admin/root_admin lain termasuk admin utama.');
                    }

                    return $next($request);
                }

                return $this->deny($request, 'List/detail/update/delete server lewat PTLA/PTLC hanya untuk admin utama.');
            }
        }

        /*
         * PTLA/Application API user guard:
         * Admin selain utama boleh create user biasa, tapi tidak boleh create/update root_admin.
         */
        if ($this->starts($path, 'api/application/users') && in_array($method, ['POST', 'PUT', 'PATCH'], true)) {
            $actorId = $this->actingUserId($request);
            $isMain = $actorId !== null && (int) $actorId === $mainAdminId;

            if (!$isMain && $this->requestTouchesAdminFlag($request)) {
                return $this->deny($request, 'Admin selain utama tidak boleh create/edit user admin lewat PTLA.');
            }
        }

        $user = $request->user();

        /*
         * User biasa:
         * - tidak boleh create PTLC
         * - file/download/backup milik sendiri tetap jalan bawaan Pterodactyl
         */
        if ($user && empty($user->root_admin)) {
            if ($this->isPtlcCreate($request, $path)) {
                return $this->deny($request, 'User biasa tidak boleh membuat PTLC/API key.');
            }

            return $next($request);
        }

        if (!$user) {
            return $next($request);
        }

        if ((int) $user->id === $mainAdminId) {
            return $next($request);
        }

        /*
         * Admin selain utama:
         * boleh create PTLA/PTLC, tapi tidak boleh revoke/delete.
         */
        if ($this->isApiKeyDelete($request, $path)) {
            return $this->deny($request, 'Hanya admin utama yang boleh revoke/delete API key.');
        }

        /*
         * Admin selain utama boleh create user biasa, bukan admin/root_admin.
         */
        if ($this->isUserCreateRequest($request, $path)) {
            if ($this->requestTouchesAdminFlag($request)) {
                return $this->deny($request, 'Admin selain utama tidak boleh membuat user admin/root_admin.');
            }
        }

        if ($this->isUserPrivilegeUpdate($request, $path)) {
            if ($request->has('root_admin') || $request->has('admin') || $request->has('is_admin')) {
                return $this->deny($request, 'Admin selain utama tidak boleh mengubah privilege admin.');
            }
        }

        /*
         * Admin selain utama boleh create server manual/PTLA untuk user manapun.
         * Kalau owner adalah admin/root_admin, hanya boleh akun admin dia sendiri.
         * Larangan list/detail/delete/delsrv tetap aktif.
         */
        if ($this->isAdminServerCreate($request, $path)) {
            $ownerId = $this->requestedServerOwnerId($request);

            if (!$ownerId) {
                return $this->deny($request, 'Create server wajib memilih owner.');
            }

            if ($this->isRootAdminUserId($ownerId) && (int) $ownerId !== (int) $user->id) {
                return $this->deny($request, 'Admin selain utama tidak boleh create server untuk admin/root_admin lain termasuk admin utama.');
            }
        }

        $adminBlock = $this->blockedAdminArea($request, $path);
        if ($adminBlock instanceof Response) {
            return $adminBlock;
        }

        /*
         * Dashboard client admin selain utama:
         * jangan tampilkan server apapun, walaupun dia yang create via PTLA.
         * Ini supaya dia tidak bisa lihat data server/user hasil create.
         */
        if ($this->isClientServerList($request, $path)) {
            $response = $next($request);
            return $this->emptyServerListResponse($request, $response);
        }

        /*
         * Direct access server:
         * Admin selain utama hanya boleh akses server yang memang owner_id dia sendiri.
         * Server milik user biasa yang dia create tetap tidak boleh dilihat.
         */
        $server = $this->serverFromRequest($request, $path);
        if ($server instanceof Server && (int) $server->owner_id !== (int) $user->id) {
            return $this->deny($request, 'Admin selain utama tidak boleh melihat data server orang lain.');
        }

        return $next($request);
    }

    private function blockedAdminArea(Request $request, string $path): ?Response
    {
        $mainOnlyAll = [
            'admin/settings',
            'admin/system',
            'admin/roles',
            'admin/mounts',
        ];

        foreach ($mainOnlyAll as $prefix) {
            if ($this->starts($path, $prefix)) {
                return $this->deny($request, 'Area ini hanya untuk admin utama.');
            }
        }

        /*
         * Nodes dan Nests:
         * - halaman langsung tetap 403
         * - ajax/json GET tetap boleh supaya form create server tidak rusak
         */
        foreach (['admin/nodes', 'admin/nests'] as $prefix) {
            if ($this->starts($path, $prefix)) {
                if ($this->isSafeCreateServerSupportRead($request)) {
                    return null;
                }

                return $this->deny($request, 'Nodes dan Nests hanya boleh diakses admin utama.');
            }
        }

        /*
         * User detail/list tidak boleh untuk admin selain utama.
         * Create user biasa tetap boleh.
         */
        $blockedUserPrefixes = [
            'admin/users/view',
            'admin/users/edit',
            'admin/users/delete',
            'admin/users/two-factor',
        ];

        foreach ($blockedUserPrefixes as $prefix) {
            if ($this->starts($path, $prefix)) {
                return $this->deny($request, 'Admin selain utama tidak boleh membuka detail/edit/delete user.');
            }
        }

        if (($path === 'admin/users' || $path === 'admin/users/') && $request->isMethod('GET')) {
            return redirect('/admin/users/new');
        }

        /*
         * Jangan tampilkan list semua server.
         * Tapi admin selain utama tetap boleh masuk halaman create server.
         */
        if (($path === 'admin/servers' || $path === 'admin/servers/') && $request->isMethod('GET')) {
            return redirect('/admin/servers/new');
        }

        $globalWriteOnly = [
            'admin/locations',
            'admin/databases',
        ];

        foreach ($globalWriteOnly as $prefix) {
            if ($this->starts($path, $prefix) && !$request->isMethod('GET')) {
                return $this->deny($request, 'Admin selain utama tidak boleh mengubah data global panel.');
            }
        }

        return null;
    }

    private function isSafeCreateServerSupportRead(Request $request): bool
    {
        return $request->isMethod('GET') && ($request->ajax() || $request->expectsJson());
    }

    private function requestedServerOwnerId(Request $request): ?int
    {
        foreach (['owner_id', 'user_id', 'user'] as $key) {
            $value = $request->input($key);
            if ($value !== null && $value !== '' && is_numeric($value)) {
                return (int) $value;
            }
        }

        return null;
    }

    private function requestTouchesAdminFlag(Request $request): bool
    {
        foreach (['root_admin', 'admin', 'is_admin'] as $key) {
            if ($request->has($key) && $this->truthy($request->input($key))) {
                return true;
            }
        }

        return false;
    }

    private function isRootAdminUserId(int $userId): bool
    {
        try {
            $row = \Illuminate\Support\Facades\DB::table('users')->where('id', $userId)->first();
            return $row ? (bool) $row->root_admin : false;
        } catch (\Throwable $e) {
            return true;
        }
    }

    private function actingUserId(Request $request): ?int
    {
        $user = $request->user();

        if ($user instanceof \Pterodactyl\Models\User && isset($user->id)) {
            return (int) $user->id;
        }

        try {
            $authUser = \Illuminate\Support\Facades\Auth::user();
            if ($authUser instanceof \Pterodactyl\Models\User && isset($authUser->id)) {
                return (int) $authUser->id;
            }
        } catch (\Throwable $e) {
            // ignore
        }

        /*
         * Beberapa middleware Application API menyimpan model API key di attributes.
         */
        try {
            foreach ($request->attributes->all() as $value) {
                if (is_object($value) && isset($value->user_id)) {
                    return (int) $value->user_id;
                }

                if (is_array($value) && isset($value['user_id'])) {
                    return (int) $value['user_id'];
                }
            }
        } catch (\Throwable $e) {
            // ignore
        }

        return $this->apiKeyOwnerId($request);
    }

    private function apiKeyOwnerId(Request $request): ?int
    {
        $token = (string) $request->bearerToken();

        if ($token === '') {
            $header = (string) $request->header('Authorization', '');
            if (preg_match('/Bearer\s+(.+)/i', $header, $m)) {
                $token = trim($m[1]);
            }
        }

        if ($token === '') {
            $header = (string) ($_SERVER['HTTP_AUTHORIZATION'] ?? '');
            if (preg_match('/Bearer\s+(.+)/i', $header, $m)) {
                $token = trim($m[1]);
            }
        }

        if ($token === '') {
            return null;
        }

        $raw = preg_replace('/^(ptla_|ptlc_)/i', '', $token);
        $candidates = [];

        foreach ([16, 20, 24, 32, 8] as $len) {
            if (strlen($raw) >= $len) {
                $candidates[] = substr($raw, 0, $len);
            }
        }

        foreach (preg_split('/[._\-]/', $raw) ?: [] as $part) {
            if (strlen($part) >= 8) {
                $candidates[] = $part;
                foreach ([16, 20, 24, 32, 8] as $len) {
                    if (strlen($part) >= $len) {
                        $candidates[] = substr($part, 0, $len);
                    }
                }
            }
        }

        if (preg_match('/^((?:ptla|ptlc)_[A-Za-z0-9]+)/', $token, $m)) {
            $candidates[] = $m[1];
        }

        $candidates = array_values(array_unique(array_filter($candidates)));

        foreach ($candidates as $identifier) {
            try {
                $row = \Illuminate\Support\Facades\DB::table('api_keys')
                    ->where('identifier', $identifier)
                    ->first();

                if ($row && isset($row->user_id)) {
                    return (int) $row->user_id;
                }
            } catch (\Throwable $e) {
                // ignore
            }
        }

        return null;
    }

    private function isPtlcCreate(Request $request, string $path): bool
    {
        return $request->isMethod('POST') && (
            $path === 'api/client/account/api-keys'
            || $path === 'api/client/account/api-keys/'
            || $path === 'account/api'
            || $path === 'account/api/'
        );
    }

    private function isApiKeyDelete(Request $request, string $path): bool
    {
        if (!in_array(strtoupper($request->method()), ['DELETE', 'POST'], true)) {
            return false;
        }

        $isDeleteAction = $request->isMethod('DELETE')
            || $request->input('_method') === 'DELETE'
            || strtolower((string) $request->input('action')) === 'delete'
            || strtolower((string) $request->input('action')) === 'revoke';

        if (!$isDeleteAction) {
            return false;
        }

        return $this->starts($path, 'admin/api')
            || $this->starts($path, 'api/client/account/api-keys')
            || $this->starts($path, 'account/api')
            || $this->starts($path, 'api/application/api-keys');
    }

    private function isUserCreateRequest(Request $request, string $path): bool
    {
        return in_array(strtoupper($request->method()), ['POST', 'PUT', 'PATCH'], true)
            && ($path === 'admin/users' || $path === 'admin/users/' || $path === 'admin/users/new' || $path === 'admin/users/new/');
    }

    private function isUserPrivilegeUpdate(Request $request, string $path): bool
    {
        return in_array(strtoupper($request->method()), ['POST', 'PUT', 'PATCH'], true)
            && ($this->starts($path, 'admin/users/view') || $this->starts($path, 'admin/users/edit'));
    }

    private function isAdminServerCreate(Request $request, string $path): bool
    {
        return in_array(strtoupper($request->method()), ['POST', 'PUT', 'PATCH'], true)
            && ($path === 'admin/servers' || $path === 'admin/servers/' || $path === 'admin/servers/new' || $path === 'admin/servers/new/');
    }

    private function isClientServerList(Request $request, string $path): bool
    {
        return $request->isMethod('GET') && (
            $path === 'api/client'
            || $path === 'api/client/'
            || $path === 'api/client/servers'
            || $path === 'api/client/servers/'
        );
    }

    private function serverFromRequest(Request $request, string $path): ?Server
    {
        if (preg_match('#^api/client/servers/([^/]+)(?:/|$)#', $path, $m)) {
            return $this->findServer($m[1]);
        }

        if (preg_match('#^(server|servers)/([^/]+)(?:/|$)#', $path, $m)) {
            return $this->findServer($m[2]);
        }

        if ($path === 'admin/servers' || $path === 'admin/servers/' || $this->starts($path, 'admin/servers/new')) {
            return null;
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

    private function emptyServerListResponse(Request $request, Response $response): Response
    {
        $payload = null;

        if ($response->getStatusCode() === 200 && method_exists($response, 'getContent')) {
            $payload = json_decode($response->getContent(), true);
        }

        if (!is_array($payload)) {
            $payload = [
                'object' => 'list',
                'data' => [],
            ];
        }

        if (isset($payload['data']) && is_array($payload['data'])) {
            $payload['data'] = [];
        }

        if (isset($payload['meta']['pagination']) && is_array($payload['meta']['pagination'])) {
            $payload['meta']['pagination']['total'] = 0;
            $payload['meta']['pagination']['count'] = 0;
            $payload['meta']['pagination']['per_page'] = 1;
            $payload['meta']['pagination']['current_page'] = 1;
            $payload['meta']['pagination']['total_pages'] = 1;
        }

        return response()->json($payload, 200);
    }

    private function truthy($value): bool
    {
        if (is_bool($value)) return $value;
        if (is_numeric($value)) return (int) $value === 1;

        $value = strtolower((string) $value);
        return in_array($value, ['1', 'true', 'on', 'yes', 'admin', 'root'], true);
    }

    private function starts(string $path, string $prefix): bool
    {
        $prefix = trim($prefix, '/');

        return $path === $prefix || str_starts_with($path, $prefix . '/');
    }

    private function deny(Request $request, string $message): Response
    {
        $path = trim($request->path(), '/');

        if ($request->expectsJson() || $request->ajax() || str_starts_with($path, 'api/')) {
            return response()->json([
                'errors' => [[
                    'code' => 'KahfiMoodTzyProtected',
                    'status' => '403',
                    'detail' => $message,
                ]],
            ], 403);
        }

        abort(403, $message);
    }
}
PHP

print_success "Middleware v7 dibuat."

# ==========================================================
# Inject middleware ke AppServiceProvider untuk web/api/client-api/application-api.
# ==========================================================
php <<'PHP_PATCH'
<?php

$file = 'app/Providers/AppServiceProvider.php';
$class = '\\Pterodactyl\\Http\\Middleware\\KahfiMoodTzyPanelProtect::class';
$marker = 'KAHFIMOODTZYY_PANEL_PROTECT_BOOT_V12';

if (!is_file($file)) {
    fwrite(STDERR, "AppServiceProvider.php tidak ditemukan\n");
    exit(1);
}

$s = file_get_contents($file);

$lines = [
    "\$this->app['router']->pushMiddlewareToGroup('web', {$class});",
    "\$this->app['router']->pushMiddlewareToGroup('api', {$class});",
    "\$this->app['router']->pushMiddlewareToGroup('client-api', {$class});",
    "\$this->app['router']->pushMiddlewareToGroup('application-api', {$class});",
];

$missing = [];
foreach ($lines as $line) {
    if (strpos($s, $line) === false) {
        $missing[] = $line;
    }
}

if (empty($missing)) {
    echo "AppServiceProvider middleware sudah lengkap.\n";
    exit(0);
}

$inject = "\n        // {$marker}\n        " . implode("\n        ", $missing) . "\n";

if (preg_match('/public\s+function\s+boot\s*\([^)]*\)\s*(?::\s*void\s*)?\{/m', $s, $m, PREG_OFFSET_CAPTURE)) {
    $pos = $m[0][1] + strlen($m[0][0]);
    $s = substr($s, 0, $pos) . $inject . substr($s, $pos);
} else {
    $pos = strrpos($s, "\n}");
    if ($pos === false) {
        fwrite(STDERR, "Gagal patch AppServiceProvider.php\n");
        exit(1);
    }

    $method = "\n    public function boot(): void\n    {\n" . $inject . "    }\n";
    $s = substr($s, 0, $pos) . $method . substr($s, $pos);
}

file_put_contents($file, $s);
echo "AppServiceProvider berhasil dipatch v7.\n";
PHP_PATCH

# ==========================================================
# Shared PHP patch helpers for service-level guards.
# ==========================================================
php <<'PHP_PATCH'
<?php

function kahfi_actor_php_code(): string
{
    return <<<'CODE'
        $kahfiMainAdminId = (int) env('KAHFI_MAIN_ADMIN_ID', 1);
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }

        $kahfiActorId = null;
        if ($kahfiAuthUser instanceof \Pterodactyl\Models\User && isset($kahfiAuthUser->id)) {
            $kahfiActorId = (int) $kahfiAuthUser->id;
        }

        if (!$kahfiActorId) {
            try {
                foreach (request()->attributes->all() as $kahfiAttr) {
                    if (is_object($kahfiAttr) && isset($kahfiAttr->user_id)) {
                        $kahfiActorId = (int) $kahfiAttr->user_id;
                        break;
                    }
                    if (is_array($kahfiAttr) && isset($kahfiAttr['user_id'])) {
                        $kahfiActorId = (int) $kahfiAttr['user_id'];
                        break;
                    }
                }
            } catch (\Throwable $e) {}
        }

        if (!$kahfiActorId) {
            try {
                $kahfiToken = (string) request()->bearerToken();
                if ($kahfiToken === '') {
                    $kahfiHeader = (string) request()->header('Authorization', '');
                    if (preg_match('/Bearer\s+(.+)/i', $kahfiHeader, $kahfiMatch)) {
                        $kahfiToken = trim($kahfiMatch[1]);
                    }
                }

                $kahfiRaw = preg_replace('/^(ptla_|ptlc_)/i', '', $kahfiToken);
                $kahfiCandidates = [];
                foreach ([16, 20, 24, 32, 8] as $kahfiLen) {
                    if (strlen($kahfiRaw) >= $kahfiLen) {
                        $kahfiCandidates[] = substr($kahfiRaw, 0, $kahfiLen);
                    }
                }
                foreach (preg_split('/[._\-]/', $kahfiRaw) ?: [] as $kahfiPart) {
                    if (strlen($kahfiPart) >= 8) {
                        $kahfiCandidates[] = $kahfiPart;
                        foreach ([16, 20, 24, 32, 8] as $kahfiLen) {
                            if (strlen($kahfiPart) >= $kahfiLen) {
                                $kahfiCandidates[] = substr($kahfiPart, 0, $kahfiLen);
                            }
                        }
                    }
                }
                if (preg_match('/^((?:ptla|ptlc)_[A-Za-z0-9]+)/', $kahfiToken, $kahfiMatch2)) {
                    $kahfiCandidates[] = $kahfiMatch2[1];
                }

                foreach (array_values(array_unique(array_filter($kahfiCandidates))) as $kahfiIdentifier) {
                    $kahfiRow = \Illuminate\Support\Facades\DB::table('api_keys')->where('identifier', $kahfiIdentifier)->first();
                    if ($kahfiRow && isset($kahfiRow->user_id)) {
                        $kahfiActorId = (int) $kahfiRow->user_id;
                        break;
                    }
                }
            } catch (\Throwable $e) {
                $kahfiActorId = null;
            }
        }

        $kahfiPath = '';
        try { $kahfiPath = trim(request()->path(), '/'); } catch (\Throwable $e) {}
CODE;
}

function kahfi_patch_handle_guard(string $file, string $marker, string $guard): void
{
    if (!is_file($file)) {
        echo "SKIP not found: {$file}\n";
        return;
    }

    $s = file_get_contents($file);
    if (strpos($s, $marker) !== false) {
        echo "Already patched: {$file}\n";
        return;
    }

    $pattern = '/public\s+function\s+handle\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{/m';
    if (!preg_match($pattern, $s, $m, PREG_OFFSET_CAPTURE)) {
        echo "WARNING handle() not found: {$file}\n";
        return;
    }

    $pos = $m[0][1] + strlen($m[0][0]);
    $s = substr($s, 0, $pos) . "\n" . rtrim($guard) . "\n" . substr($s, $pos);
    file_put_contents($file, $s);
    echo "Patched handle guard: {$file}\n";
}

$actor = kahfi_actor_php_code();

kahfi_patch_handle_guard(
    'app/Services/Servers/ServerCreationService.php',
    'kahfimoodtzyy server owner admin self only guard v12',
    <<<GUARD
        // kahfimoodtzyy server owner admin self only guard v12
{$actor}
        // Admin selain utama boleh create server untuk user manapun.
        // Jika owner adalah admin/root_admin, hanya boleh akun admin dia sendiri.
        \$kahfiShouldCheckServerCreate = false;

        if (str_starts_with(\$kahfiPath, 'api/application/servers')) {
            \$kahfiShouldCheckServerCreate = true;
        }

        if (\$kahfiAuthUser instanceof \Pterodactyl\Models\User && !empty(\$kahfiAuthUser->root_admin) && (int) \$kahfiAuthUser->id !== \$kahfiMainAdminId) {
            \$kahfiShouldCheckServerCreate = true;
        }

        if (\$kahfiShouldCheckServerCreate && (int) \$kahfiActorId !== \$kahfiMainAdminId) {
            \$kahfiOwnerId = null;
            if (isset(\$data) && is_array(\$data)) {
                \$kahfiOwnerId = \$data['owner_id'] ?? \$data['user_id'] ?? \$data['user'] ?? null;
            }

            if (!\$kahfiOwnerId || !is_numeric(\$kahfiOwnerId)) {
                throw new \Pterodactyl\Exceptions\DisplayException('Create server wajib memilih owner.');
            }

            try {
                \$kahfiOwner = \Pterodactyl\Models\User::query()->find((int) \$kahfiOwnerId);
            } catch (\Throwable \$e) {
                \$kahfiOwner = null;
            }

            if (!\$kahfiOwner) {
                throw new \Pterodactyl\Exceptions\DisplayException('Owner user tidak ditemukan.');
            }

            if (!empty(\$kahfiOwner->root_admin) && (int) \$kahfiOwner->id !== (int) \$kahfiActorId) {
                throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh create server untuk admin/root_admin lain termasuk admin utama.');
            }
        }
GUARD
);

kahfi_patch_handle_guard(
    'app/Services/Servers/ServerDeletionService.php',
    'kahfimoodtzyy server deletion main admin only guard v7',
    <<<GUARD
        // kahfimoodtzyy server deletion main admin only guard v7
{$actor}
        if ((int) \$kahfiActorId !== \$kahfiMainAdminId) {
            throw new \Pterodactyl\Exceptions\DisplayException('Delete/delsrv server hanya untuk admin utama.');
        }
GUARD
);

kahfi_patch_handle_guard(
    'app/Services/Users/UserCreationService.php',
    'kahfimoodtzyy user admin hard error guard v7',
    <<<GUARD
        // kahfimoodtzyy user admin hard error guard v7
{$actor}
        \$kahfiRootRequested = false;

        if (isset(\$data) && is_array(\$data)) {
            foreach (['root_admin', 'admin', 'is_admin'] as \$kahfiKey) {
                if (array_key_exists(\$kahfiKey, \$data) && filter_var(\$data[\$kahfiKey], FILTER_VALIDATE_BOOLEAN)) {
                    \$kahfiRootRequested = true;
                    break;
                }
            }
        }

        if (
            \$kahfiRootRequested
            && (
                (\$kahfiAuthUser instanceof \Pterodactyl\Models\User && !empty(\$kahfiAuthUser->root_admin) && (int) \$kahfiAuthUser->id !== \$kahfiMainAdminId)
                || (str_starts_with(\$kahfiPath, 'api/application/users') && (int) \$kahfiActorId !== \$kahfiMainAdminId)
            )
        ) {
            throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh membuat user admin/root_admin.');
        }
GUARD
);

kahfi_patch_handle_guard(
    'app/Services/Users/UserUpdateService.php',
    'kahfimoodtzyy block admin privilege update guard v7',
    <<<GUARD
        // kahfimoodtzyy block admin privilege update guard v7
{$actor}
        \$kahfiRootTouched = isset(\$data) && is_array(\$data) && (
            array_key_exists('root_admin', \$data)
            || array_key_exists('admin', \$data)
            || array_key_exists('is_admin', \$data)
        );

        if (
            \$kahfiRootTouched
            && (
                (\$kahfiAuthUser instanceof \Pterodactyl\Models\User && !empty(\$kahfiAuthUser->root_admin) && (int) \$kahfiAuthUser->id !== \$kahfiMainAdminId)
                || (str_starts_with(\$kahfiPath, 'api/application/users') && (int) \$kahfiActorId !== \$kahfiMainAdminId)
            )
        ) {
            throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh mengubah privilege admin.');
        }

        if (\$kahfiAuthUser instanceof \Pterodactyl\Models\User && !empty(\$kahfiAuthUser->root_admin) && (int) \$kahfiAuthUser->id !== \$kahfiMainAdminId) {
            if (isset(\$user) && is_object(\$user) && !empty(\$user->root_admin)) {
                throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh edit akun admin.');
            }
        }
GUARD
);
PHP_PATCH

# ==========================================================
# Patch Application API server controllers:
# list/detail/update/delete blocked for admin selain utama.
# store/create intentionally NOT patched.
# ==========================================================
php <<'PHP_PATCH'
<?php

function kahfi_actor_guard_block_code(): string
{
    return <<<'GUARD'
        // kahfimoodtzyy application server no-list-no-delete guard v7
        $kahfiMainAdminId = (int) env('KAHFI_MAIN_ADMIN_ID', 1);
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }

        $kahfiActorId = null;
        if ($kahfiAuthUser instanceof \Pterodactyl\Models\User && isset($kahfiAuthUser->id)) {
            $kahfiActorId = (int) $kahfiAuthUser->id;
        }

        if (!$kahfiActorId) {
            try {
                foreach (request()->attributes->all() as $kahfiAttr) {
                    if (is_object($kahfiAttr) && isset($kahfiAttr->user_id)) {
                        $kahfiActorId = (int) $kahfiAttr->user_id;
                        break;
                    }
                    if (is_array($kahfiAttr) && isset($kahfiAttr['user_id'])) {
                        $kahfiActorId = (int) $kahfiAttr['user_id'];
                        break;
                    }
                }
            } catch (\Throwable $e) {}
        }

        if (!$kahfiActorId) {
            try {
                $kahfiToken = (string) request()->bearerToken();
                if ($kahfiToken === '') {
                    $kahfiHeader = (string) request()->header('Authorization', '');
                    if (preg_match('/Bearer\s+(.+)/i', $kahfiHeader, $kahfiMatch)) {
                        $kahfiToken = trim($kahfiMatch[1]);
                    }
                }

                $kahfiRaw = preg_replace('/^(ptla_|ptlc_)/i', '', $kahfiToken);
                $kahfiCandidates = [];
                foreach ([16, 20, 24, 32, 8] as $kahfiLen) {
                    if (strlen($kahfiRaw) >= $kahfiLen) {
                        $kahfiCandidates[] = substr($kahfiRaw, 0, $kahfiLen);
                    }
                }
                foreach (preg_split('/[._\-]/', $kahfiRaw) ?: [] as $kahfiPart) {
                    if (strlen($kahfiPart) >= 8) {
                        $kahfiCandidates[] = $kahfiPart;
                        foreach ([16, 20, 24, 32, 8] as $kahfiLen) {
                            if (strlen($kahfiPart) >= $kahfiLen) {
                                $kahfiCandidates[] = substr($kahfiPart, 0, $kahfiLen);
                            }
                        }
                    }
                }
                if (preg_match('/^((?:ptla|ptlc)_[A-Za-z0-9]+)/', $kahfiToken, $kahfiMatch2)) {
                    $kahfiCandidates[] = $kahfiMatch2[1];
                }

                foreach (array_values(array_unique(array_filter($kahfiCandidates))) as $kahfiIdentifier) {
                    $kahfiRow = \Illuminate\Support\Facades\DB::table('api_keys')->where('identifier', $kahfiIdentifier)->first();
                    if ($kahfiRow && isset($kahfiRow->user_id)) {
                        $kahfiActorId = (int) $kahfiRow->user_id;
                        break;
                    }
                }
            } catch (\Throwable $e) {
                $kahfiActorId = null;
            }
        }

        if ((int) $kahfiActorId !== $kahfiMainAdminId) {
            throw new \Pterodactyl\Exceptions\DisplayException('List/detail/update/delete server lewat PTLA/PTLC hanya untuk admin utama.');
        }
GUARD;
}

function kahfi_patch_named_methods(string $file, array $methods, string $marker, string $guard): void
{
    if (!is_file($file)) {
        return;
    }

    $s = file_get_contents($file);
    if (strpos($s, $marker) !== false) {
        echo "Already patched application server: {$file}\n";
        return;
    }

    $regex = implode('|', array_map('preg_quote', $methods));
    $pattern = '/public\s+function\s+(' . $regex . ')\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{/m';

    $count = 0;
    $patched = preg_replace_callback($pattern, function ($m) use ($guard, &$count) {
        $count++;
        return $m[0] . "\n" . rtrim($guard) . "\n";
    }, $s, -1, $count);

    if ($count > 0 && $patched !== null) {
        file_put_contents($file, $patched);
        echo "Patched application server no-list/no-delete: {$file} ({$count})\n";
    }
}

$guard = kahfi_actor_guard_block_code();
$methods = [
    'index', 'view', 'show', 'details',
    'update', 'updateDetails', 'updateBuild', 'updateStartup',
    'delete', 'destroy', 'remove',
    'suspend', 'unsuspend', 'reinstall',
    'build', 'startup', 'database', 'databases',
];

$paths = [
    'app/Http/Controllers/Api/Application/Servers',
    'app/Http/Controllers/Api/Application',
];

foreach ($paths as $dir) {
    if (!is_dir($dir)) continue;

    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $fileInfo) {
        if (!$fileInfo->isFile() || strtolower($fileInfo->getExtension()) !== 'php') {
            continue;
        }

        $file = $fileInfo->getPathname();
        $contents = file_get_contents($file);

        if (stripos($file, 'Server') !== false || stripos($contents, 'Pterodactyl\\Models\\Server') !== false || stripos($contents, 'ServerTransformer') !== false) {
            kahfi_patch_named_methods($file, $methods, 'kahfimoodtzyy application server no-list-no-delete guard v7', $guard);
        }
    }
}
PHP_PATCH

# ==========================================================
# Patch UserController redirect store user: admin lain balik ke create/list, bukan detail user.
# ==========================================================
php <<'PHP_PATCH'
<?php

$file = 'app/Http/Controllers/Admin/UserController.php';
if (!is_file($file)) {
    echo "SKIP UserController not found\n";
    exit(0);
}

$s = file_get_contents($file);
$marker = 'kahfimoodtzyy user store redirect patch v7';

if (strpos($s, $marker) !== false) {
    echo "UserController redirect sudah dipatch v7.\n";
    exit(0);
}

if (strpos($s, 'use Illuminate\Support\Facades\Auth;') === false) {
    $s = preg_replace('/namespace\s+Pterodactyl\\\\Http\\\\Controllers\\\\Admin;\s*/', "namespace Pterodactyl\\Http\\Controllers\\Admin;\n\nuse Illuminate\\Support\\Facades\\Auth;\n", $s, 1);
}

$replacements = [
    "return redirect()->route('admin.users.view', \$user->id);" => "// {$marker}\n        return ((int) Auth::id() === (int) env('KAHFI_MAIN_ADMIN_ID', 1))\n            ? redirect()->route('admin.users.view', \$user->id)\n            : redirect()->route('admin.users.new');",
    'return redirect()->route("admin.users.view", $user->id);' => "// {$marker}\n        return ((int) Auth::id() === (int) env('KAHFI_MAIN_ADMIN_ID', 1))\n            ? redirect()->route('admin.users.view', \$user->id)\n            : redirect()->route('admin.users.new');",
];

$done = false;
foreach ($replacements as $from => $to) {
    if (strpos($s, $from) !== false) {
        $s = str_replace($from, $to, $s);
        $done = true;
        break;
    }
}

if ($done) {
    file_put_contents($file, $s);
    echo "UserController redirect berhasil dipatch v7.\n";
} else {
    echo "WARNING: redirect store user tidak ditemukan, skip.\n";
}
PHP_PATCH

# ==========================================================
# API key delete/revoke guard: create PTLA/PTLC boleh, revoke/delete hanya admin utama.
# ==========================================================
php <<'PHP_PATCH'
<?php

function patch_methods_guard(string $file, array $methods, string $marker, string $guard): void
{
    if (!is_file($file)) return;

    $s = file_get_contents($file);
    if (strpos($s, $marker) !== false) {
        echo "Already API revoke patched: {$file}\n";
        return;
    }

    $regex = implode('|', array_map('preg_quote', $methods));
    $pattern = '/public\s+function\s+(' . $regex . ')\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{/m';

    $count = 0;
    $patched = preg_replace_callback($pattern, function ($m) use ($guard, &$count) {
        $count++;
        return $m[0] . "\n" . rtrim($guard) . "\n";
    }, $s, -1, $count);

    if ($count > 0 && $patched !== null) {
        file_put_contents($file, $patched);
        echo "Patched API key revoke: {$file} ({$count})\n";
    }
}

$guard = <<<'GUARD'
        // kahfimoodtzyy api key revoke main admin only guard v7
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }

        if ($kahfiAuthUser instanceof \Pterodactyl\Models\User && (int) $kahfiAuthUser->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            throw new \Pterodactyl\Exceptions\DisplayException('Revoke/delete API key hanya untuk admin utama.');
        }
GUARD;

$controllerCandidates = [
    'app/Http/Controllers/Admin/ApiController.php',
    'app/Http/Controllers/Admin/ApiKeyController.php',
    'app/Http/Controllers/Admin/ApiKeysController.php',
    'app/Http/Controllers/Api/Client/Account/ApiKeyController.php',
    'app/Http/Controllers/Api/Client/Account/ApiKeysController.php',
    'app/Http/Controllers/Api/Application/ApiKeyController.php',
    'app/Http/Controllers/Api/Application/ApiKeysController.php',
];

foreach ($controllerCandidates as $file) {
    patch_methods_guard($file, ['delete', 'destroy', 'revoke', 'remove'], 'kahfimoodtzyy api key revoke main admin only guard v7', $guard);
}

$dirs = ['app/Services', 'app/Http/Controllers'];
foreach ($dirs as $dir) {
    if (!is_dir($dir)) continue;
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $fileInfo) {
        if (!$fileInfo->isFile() || strtolower($fileInfo->getExtension()) !== 'php') continue;
        $file = $fileInfo->getPathname();
        $base = $fileInfo->getBasename();

        if (preg_match('/(KeyDeletionService|ApiKeyDeletionService|ApplicationApiKeyDeletionService|ClientApiKeyDeletionService)\.php$/i', $base)) {
            patch_methods_guard($file, ['handle', 'delete', 'destroy', 'revoke', 'remove'], 'kahfimoodtzyy api key revoke main admin only guard v7', $guard);
        }
    }
}
PHP_PATCH

# ==========================================================
# Theme same style: keep kahfimoodtzyy name.
# ==========================================================
print_status "Installing kahfimoodtzyy admin theme..."

CUSTOM_DIR="public/assets/custom"
CUSTOM_CSS="$CUSTOM_DIR/kahfimoodtzyy-theme.css"
CUSTOM_JS="$CUSTOM_DIR/kahfimoodtzyy-theme.js"
mkdir -p "$CUSTOM_DIR"

cat > "$CUSTOM_CSS" <<'CSS'
.kahfi-security-badge {
    position: fixed;
    top: 16px;
    right: 16px;
    background: linear-gradient(135deg, #ea4335, #7f1d1d);
    color: #fff;
    padding: 8px 14px;
    border-radius: 18px;
    font-size: 12px;
    font-weight: 700;
    z-index: 99999;
    box-shadow: 0 4px 14px rgba(0,0,0,.25);
    letter-spacing: .3px;
}
.kahfi-security-welcome {
    margin: 14px 0;
    padding: 12px 14px;
    border-radius: 10px;
    background: rgba(234,67,53,.10);
    border-left: 4px solid #ea4335;
    color: inherit;
    font-weight: 600;
}
CSS

cat > "$CUSTOM_JS" <<'JS'
document.addEventListener("DOMContentLoaded", function() {
    if (!document.querySelector(".kahfi-security-badge")) {
        const badge = document.createElement("div");
        badge.className = "kahfi-security-badge";
        badge.textContent = "Protected by kahfimoodtzyy";
        document.body.appendChild(badge);
    }
});
JS

LAYOUT_FILE="resources/views/layouts/admin.blade.php"
if [ -f "$LAYOUT_FILE" ]; then
    if ! grep -q "kahfimoodtzyy-theme.css" "$LAYOUT_FILE"; then
        sed -i '/<\/head>/i\    <link rel="stylesheet" href="{{ asset('\''assets/custom/kahfimoodtzyy-theme.css'\'') }}">' "$LAYOUT_FILE"
    fi

    if ! grep -q "kahfimoodtzyy-theme.js" "$LAYOUT_FILE"; then
        sed -i '/<\/body>/i\    <script src="{{ asset('\''assets/custom/kahfimoodtzyy-theme.js'\'') }}"></script>' "$LAYOUT_FILE"
    fi

    print_success "Admin layout theme updated."
else
    print_warning "Admin layout file tidak ditemukan, theme skip."
fi

# ==========================================================
# Final checks.
# ==========================================================
print_status "Checking PHP syntax..."
BAD=0
for f in \
    app/Http/Middleware/KahfiMoodTzyPanelProtect.php \
    app/Providers/AppServiceProvider.php \
    app/Services/Servers/ServerCreationService.php \
    app/Services/Servers/ServerDeletionService.php \
    app/Services/Users/UserCreationService.php \
    app/Services/Users/UserUpdateService.php \
    app/Http/Controllers/Admin/UserController.php
do
    if [ -f "$f" ]; then
        php -l "$f" || BAD=1
    fi
done

if [ "$BAD" = "1" ]; then
    print_error "Ada syntax error. Cek output di atas. File backup ada di $BACKUP_DIR"
    exit 1
fi

if id www-data >/dev/null 2>&1; then
    chown -R www-data:www-data "$PANEL_PATH" 2>/dev/null || true
fi

chmod -R 755 "$CUSTOM_DIR" 2>/dev/null || true

print_status "Clearing cache..."
php artisan optimize:clear || true
php artisan config:clear || true
php artisan route:clear || true
php artisan view:clear || true
php artisan cache:clear || true
php artisan queue:restart || true

print_status "Restart service..."
systemctl restart nginx 2>/dev/null || true
for svc in php8.4-fpm php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm; do
    systemctl restart "$svc" 2>/dev/null || true
done

cat <<EOF

============================================================
kahfimoodtzyy FULL PROTECT v12 SELESAI
============================================================

Rules aktif:

Admin utama ID $MAIN_ADMIN_ID:
- full akses semua

Admin selain utama:
- boleh create user biasa
- tidak boleh create user admin/root_admin
- boleh create server lewat panel/PTLA untuk user manapun
- boleh create server untuk akun admin dia sendiri
- tidak boleh create server untuk admin/root_admin lain termasuk admin utama
- dashboard client tidak menampilkan list server
- tidak boleh list/detail/update/delete/delsrv server via PTLA/PTLC
- tidak boleh melihat data server orang lain
- server yang dibuat tetap tidak muncul di list dashboard admin, sesuai protect list server
- boleh create PTLA/PTLC
- tidak boleh revoke/delete API key
- tidak boleh buka Nodes/Nests/Settings

User biasa:
- tidak boleh create PTLC
- tetap bisa backup/download/file manager server sendiri sesuai permission

Theme:
- badge admin tetap: Protected by kahfimoodtzyy

Backup:
$BACKUP_DIR

Test:
1. Admin selain utama create user biasa: harus bisa.
2. Admin selain utama create admin/root_admin: harus gagal.
3. Admin selain utama create server untuk user biasa mana pun via panel/PTLA: harus bisa.
4. Admin selain utama create server untuk akun admin dia sendiri: harus bisa.
5. Admin selain utama create server untuk admin/root_admin lain termasuk admin utama: harus 403.
6. Admin selain utama list server via bot/PTLA: harus 403.
5. Admin selain utama delsrv/delete via bot/PTLA: harus 403.
6. Dashboard admin selain utama: list server kosong/tidak tampil.
7. User biasa backup/download file server sendiri: tetap bisa.

============================================================
EOF
