#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# kahfimoodtzyy Full Protect + Same Admin Theme v5
# Base konsep dari bash.sh user, tapi dibuat lebih aman:
# - Tidak rewrite controller besar-besaran.
# - Tidak merusak FileController/BackupController.
# - Backup/download file tetap jalan untuk owner/subuser masing-masing.
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

print_status "Starting kahfimoodtzyy Full Protect installation..."
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
backup_file "app/Services/Servers/ServerCreationService.php" "ServerCreationService"
backup_file "app/Services/Servers/ServerDeletionService.php" "ServerDeletionService"
backup_file "app/Services/Users/UserCreationService.php" "UserCreationService"
backup_file "app/Services/Users/UserUpdateService.php" "UserUpdateService"
backup_file "app/Http/Controllers/Admin/UserController.php" "UserController"
backup_file "resources/views/layouts/admin.blade.php" "admin_layout"

# Simpan admin utama di .env
if grep -q '^KAHFI_MAIN_ADMIN_ID=' .env 2>/dev/null; then
    sed -i "s/^KAHFI_MAIN_ADMIN_ID=.*/KAHFI_MAIN_ADMIN_ID=${MAIN_ADMIN_ID}/" .env
else
    printf '\nKAHFI_MAIN_ADMIN_ID=%s\n' "$MAIN_ADMIN_ID" >> .env
fi

# ==========================================================
# Middleware utama: protect route tanpa rewrite controller file-manager.
# ==========================================================
mkdir -p app/Http/Middleware
cat > app/Http/Middleware/KahfiMoodTzyPanelProtect.php <<'PHP'
<?php

namespace Pterodactyl\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Log;
use Pterodactyl\Models\Server;
use Symfony\Component\HttpFoundation\Response;

class KahfiMoodTzyPanelProtect
{
    public function handle(Request $request, Closure $next): Response
    {
        $user = $request->user();
        $path = trim($request->path(), '/');
        $mainAdminId = (int) env('KAHFI_MAIN_ADMIN_ID', 1);

        /*
         * Guard paling penting untuk PTLA/Application API.
         * Beberapa route Application API tidak selalu membawa session user biasa,
         * jadi owner PTLA dibaca langsung dari token api_keys.
         * Hasilnya: admin selain utama tetap bisa pakai PTLA, tapi tidak bisa
         * membuat/mengubah user menjadi root_admin lewat PTLA.
         */
        if ($this->isApplicationUserAdminWrite($request, $path)) {
            $actingUserId = $this->actingUserId($request);

            if ((int) $actingUserId !== $mainAdminId) {
                return $this->deny($request, 'PTLA admin selain utama tidak boleh membuat atau mengubah user menjadi admin/root_admin.');
            }
        }

        /*
         * Guard Application API server untuk bot/PTLA:
         * - Admin utama boleh list/detail/delete/update semua server.
         * - Admin selain utama boleh create server saja, dan owner wajib user biasa/non-admin.
         * - Admin selain utama tidak boleh list/detail/delete/update server lewat bot/PTLA.
         */
        $applicationServerBlock = $this->applicationServerGuard($request, $path);
        if ($applicationServerBlock instanceof Response) {
            return $applicationServerBlock;
        }

        if (!$user) {
            return $next($request);
        }

        /*
         * User biasa:
         * - tetap bisa server/file/backup/download miliknya sesuai permission Pterodactyl.
         * - tidak boleh create PTLC/client API key.
         */
        if (!$user->root_admin) {
            if ($this->isPtlcCreate($request, $path)) {
                return $this->deny($request, 'User biasa tidak boleh membuat PTLC/API key.');
            }

            return $next($request);
        }

        /* Admin utama full akses. */
        if ((int) $user->id === $mainAdminId) {
            return $next($request);
        }

        /*
         * Admin lain/root_admin selain admin utama:
         * - boleh create PTLA/PTLC.
         * - tidak boleh revoke/delete API key.
         */
        if ($this->isApiKeyDelete($request, $path)) {
            return $this->deny($request, 'Hanya admin utama yang boleh revoke/delete API key.');
        }

        /* Admin lain boleh create user, tapi tidak boleh create admin/root_admin. */
        if ($this->isUserCreateRequest($request, $path)) {
            if ($this->truthy($request->input('root_admin')) || $this->truthy($request->input('admin'))) {
                return $this->deny($request, 'Admin selain utama tidak boleh membuat admin/root_admin. Buat user biasa saja.');
            }
        }

        if ($this->isUserPrivilegeUpdate($request, $path)) {
            if ($request->has('root_admin') || $request->has('admin')) {
                return $this->deny($request, 'Admin selain utama tidak boleh mengubah privilege admin.');
            }
        }

        /*
         * Admin lain boleh create server, tapi owner wajib user biasa/non-admin.
         * Owner tidak dipaksa ke akun admin agar server tidak nongol di dashboard admin selain utama.
         */
        if ($this->isAdminServerCreate($request, $path)) {
            $ownerId = $this->requestedServerOwnerId($request);

            if (!$ownerId) {
                return $this->deny($request, 'Admin selain utama wajib memilih owner user biasa saat create server.');
            }

            if ($this->isRootAdminUserId($ownerId)) {
                return $this->deny($request, 'Admin selain utama tidak boleh create server untuk akun admin/root_admin. Pilih user biasa.');
            }
        }

        /* Area sensitif full khusus admin utama. */
        $adminBlock = $this->blockedAdminArea($request, $path);
        if ($adminBlock instanceof Response) {
            return $adminBlock;
        }

        /* Admin lain hanya boleh akses server miliknya sendiri. */
        $server = $this->serverFromRequest($request, $path);
        if ($server instanceof Server && (int) $server->owner_id !== (int) $user->id) {
            return $this->deny($request, 'Admin selain utama hanya boleh mengakses server miliknya sendiri.');
        }

        /* Filter dashboard client agar admin lain tidak lihat semua server. */
        if ($this->isClientServerList($request, $path)) {
            $response = $next($request);
            return $this->filterClientServerList($request, $response);
        }

        return $next($request);
    }

