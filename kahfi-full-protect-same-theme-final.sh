#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# kahfimoodtzyy Full Protect + Same Admin Theme
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

        if (!$user) {
            return $next($request);
        }

        $path = trim($request->path(), '/');
        $mainAdminId = (int) env('KAHFI_MAIN_ADMIN_ID', 1);

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
                $request->merge(['root_admin' => false, 'admin' => false]);
            }
        }

        if ($this->isUserPrivilegeUpdate($request, $path)) {
            if ($request->has('root_admin') || $request->has('admin')) {
                return $this->deny($request, 'Admin selain utama tidak boleh mengubah privilege admin.');
            }
        }

        /* Admin lain boleh create server, tapi owner server dipaksa ke dirinya sendiri. */
        if ($this->isAdminServerCreate($request, $path)) {
            $request->merge([
                'owner_id' => (int) $user->id,
                'user_id' => (int) $user->id,
            ]);
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

        /* List semua server dilarang, create server tetap boleh lewat /admin/servers/new. */
        if (($path === 'admin/servers' || $path === 'admin/servers/') && $request->isMethod('GET')) {
            return $this->deny($request, 'List semua server hanya untuk admin utama.');
        }

        /* Global panel data: GET masih dibolehkan agar form create server tidak rusak, write dilarang. */
        $globalWriteOnly = [
            'admin/nodes',
            'admin/locations',
            'admin/nests',
            'admin/databases',
        ];

        foreach ($globalWriteOnly as $prefix) {
            if ($this->starts($path, $prefix) && !$request->isMethod('GET')) {
                return $this->deny($request, 'Admin selain utama tidak boleh mengubah data global panel.');
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
    'kahfimoodtzyy server owner force guard',
    <<<'GUARD'
        // kahfimoodtzyy server owner force guard
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
GUARD
);

kahfi_patch_handle_guard(
    'app/Services/Users/UserCreationService.php',
    'kahfimoodtzyy user no admin guard',
    <<<'GUARD'
        // kahfimoodtzyy user no admin guard
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser) {
            try { $kahfiAuthUser = request()->user(); } catch (\Throwable $e) { $kahfiAuthUser = null; }
        }
        if ($kahfiAuthUser && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== (int) env('KAHFI_MAIN_ADMIN_ID', 1)) {
            if (isset($data) && is_array($data)) {
                $data['root_admin'] = false;
            }
        }
GUARD
);

kahfi_patch_handle_guard(
    'app/Services/Users/UserUpdateService.php',
    'kahfimoodtzyy block admin privilege update guard',
    <<<'GUARD'
        // kahfimoodtzyy block admin privilege update guard
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
KAHFIMOODTZYY FULL PROTECT INSTALLED
==============================================================

Aktif:
- Admin utama ID $MAIN_ADMIN_ID full akses semua.
- Admin lain bisa manage server miliknya sendiri.
- Admin lain bisa create server, owner dipaksa ke dirinya sendiri.
- Admin lain bisa create user biasa/member.
- Admin lain tidak bisa create admin/root_admin.
- Admin lain bisa create PTLA/PTLC.
- Admin lain tidak bisa revoke/delete API key.
- User biasa tidak bisa create PTLC.
- User biasa tetap bisa backup/download/file manager sesuai permission server masing-masing.
- Admin lain tidak bisa akses server orang lain.
- Tampilan admin tetap ada badge/nama: kahfimoodtzyy.

Backup file sebelum patch ada di:
$BACKUP_DIR

Test wajib:
1. Admin utama: buka semua server, create PTLA/PTLC, semua harus bisa.
2. Admin lain: create server harus bisa, server owner harus admin itu sendiri.
3. Admin lain: server sendiri console/files/backup/download harus bisa.
4. Admin lain: server orang lain harus 403.
5. Admin lain: create user biasa harus bisa, create admin harus gagal/otomatis jadi user biasa.
6. User biasa: create PTLC harus gagal.
7. User biasa: backup/download server sendiri harus bisa.

Jika 500, kirim output:
cd $PANEL_PATH && tail -n 120 storage/logs/laravel-*.log

==============================================================
EOF