    private function blockedAdminArea(Request $request, string $path): ?Response
    {
        /*
         * Dilarang total untuk admin selain utama.
         * PTLA admin/api sengaja TIDAK diblok karena user minta admin lain bisa create PTLA.
         */
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

        /* User detail/edit/delete dilarang, create user biasa tetap boleh. */
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

        /*
         * List semua server tidak ditampilkan untuk admin selain utama.
         * Tapi supaya admin lain tetap bisa CREATE SERVER, /admin/servers diarahkan ke /admin/servers/new.
         */
        if (($path === 'admin/servers' || $path === 'admin/servers/') && $request->isMethod('GET')) {
            return redirect('/admin/servers/new');
        }

        /*
         * Nodes dan Nests wajib terprotect untuk admin selain utama.
         * Direct page /admin/nodes dan /admin/nests kena 403.
         * AJAX/JSON read tetap dibolehkan supaya form create server tidak rusak saat load data egg/node.
         */
        foreach (['admin/nodes', 'admin/nests'] as $prefix) {
            if ($this->starts($path, $prefix)) {
                if ($this->isSafeCreateServerSupportRead($request, $path)) {
                    return null;
                }

                return $this->deny($request, 'Nodes dan Nests hanya boleh diakses admin utama.');
            }
        }

        /* Global panel data lain: GET masih dibolehkan agar form create server tidak rusak, write dilarang. */
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

    private function isSafeCreateServerSupportRead(Request $request, string $path): bool
    {
        if (!$request->isMethod('GET')) {
            return false;
        }

        /*
         * Ini hanya untuk request data pendukung create server, bukan membuka halaman Nodes/Nests.
         * Browser page biasa tidak pakai ajax/JSON, jadi tetap 403 saat klik menu Nodes/Nests.
         */
        if ($request->ajax() || $request->expectsJson()) {
            return true;
        }

        return false;
    }

    private function applicationServerGuard(Request $request, string $path): ?Response
    {
        if (!$this->starts($path, 'api/application/servers')) {
            return null;
        }

        $mainAdminId = (int) env('KAHFI_MAIN_ADMIN_ID', 1);
        $actingUserId = $this->actingUserId($request);

        if ((int) $actingUserId === $mainAdminId) {
            return null;
        }

        $method = strtoupper($request->method());
        $isCreate = $method === 'POST' && ($path === 'api/application/servers' || $path === 'api/application/servers/');

        if ($isCreate) {
            $ownerId = $this->requestedServerOwnerId($request);

            if (!$ownerId) {
                return $this->deny($request, 'PTLA admin selain utama wajib create server untuk owner user biasa.');
            }

            if ($this->isRootAdminUserId($ownerId)) {
                return $this->deny($request, 'PTLA admin selain utama tidak boleh create server untuk akun admin/root_admin.');
            }

            return null;
        }

        return $this->deny($request, 'List/detail/delete/update server lewat PTLA hanya untuk admin utama.');
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

    private function isRootAdminUserId(int $userId): bool
    {
        try {
            $row = \Illuminate\Support\Facades\DB::table('users')->where('id', $userId)->first();
            return $row ? (bool) $row->root_admin : false;
        } catch (\Throwable $e) {
            return true;
        }
    }

    private function isApplicationUserAdminWrite(Request $request, string $path): bool
    {
        /*
         * Protect create/update user dari PTLA:
         * - POST /api/application/users
         * - PATCH/PUT /api/application/users/{id}
         *
         * Kalau request membawa root_admin/admin=true, hanya PTLA milik admin utama yang boleh.
         */
        if (!in_array(strtoupper($request->method()), ['POST', 'PUT', 'PATCH'], true)) {
            return false;
        }

        if (!$this->starts($path, 'api/application/users')) {
            return false;
        }

        return $this->truthy($request->input('root_admin'))
            || $this->truthy($request->input('admin'));
    }

    private function actingUserId(Request $request): ?int
    {
        $user = $request->user();

        if ($user && isset($user->id)) {
            return (int) $user->id;
        }

        try {
            $authUser = \Illuminate\Support\Facades\Auth::user();
            if ($authUser && isset($authUser->id)) {
                return (int) $authUser->id;
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
            return null;
        }

        /*
         * Format PTLA biasanya: ptla_<identifier><secret>
         * identifier disimpan di table api_keys. Panjang identifier umum 16 char.
         * Untuk jaga-jaga dicoba beberapa panjang.
         */
        $raw = preg_replace('/^ptla_/i', '', $token);
        $candidates = [];

        foreach ([16, 32, 24, 8] as $len) {
            if (strlen($raw) >= $len) {
                $candidates[] = substr($raw, 0, $len);
            }
        }

        if (preg_match('/^(ptla_[A-Za-z0-9]+)/', $token, $m)) {
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

    private function filterClientServerList(Request $request, Response $response): Response
    {
        if ($response->getStatusCode() !== 200 || !method_exists($response, 'getContent')) {
            return $response;
        }

        $payload = json_decode($response->getContent(), true);
        if (!is_array($payload) || !isset($payload['data']) || !is_array($payload['data'])) {
            return $response;
        }

        $user = $request->user();
        $filtered = [];

        /* Admin selain utama tidak perlu melihat list server di dashboard client. */
        if ($user && !empty($user->root_admin) && (int) $user->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            $payload['data'] = [];
            if (isset($payload['meta']['pagination']) && is_array($payload['meta']['pagination'])) {
                $payload['meta']['pagination']['total'] = 0;
                $payload['meta']['pagination']['count'] = 0;
                $payload['meta']['pagination']['per_page'] = 1;
                $payload['meta']['pagination']['current_page'] = 1;
                $payload['meta']['pagination']['total_pages'] = 1;
            }
            return response()->json($payload, 200);
        }

        foreach ($payload['data'] as $item) {
            $attr = $item['attributes'] ?? [];
            $identifier = $attr['identifier'] ?? $attr['uuidShort'] ?? $attr['uuid_short'] ?? $attr['uuid'] ?? null;

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

    private function truthy($value): bool
    {
        if (is_bool($value)) {
            return $value;
        }

        if (is_numeric($value)) {
            return (int) $value === 1;
        }

        return in_array(strtolower((string) $value), ['1', 'true', 'on', 'yes', 'admin', 'root'], true);
    }

    private function starts(string $path, string $prefix): bool
    {
        return $path === $prefix || str_starts_with($path, rtrim($prefix, '/') . '/');
    }

    private function deny(Request $request, string $message): Response
    {
        $path = trim($request->path(), '/');

        Log::warning('kahfimoodtzyy protect denied request', [
            'user_id' => optional($request->user())->id,
            'path' => $path,
            'method' => $request->method(),
            'message' => $message,
        ]);

        if ($request->expectsJson() || $request->ajax() || str_starts_with($path, 'api/')) {
            return response()->json([
                'errors' => [[
                    'code' => 'KahfiMoodTzyProtectedAccess',
                    'status' => '403',
                    'detail' => $message,
                ]],
            ], 403);
        }

        abort(403, $message);
    }
}
PHP

print_success "Middleware protect dibuat."

# ==========================================================
# Inject middleware ke AppServiceProvider.
# ==========================================================
php <<'PHP_PATCH'
<?php
$file = 'app/Providers/AppServiceProvider.php';
$marker = 'KAHFIMOODTZYY_PANEL_PROTECT_BOOT';

if (!is_file($file)) {
    fwrite(STDERR, "AppServiceProvider.php tidak ditemukan\n");
    exit(1);
}

$s = file_get_contents($file);
if (strpos($s, $marker) !== false) {
    echo "AppServiceProvider sudah pernah dipatch.\n";
    exit(0);
}

$inject = <<<CODE

        // {$marker}
        \$this->app['router']->pushMiddlewareToGroup('web', \\Pterodactyl\\Http\\Middleware\\KahfiMoodTzyPanelProtect::class);
        \$this->app['router']->pushMiddlewareToGroup('api', \\Pterodactyl\\Http\\Middleware\\KahfiMoodTzyPanelProtect::class);
CODE;

if (preg_match('/public\s+function\s+boot\s*\([^)]*\)\s*(?::\s*void\s*)?\{/m', $s, $m, PREG_OFFSET_CAPTURE)) {
    $pos = $m[0][1] + strlen($m[0][0]);
    $s = substr($s, 0, $pos) . $inject . substr($s, $pos);
} else {
    $pos = strrpos($s, "\n}");
    if ($pos === false) {
        fwrite(STDERR, "Gagal patch AppServiceProvider.php\n");
        exit(1);
    }

    $method = <<<CODE

    public function boot(): void
    {
        // {$marker}
        \$this->app['router']->pushMiddlewareToGroup('web', \\Pterodactyl\\Http\\Middleware\\KahfiMoodTzyPanelProtect::class);
        \$this->app['router']->pushMiddlewareToGroup('api', \\Pterodactyl\\Http\\Middleware\\KahfiMoodTzyPanelProtect::class);
    }

CODE;
    $s = substr($s, 0, $pos) . $method . substr($s, $pos);
}

file_put_contents($file, $s);
echo "AppServiceProvider berhasil dipatch.\n";
PHP_PATCH

# ==========================================================
# Service-level guard supaya bot/API tetap aman.
# ==========================================================

# Hapus/ubah guard lama v4 jika script sebelumnya sudah pernah dipasang.
php <<'PHP_PATCH'
<?php
$file = 'app/Services/Servers/ServerCreationService.php';
if (is_file($file)) {
    $s = file_get_contents($file);
    $old = <<<'OLD'
        if ($kahfiAuthUser && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            if (isset($data) && is_array($data)) {
                $data['owner_id'] = (int) $kahfiAuthUser->id;
                $data['user_id'] = (int) $kahfiAuthUser->id;
            }
        }
OLD;
    $new = <<<'NEW'
        if ($kahfiAuthUser && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            if (isset($data) && is_array($data)) {
                $kahfiOwnerId = $data['owner_id'] ?? $data['user_id'] ?? $data['user'] ?? null;

                if (!$kahfiOwnerId || !is_numeric($kahfiOwnerId)) {
                    throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama wajib create server untuk owner user biasa.');
                }

                try {
                    $kahfiOwner = \Pterodactyl\Models\User::query()->find((int) $kahfiOwnerId);
                } catch (\Throwable $e) {
                    $kahfiOwner = null;
                }

                if (!$kahfiOwner) {
                    throw new \Pterodactyl\Exceptions\DisplayException('Owner user tidak ditemukan.');
                }

                if (!empty($kahfiOwner->root_admin)) {
                    throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh create server untuk akun admin/root_admin. Pilih user biasa.');
                }
            }
        }
NEW;
    if (strpos($s, 'kahfimoodtzyy server owner force guard') !== false && strpos($s, $old) !== false) {
        $s = str_replace($old, $new, $s);
        $s = str_replace('kahfimoodtzyy server owner force guard', 'kahfimoodtzyy server owner non admin guard v5', $s);
        file_put_contents($file, $s);
        echo "Updated old v4 ServerCreationService owner force guard to v5.\n";
    }
}
PHP_PATCH


php <<'PHP_PATCH'
<?php
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
        echo "WARNING handle not found: {$file}\n";
        return;
    }

    $pos = $m[0][1] + strlen($m[0][0]);
    $s = substr($s, 0, $pos) . "\n" . rtrim($guard) . "\n" . substr($s, $pos);
    file_put_contents($file, $s);
    echo "Patched: {$file}\n";
}

kahfi_patch_handle_guard(
    'app/Services/Servers/ServerCreationService.php',
    'kahfimoodtzyy server owner non admin guard v5',
    <<<'GUARD'
        // kahfimoodtzyy server owner non admin guard v5
        // Admin selain utama boleh create server, tapi owner wajib user biasa/non-admin.
        // Owner tidak dipaksa ke akun admin supaya server tidak muncul di dashboard admin selain utama.
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }

        if ($kahfiAuthUser && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            if (isset($data) && is_array($data)) {
                $kahfiOwnerId = $data['owner_id'] ?? $data['user_id'] ?? $data['user'] ?? null;

                if (!$kahfiOwnerId || !is_numeric($kahfiOwnerId)) {
                    throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama wajib create server untuk owner user biasa.');
                }

                try {
                    $kahfiOwner = \Pterodactyl\Models\User::query()->find((int) $kahfiOwnerId);
                } catch (\Throwable $e) {
                    $kahfiOwner = null;
                }

                if (!$kahfiOwner) {
                    throw new \Pterodactyl\Exceptions\DisplayException('Owner user tidak ditemukan.');
                }

                if (!empty($kahfiOwner->root_admin)) {
                    throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh create server untuk akun admin/root_admin. Pilih user biasa.');
                }
            }
        }
GUARD
);

kahfi_patch_handle_guard(
    'app/Services/Users/UserCreationService.php',
    'kahfimoodtzyy user admin hard error guard v4',
    <<<'GUARD'
        // kahfimoodtzyy user admin hard error guard v4
        // Ini guard paling atas di UserCreationService.
        // Tujuan: kalau admin selain utama atau PTLA milik admin selain utama mencoba create admin/root_admin,
        // request langsung error. Tidak dipaksa jadi user biasa lagi.
        $kahfiMainAdminId = (int) env('KAHFI_MAIN_ADMIN_ID', 1);
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }

        $kahfiActorId = $kahfiAuthUser && isset($kahfiAuthUser->id) ? (int) $kahfiAuthUser->id : null;
        if (!$kahfiActorId) {
            try {
                $kahfiToken = (string) request()->bearerToken();
                if ($kahfiToken === '') {
                    $kahfiHeader = (string) request()->header('Authorization', '');
                    if (preg_match('/Bearer\s+(.+)/i', $kahfiHeader, $kahfiMatch)) {
                        $kahfiToken = trim($kahfiMatch[1]);
                    }
                }

                // Coba ambil owner PTLA/PTLC dari tabel api_keys berdasarkan identifier token.
                $kahfiRaw = preg_replace('/^(ptla_|ptlc_)/i', '', $kahfiToken);
                $kahfiCandidates = [];
                foreach ([16, 32, 24, 8] as $kahfiLen) {
                    if (strlen($kahfiRaw) >= $kahfiLen) {
                        $kahfiCandidates[] = substr($kahfiRaw, 0, $kahfiLen);
                    }
                }
                if (preg_match('/^((?:ptla|ptlc)_[A-Za-z0-9]+)/', $kahfiToken, $kahfiMatch2)) {
                    $kahfiCandidates[] = $kahfiMatch2[1];
                }
                $kahfiCandidates = array_values(array_unique(array_filter($kahfiCandidates)));

                foreach ($kahfiCandidates as $kahfiIdentifier) {
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

        $kahfiRootRequested = false;
        if (isset($data) && is_array($data)) {
            foreach (['root_admin', 'admin', 'is_admin'] as $kahfiKey) {
                if (array_key_exists($kahfiKey, $data) && filter_var($data[$kahfiKey], FILTER_VALIDATE_BOOLEAN)) {
                    $kahfiRootRequested = true;
                    break;
                }
            }
        }

        $kahfiPath = '';
        try { $kahfiPath = trim(request()->path(), '/'); } catch (\Throwable $e) { $kahfiPath = ''; }

        // Untuk jalur web admin: kalau admin selain utama mencentang root_admin, langsung error.
        if ($kahfiRootRequested && $kahfiAuthUser && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== $kahfiMainAdminId) {
            throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh membuat user admin/root_admin.');
        }

        // Untuk jalur PTLA/Application API: hanya PTLA milik admin utama yang boleh create root_admin.
        // Jika owner PTLA tidak terbaca, tetap ditolak supaya tidak bisa bypass lewat bot.
        if ($kahfiRootRequested && str_starts_with($kahfiPath, 'api/application/users') && (int) $kahfiActorId !== $kahfiMainAdminId) {
            throw new \Pterodactyl\Exceptions\DisplayException('PTLA admin selain utama tidak boleh membuat user admin/root_admin.');
        }
GUARD
);
kahfi_patch_handle_guard(
    'app/Services/Users/UserUpdateService.php',
    'kahfimoodtzyy block admin privilege update guard',
    <<<'GUARD'
        // kahfimoodtzyy block admin privilege update guard
        $kahfiMainAdminId = (int) env('KAHFI_MAIN_ADMIN_ID', 1);
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }

        $kahfiActorId = $kahfiAuthUser && isset($kahfiAuthUser->id) ? (int) $kahfiAuthUser->id : null;
        if (!$kahfiActorId) {
            try {
                $kahfiToken = (string) request()->bearerToken();
                if ($kahfiToken === '') {
                    $kahfiHeader = (string) request()->header('Authorization', '');
                    if (preg_match('/Bearer\s+(.+)/i', $kahfiHeader, $kahfiMatch)) {
                        $kahfiToken = trim($kahfiMatch[1]);
                    }
                }
                $kahfiRaw = preg_replace('/^ptla_/i', '', $kahfiToken);
                foreach ([16, 32, 24, 8] as $kahfiLen) {
                    if (strlen($kahfiRaw) >= $kahfiLen) {
                        $kahfiIdentifier = substr($kahfiRaw, 0, $kahfiLen);
                        $kahfiRow = \Illuminate\Support\Facades\DB::table('api_keys')->where('identifier', $kahfiIdentifier)->first();
                        if ($kahfiRow && isset($kahfiRow->user_id)) {
                            $kahfiActorId = (int) $kahfiRow->user_id;
                            break;
                        }
                    }
                }
            } catch (\Throwable $e) {
                $kahfiActorId = null;
            }
        }

        $kahfiPath = '';
        try { $kahfiPath = trim(request()->path(), '/'); } catch (\Throwable $e) { $kahfiPath = ''; }

        $kahfiRootTouched = isset($data) && is_array($data) && array_key_exists('root_admin', $data);

        if (
            $kahfiRootTouched
            && (
                ($kahfiAuthUser && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== $kahfiMainAdminId)
                || (str_starts_with($kahfiPath, 'api/application/users') && (int) $kahfiActorId !== $kahfiMainAdminId)
            )
        ) {
            throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh mengubah privilege admin, termasuk lewat PTLA.');
        }

        if ($kahfiAuthUser && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== $kahfiMainAdminId) {
            if (isset($user) && is_object($user) && !empty($user->root_admin)) {
                throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh edit akun admin.');
            }
        }
GUARD
);
PHP_PATCH

# ==========================================================
# Patch redirect store user supaya admin lain tidak dilempar ke detail user yang diblok.
# ==========================================================
php <<'PHP_PATCH'
<?php
$file = 'app/Http/Controllers/Admin/UserController.php';
if (!is_file($file)) {
    echo "SKIP UserController not found\n";
    exit(0);
}

$s = file_get_contents($file);
$marker = 'kahfimoodtzyy user store redirect patch';
if (strpos($s, $marker) !== false) {
    echo "UserController redirect sudah dipatch.\n";
    exit(0);
}

if (strpos($s, 'use Illuminate\Support\Facades\Auth;') === false) {
    $s = preg_replace('/namespace\s+Pterodactyl\\Http\\Controllers\\Admin;\s*/', "namespace Pterodactyl\\Http\\Controllers\\Admin;\n\nuse Illuminate\\Support\\Facades\\Auth;\n", $s, 1);
}

$replacements = [
    "return redirect()->route('admin.users.view', \$user->id);" => "// {$marker}\n        return ((int) Auth::id() === (int) env('KAHFI_MAIN_ADMIN_ID', 1))\n            ? redirect()->route('admin.users.view', \$user->id)\n            : redirect()->route('admin.users');",
    'return redirect()->route("admin.users.view", $user->id);' => "// {$marker}\n        return ((int) Auth::id() === (int) env('KAHFI_MAIN_ADMIN_ID', 1))\n            ? redirect()->route('admin.users.view', \$user->id)\n            : redirect()->route('admin.users');",
];

$done = false;
foreach ($replacements as $from => $to) {
    if (strpos($s, $from) !== false) {
        $s = str_replace($from, $to, $s);
        $done = true;
        break;
    }
}

if (!$done) {
    echo "WARNING: redirect store user tidak ditemukan, skip.\n";
} else {
    file_put_contents($file, $s);
    echo "UserController redirect berhasil dipatch.\n";
}
PHP_PATCH

# ==========================================================

# ==========================================================
# Block list/detail/delete/update server lewat PTLA untuk admin selain utama.
# Create server tetap boleh untuk user biasa/non-admin.
# ==========================================================
php <<'PHP_PATCH'
<?php
function kahfi_actor_guard_code(): string
{
    return <<<'GUARD'
        // kahfimoodtzyy application server access guard v5
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }
        $kahfiActorId = $kahfiAuthUser && isset($kahfiAuthUser->id) ? (int) $kahfiAuthUser->id : null;
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
                foreach ([16, 32, 24, 8] as $kahfiLen) {
                    if (strlen($kahfiRaw) >= $kahfiLen) {
                        $kahfiCandidates[] = substr($kahfiRaw, 0, $kahfiLen);
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
            } catch (\Throwable $e) { $kahfiActorId = null; }
        }
        if ((int) $kahfiActorId !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            throw new \Pterodactyl\Exceptions\DisplayException('List/detail/delete/update server lewat PTLA hanya untuk admin utama.');
        }
GUARD;
}

function kahfi_patch_named_methods(string $file, array $methods, string $marker, string $guard): void
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

    $regex = implode('|', array_map('preg_quote', $methods));
    $pattern = '/public\s+function\s+(' . $regex . ')\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{/m';
    $count = 0;
    $s2 = preg_replace_callback($pattern, function ($m) use ($guard, &$count) {
        $count++;
        return $m[0] . "\n" . rtrim($guard) . "\n";
    }, $s, -1, $count);

    if ($count > 0 && $s2 !== null) {
        file_put_contents($file, $s2);
        echo "Patched application server guard: {$file} ({$count})\n";
    } else {
        echo "WARNING no target methods found: {$file}\n";
    }
}

$guard = kahfi_actor_guard_code();
$serverControllerCandidates = [
    'app/Http/Controllers/Api/Application/Servers/ServerController.php',
    'app/Http/Controllers/Api/Application/ServerController.php',
];

foreach ($serverControllerCandidates as $file) {
    kahfi_patch_named_methods(
        $file,
        ['index', 'view', 'details', 'build', 'startup', 'database', 'databases', 'delete', 'destroy', 'suspend', 'unsuspend', 'reinstall', 'update', 'updateDetails', 'updateBuild', 'updateStartup'],
        'kahfimoodtzyy application server access guard v5',
        $guard
    );
}

// Service-level delete guard supaya delsrv lewat bot/PTLA tetap tidak tembus.
$file = 'app/Services/Servers/ServerDeletionService.php';
if (is_file($file)) {
    kahfi_patch_named_methods(
        $file,
        ['handle'],
        'kahfimoodtzyy server deletion main admin only guard v5',
        <<<'GUARD'
        // kahfimoodtzyy server deletion main admin only guard v5
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }
        $kahfiActorId = $kahfiAuthUser && isset($kahfiAuthUser->id) ? (int) $kahfiAuthUser->id : null;
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
                foreach ([16, 32, 24, 8] as $kahfiLen) {
                    if (strlen($kahfiRaw) >= $kahfiLen) {
                        $kahfiIdentifier = substr($kahfiRaw, 0, $kahfiLen);
                        $kahfiRow = \Illuminate\Support\Facades\DB::table('api_keys')->where('identifier', $kahfiIdentifier)->first();
                        if ($kahfiRow && isset($kahfiRow->user_id)) {
                            $kahfiActorId = (int) $kahfiRow->user_id;
                            break;
                        }
                    }
                }
            } catch (\Throwable $e) { $kahfiActorId = null; }
        }
        if ((int) $kahfiActorId !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            throw new \Pterodactyl\Exceptions\DisplayException('Delete server hanya untuk admin utama.');
        }
GUARD
    );
}
PHP_PATCH

# API key delete service guard: create PTLA/PTLC tetap boleh, revoke/delete dikunci.
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
    $s2 = preg_replace_callback($pattern, function ($m) use ($guard, &$count) {
        $count++;
        return $m[0] . "\n" . rtrim($guard) . "\n";
    }, $s, -1, $count);

    if ($count > 0 && $s2 !== null) {
        file_put_contents($file, $s2);
        echo "API revoke guard patched {$file} ({$count})\n";
    }
}

$guard = <<<'GUARD'
        // kahfimoodtzyy api key revoke/delete guard
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }
        if ($kahfiAuthUser && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            throw new \Pterodactyl\Exceptions\DisplayException('Hanya admin utama yang boleh revoke/delete API key.');
        }
GUARD;

$candidates = [
    'app/Http/Controllers/Admin/ApiController.php',
    'app/Http/Controllers/Admin/ApiKeyController.php',
    'app/Http/Controllers/Admin/ApiKeysController.php',
    'app/Http/Controllers/Api/Client/Account/ApiKeyController.php',
    'app/Http/Controllers/Api/Client/Account/ApiKeysController.php',
    'app/Http/Controllers/Api/Application/ApiKeyController.php',
    'app/Http/Controllers/Api/Application/ApiKeysController.php',
];

foreach ($candidates as $file) {
    patch_methods_guard($file, ['delete', 'destroy', 'revoke', 'remove'], 'kahfimoodtzyy api key revoke/delete guard', $guard);
}

$serviceBase = 'app/Services';
if (is_dir($serviceBase)) {
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($serviceBase, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $f) {
        if (!$f->isFile()) continue;
        $path = $f->getPathname();
        if (preg_match('/(KeyDeletionService|ApiKeyDeletionService|ApplicationApiKeyDeletionService|ClientApiKeyDeletionService)\.php$/i', basename($path))) {
            patch_methods_guard($path, ['handle', 'delete', 'destroy', 'revoke', 'remove'], 'kahfimoodtzyy api key revoke/delete guard', $guard);
        }
    }
}
PHP_PATCH

# ==========================================================
# Theme/admin look: tetap ada nama kahfimoodtzyy.
# ==========================================================
print_status "Installing same admin theme with kahfimoodtzyy name..."
CUSTOM_DIR="$PANEL_PATH/public/assets/custom"
mkdir -p "$CUSTOM_DIR"

cat > "$CUSTOM_DIR/kahfimoodtzyy-theme.css" <<'CSS'
@import url("https://fonts.googleapis.com/css2?family=Poppins:wght@300;400;500;600;700;800&display=swap");

.security-welcome,
.security-badge,
.alert-danger.jm-admin-alert,
.navbar-brand {
    font-family: "Poppins", "Segoe UI", Roboto, sans-serif;
}

.security-welcome {
    text-align: center;
    padding: 2rem 1.5rem 1.8rem;
    margin: 2rem auto;
    max-width: 480px;
    background: rgba(255, 255, 255, 0.92);
    border-radius: 12px;
    backdrop-filter: blur(10px);
    border: 1px solid rgba(0, 0, 0, 0.08);
    box-shadow: 0 6px 20px rgba(0, 0, 0, 0.12);
}
.security-welcome h3 {
    font-weight: 600;
    font-size: 1.4rem;
    color: #1a73e8;
    margin: 0 0 .5rem;
}
.security-welcome p {
    margin: 0;
    font-size: .95rem;
    color: #5f6368;
}

.security-badge {
    position: fixed;
    top: 20px;
    right: 20px;
    background: linear-gradient(135deg, #ea4335, #b71c1c);
    color: #fff;
    padding: 8px 16px;
    border-radius: 20px;
    font-size: 13px;
    font-weight: 600;
    z-index: 9999;
    animation: kahfiPulse 2s infinite;
    box-shadow: 0 4px 12px rgba(234, 67, 53, .35);
}
@keyframes kahfiPulse {
    0%, 100% { transform: scale(1); }
    50%      { transform: scale(1.05); }
}
CSS

cat > "$CUSTOM_DIR/kahfimoodtzyy-theme.js" <<'JS'
class KahfiMoodTzyySecurity {
    constructor() { this.init(); }
    init() {
        this.addSecurityBadge();
        this.addWelcomeAnimation();
        this.enhanceUI();
    }
    addSecurityBadge() {
        if (document.querySelector('.security-badge')) return;
        const badge = document.createElement('div');
        badge.className = 'security-badge';
        badge.innerHTML = 'kahfimoodtzyy';
        badge.setAttribute('title', 'kahfimoodtzyy panel protection active');
        document.body.appendChild(badge);
    }
    addWelcomeAnimation() {
        if (!(location.pathname.includes('/admin') || location.pathname.includes('/server'))) return;
        setTimeout(() => {
            if (document.querySelector('.security-welcome')) return;
            const msg = document.createElement('div');
            msg.className = 'security-welcome';
            msg.innerHTML = '<h3>kahfimoodtzyy Protection Active</h3><p>Panel Protection</p>';
            const main = document.querySelector('.content') || document.querySelector('main') || document.body;
            main.prepend(msg);
            setTimeout(() => {
                if (msg.parentNode) {
                    msg.style.opacity = '0';
                    msg.style.transition = 'opacity .5s ease';
                    setTimeout(() => msg.remove(), 500);
                }
            }, 5000);
        }, 1000);
    }
    enhanceUI() {
        document.querySelectorAll('.card').forEach(card => {
            card.style.transition = 'all .3s cubic-bezier(0.4,0,0.2,1)';
            card.addEventListener('mouseenter', () => { card.style.transform = 'translateY(-5px)'; });
            card.addEventListener('mouseleave', () => { card.style.transform = 'translateY(0)'; });
        });
    }
}

document.addEventListener('DOMContentLoaded', () => new KahfiMoodTzyySecurity());
window.KahfiMoodTzyySecurity = KahfiMoodTzyySecurity;
JS

LAYOUT_FILE="$PANEL_PATH/resources/views/layouts/admin.blade.php"
if [ -f "$LAYOUT_FILE" ]; then
    if ! grep -q "kahfimoodtzyy-theme.css" "$LAYOUT_FILE"; then
        sed -i '/<\/head>/i\    <!-- kahfimoodtzyy Security & Theme -->\n    <link rel="stylesheet" href="{{ asset('\''assets/custom/kahfimoodtzyy-theme.css'\'') }}">\n    <link href="https://fonts.googleapis.com/css2?family=Poppins:wght@300;400;500;600;700;800&display=swap" rel="stylesheet">' "$LAYOUT_FILE"
    fi
    if ! grep -q "kahfimoodtzyy-theme.js" "$LAYOUT_FILE"; then
        sed -i '/<\/body>/i\    <!-- kahfimoodtzyy Security Scripts -->\n    <script src="{{ asset('\''assets/custom/kahfimoodtzyy-theme.js'\'') }}"></script>' "$LAYOUT_FILE"
    fi
    print_success "Admin layout theme updated."
else
    print_warning "resources/views/layouts/admin.blade.php tidak ditemukan, theme mungkin tidak tampil."
fi

# ==========================================================
# Final check.
# ==========================================================
print_status "Checking PHP syntax..."
php -l app/Http/Middleware/KahfiMoodTzyPanelProtect.php >/dev/null
php -l app/Providers/AppServiceProvider.php >/dev/null
[ -f app/Services/Servers/ServerCreationService.php ] && php -l app/Services/Servers/ServerCreationService.php >/dev/null || true
[ -f app/Services/Users/UserCreationService.php ] && php -l app/Services/Users/UserCreationService.php >/dev/null || true
[ -f app/Services/Users/UserUpdateService.php ] && php -l app/Services/Users/UserUpdateService.php >/dev/null || true
[ -f app/Http/Controllers/Admin/UserController.php ] && php -l app/Http/Controllers/Admin/UserController.php >/dev/null || true

print_status "Clearing cache and restarting services..."
chown -R www-data:www-data "$PANEL_PATH" 2>/dev/null || true
chmod -R 755 "$PANEL_PATH/public/assets/custom" 2>/dev/null || true
php artisan optimize:clear || true
php artisan config:clear || true
php artisan route:clear || true
php artisan view:clear || true
php artisan cache:clear || true
php artisan queue:restart || true

for svc in php8.4-fpm php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm; do
    systemctl restart "$svc" 2>/dev/null || true
done
systemctl restart nginx 2>/dev/null || true

cat <<EOF

==============================================================
KAHFIMOODTZYY FULL PROTECT V5 INSTALLED
==============================================================

Aktif:
- Admin utama ID $MAIN_ADMIN_ID full akses semua.
- Admin lain bisa manage server miliknya sendiri.
- Admin lain bisa create server untuk user biasa/non-admin, owner tidak dipaksa ke admin.
- /admin/servers untuk admin lain diarahkan ke /admin/servers/new.
- Admin lain bisa create user biasa/member.
- Admin lain tidak bisa create admin/root_admin, termasuk lewat PTLA/bot. Jika dicoba, request error.
- Admin lain bisa create PTLA/PTLC.
- Admin lain tidak bisa create admin/root_admin lewat PTLA.
- Admin lain tidak bisa update user jadi admin/root_admin lewat PTLA.
- Admin lain tidak bisa revoke/delete API key.
- User biasa tidak bisa create PTLC.
- User biasa tetap bisa backup/download/file manager sesuai permission server masing-masing.
- Admin lain tidak bisa akses server orang lain dan dashboard client tidak menampilkan list server.
- Admin lain tidak bisa buka Nodes dan Nests.
- Tampilan admin tetap ada badge/nama: kahfimoodtzyy.

Backup file sebelum patch ada di:
$BACKUP_DIR

Test wajib:
1. Admin utama: buka semua server, create PTLA/PTLC, semua harus bisa.
2. Admin lain: create server harus bisa, server owner harus admin itu sendiri.
3. Admin lain: dashboard client tidak menampilkan list server; server yang dibuat harus owner user biasa.
4. Admin lain: list/detail/delete server lewat bot/PTLA harus 403.
5. Admin lain: create user biasa harus bisa, create admin harus gagal/otomatis jadi user biasa.
6. Admin lain: PTLA tidak boleh create/update user menjadi admin/root_admin.
7. User biasa: create PTLC harus gagal.
8. User biasa: backup/download server sendiri harus bisa.

Jika 500, kirim output:
cd $PANEL_PATH && tail -n 120 storage/logs/laravel-*.log

==============================================================
EOF
