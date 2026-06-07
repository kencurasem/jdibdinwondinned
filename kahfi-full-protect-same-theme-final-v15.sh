#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# kahfimoodtzyy FULL PROTECT v15
#
# FINAL RULE:
# Admin utama:
# - full akses semua.
#
# Admin selain utama:
# - boleh create user biasa.
# - tidak boleh create user admin/root_admin.
# - boleh create server untuk user biasa mana pun.
# - boleh create server untuk akun admin dia sendiri.
# - tidak boleh create server untuk admin/root_admin lain termasuk admin utama.
# - tidak boleh list/detail/update/delete/delsrv server lewat PTLA/PTLC.
# - dashboard/client API hanya menampilkan server owner_id dia sendiri.
# - tidak boleh melihat data server orang lain.
# - boleh create PTLA/PTLC.
# - tidak boleh revoke/delete API key.
# - Nodes/Nests/Settings khusus admin utama.
#
# User biasa:
# - tidak boleh create PTLC.
# - tetap bisa backup/download/file manager server sendiri sesuai permission.
#
# Install:
# MAIN_ADMIN_ID=1 bash kahfi-full-protect-same-theme-final-v15.sh
# MAIN_ADMIN_ID=1 bash kahfi-full-protect-same-theme-final-v15.sh /var/www/pterodactyl
# ==========================================================

MAIN_ADMIN_ID="${MAIN_ADMIN_ID:-1}"
PANEL_PATH="${1:-/var/www/pterodactyl}"
BACKUP_DIR="/root/pterodactyl_backups"
TIMESTAMP="$(date -u +"%Y-%m-%d-%H-%M-%S")"

info(){ echo "[INFO] $1"; }
ok(){ echo "[OK] $1"; }
warn(){ echo "[WARN] $1"; }
err(){ echo "[ERROR] $1"; }
fail(){ err "$1"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Jalankan sebagai root di VPS panel."
[ -f "$PANEL_PATH/artisan" ] || fail "Folder panel salah atau artisan tidak ketemu: $PANEL_PATH"
command -v python3 >/dev/null 2>&1 || fail "python3 tidak ada. Install dulu: apt install -y python3"

mkdir -p "$BACKUP_DIR"
cd "$PANEL_PATH"

info "Starting kahfimoodtzyy FULL PROTECT v15"
info "Panel: $PANEL_PATH"
info "Main admin ID: $MAIN_ADMIN_ID"
info "Backup: $BACKUP_DIR"

backup_file(){
    local file_path="$1"
    local backup_name="$2"
    if [ -f "$file_path" ]; then
        cp -a "$file_path" "$BACKUP_DIR/${backup_name}_${TIMESTAMP}.bak"
        info "Backed up: $backup_name"
    fi
}

backup_file ".env" "env"
backup_file "app/Providers/AppServiceProvider.php" "AppServiceProvider"
backup_file "app/Http/Kernel.php" "Kernel"
backup_file "app/Services/Servers/ServerCreationService.php" "ServerCreationService"
backup_file "app/Services/Servers/ServerDeletionService.php" "ServerDeletionService"
backup_file "app/Services/Users/UserCreationService.php" "UserCreationService"
backup_file "app/Services/Users/UserUpdateService.php" "UserUpdateService"
backup_file "resources/views/layouts/admin.blade.php" "admin_layout"

if grep -q '^KAHFI_MAIN_ADMIN_ID=' .env 2>/dev/null; then
    sed -i "s/^KAHFI_MAIN_ADMIN_ID=.*/KAHFI_MAIN_ADMIN_ID=${MAIN_ADMIN_ID}/" .env
else
    printf '\nKAHFI_MAIN_ADMIN_ID=%s\n' "$MAIN_ADMIN_ID" >> .env
fi

# Hapus middleware lama yang bentrok.
rm -f app/Http/Middleware/KahfiFullAdminProtect.php
rm -f app/Http/Middleware/KahfiAdminOwnServerAccess.php
rm -f app/Http/Middleware/KahfiPanelFullProtect.php

mkdir -p app/Http/Middleware

cat > app/Http/Middleware/KahfiMoodTzyPanelProtect.php <<'PHP_MIDDLEWARE'
<?php

namespace Pterodactyl\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\User;
use Symfony\Component\HttpFoundation\Response;

class KahfiMoodTzyPanelProtect
{
    public function handle(Request $request, Closure $next): Response
    {
        $path = trim($request->path(), '/');
        $method = strtoupper($request->method());
        $mainAdminId = (int) env('KAHFI_MAIN_ADMIN_ID', 1);

        if ($this->starts($path, 'api/application/servers')) {
            $actorId = $this->actingUserId($request);
            $isMain = $actorId !== null && (int) $actorId === $mainAdminId;
            $isCreate = $method === 'POST' && ($path === 'api/application/servers' || $path === 'api/application/servers/');

            if (!$isMain) {
                if ($isCreate) {
                    $ownerId = $this->requestedServerOwnerId($request);

                    if (!$ownerId) {
                        return $this->deny($request, 'Create server wajib memilih owner.');
                    }

                    if ($this->isRootAdminUserId($ownerId) && (int) $ownerId !== (int) $actorId) {
                        return $this->deny($request, 'Admin selain utama tidak boleh create server untuk admin/root_admin lain termasuk admin utama.');
                    }

                    return $next($request);
                }

                return $this->deny($request, 'List/detail/update/delete/delsrv server lewat PTLA hanya untuk admin utama.');
            }
        }

        if ($this->starts($path, 'api/application/users') && in_array($method, ['POST', 'PUT', 'PATCH'], true)) {
            $actorId = $this->actingUserId($request);
            $isMain = $actorId !== null && (int) $actorId === $mainAdminId;

            if (!$isMain && $this->requestTouchesAdminFlag($request)) {
                return $this->deny($request, 'Admin selain utama tidak boleh create/edit user admin/root_admin lewat PTLA.');
            }
        }

        $user = $request->user();

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

        if ($this->isApiKeyDelete($request, $path)) {
            return $this->deny($request, 'Hanya admin utama yang boleh revoke/delete API key.');
        }

        if ($this->isUserCreateRequest($request, $path) && $this->requestTouchesAdminFlag($request)) {
            return $this->deny($request, 'Admin selain utama tidak boleh membuat user admin/root_admin.');
        }

        if ($this->isUserPrivilegeUpdate($request, $path) && ($request->has('root_admin') || $request->has('admin') || $request->has('is_admin'))) {
            return $this->deny($request, 'Admin selain utama tidak boleh mengubah privilege admin.');
        }

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

        if ($this->isClientServerList($request, $path)) {
            $response = $next($request);
            return $this->filterOwnServerListResponse($request, $response);
        }

        $server = $this->serverFromRequest($request, $path);
        if ($server instanceof Server && (int) $server->owner_id !== (int) $user->id) {
            return $this->deny($request, 'Admin selain utama tidak boleh melihat data server orang lain.');
        }

        return $next($request);
    }

    private function blockedAdminArea(Request $request, string $path): ?Response
    {
        foreach (['admin/settings', 'admin/system', 'admin/roles', 'admin/mounts'] as $prefix) {
            if ($this->starts($path, $prefix)) {
                return $this->deny($request, 'Area ini hanya untuk admin utama.');
            }
        }

        foreach (['admin/nodes', 'admin/nests'] as $prefix) {
            if ($this->starts($path, $prefix)) {
                if ($request->isMethod('GET') && ($request->ajax() || $request->expectsJson())) {
                    return null;
                }

                return $this->deny($request, 'Nodes dan Nests hanya boleh diakses admin utama.');
            }
        }

        foreach (['admin/users/view', 'admin/users/edit', 'admin/users/delete', 'admin/users/two-factor'] as $prefix) {
            if ($this->starts($path, $prefix)) {
                return $this->deny($request, 'Admin selain utama tidak boleh membuka detail/edit/delete user.');
            }
        }

        if (($path === 'admin/users' || $path === 'admin/users/') && $request->isMethod('GET')) {
            return redirect('/admin/users/new');
        }

        if (($path === 'admin/servers' || $path === 'admin/servers/') && $request->isMethod('GET')) {
            return redirect('/admin/servers/new');
        }

        foreach (['admin/locations', 'admin/databases'] as $prefix) {
            if ($this->starts($path, $prefix) && !$request->isMethod('GET')) {
                return $this->deny($request, 'Admin selain utama tidak boleh mengubah data global panel.');
            }
        }

        return null;
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

        if ($user instanceof User && isset($user->id)) {
            return (int) $user->id;
        }

        try {
            $authUser = \Illuminate\Support\Facades\Auth::user();
            if ($authUser instanceof User && isset($authUser->id)) {
                return (int) $authUser->id;
            }
        } catch (\Throwable $e) {}

        try {
            foreach ($request->attributes->all() as $value) {
                if (is_object($value) && isset($value->user_id)) return (int) $value->user_id;
                if (is_array($value) && isset($value['user_id'])) return (int) $value['user_id'];
            }
        } catch (\Throwable $e) {}

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

        if ($token === '') return null;

        $raw = preg_replace('/^(ptla_|ptlc_)/i', '', $token);
        $candidates = [];

        foreach ([16, 20, 24, 32, 8] as $len) {
            if (strlen($raw) >= $len) $candidates[] = substr($raw, 0, $len);
        }

        foreach (preg_split('/[._\-]/', $raw) ?: [] as $part) {
            if (strlen($part) >= 8) {
                $candidates[] = $part;
                foreach ([16, 20, 24, 32, 8] as $len) {
                    if (strlen($part) >= $len) $candidates[] = substr($part, 0, $len);
                }
            }
        }

        if (preg_match('/^((?:ptla|ptlc)_[A-Za-z0-9]+)/', $token, $m)) {
            $candidates[] = $m[1];
        }

        foreach (array_values(array_unique(array_filter($candidates))) as $identifier) {
            try {
                $row = \Illuminate\Support\Facades\DB::table('api_keys')->where('identifier', $identifier)->first();
                if ($row && isset($row->user_id)) return (int) $row->user_id;
            } catch (\Throwable $e) {}
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
        if (!in_array(strtoupper($request->method()), ['DELETE', 'POST'], true)) return false;

        $isDeleteAction = $request->isMethod('DELETE')
            || $request->input('_method') === 'DELETE'
            || strtolower((string) $request->input('action')) === 'delete'
            || strtolower((string) $request->input('action')) === 'revoke';

        if (!$isDeleteAction) return false;

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
        if (preg_match('#^api/client/servers/([^/]+)(?:/|$)#', $path, $m)) return $this->findServer($m[1]);
        if (preg_match('#^(server|servers)/([^/]+)(?:/|$)#', $path, $m)) return $this->findServer($m[2]);

        if ($path === 'admin/servers' || $path === 'admin/servers/' || $this->starts($path, 'admin/servers/new')) return null;

        if (preg_match('#^admin/servers/view/([^/]+)(?:/|$)#', $path, $m)) return $this->findServer($m[1]);
        if (preg_match('#^admin/servers/([^/]+)(?:/|$)#', $path, $m)) return $this->findServer($m[1]);

        foreach (['server', 'server_id', 'id', 'uuid', 'identifier', 'uuidShort', 'uuid_short'] as $key) {
            $value = $request->route($key) ?: $request->input($key);
            if ($value) {
                $server = $this->findServer((string) $value);
                if ($server instanceof Server) return $server;
            }
        }

        return null;
    }

    private function findServer(?string $identifier): ?Server
    {
        if (!$identifier) return null;
        $identifier = trim((string) $identifier);
        if ($identifier === '') return null;

        $query = Server::query()->where('uuidShort', $identifier)->orWhere('uuid', $identifier);

        if (ctype_digit($identifier)) {
            $query->orWhere('id', (int) $identifier);
        }

        return $query->first();
    }

    private function filterOwnServerListResponse(Request $request, Response $response): Response
    {
        if ($response->getStatusCode() !== 200 || !method_exists($response, 'getContent')) return $response;

        $payload = json_decode($response->getContent(), true);
        if (!is_array($payload) || !isset($payload['data']) || !is_array($payload['data'])) return $response;

        $user = $request->user();
        $filtered = [];

        foreach ($payload['data'] as $item) {
            $attr = $item['attributes'] ?? [];

            $identifier = $attr['identifier']
                ?? $attr['uuidShort']
                ?? $attr['uuid_short']
                ?? $attr['uuid']
                ?? null;

            if (!$identifier) continue;

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
        if (is_bool($value)) return $value;
        if (is_numeric($value)) return (int) $value === 1;
        return in_array(strtolower((string) $value), ['1', 'true', 'on', 'yes', 'admin', 'root'], true);
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
PHP_MIDDLEWARE

ok "Middleware v15 dibuat."

# Patch AppServiceProvider + service files with Python to avoid PHP heredoc parse errors.
python3 <<'PY_PATCH'
from pathlib import Path
import re

MAIN_ADMIN_ID = 1

def read(path):
    p = Path(path)
    return p.read_text() if p.exists() else None

def write(path, data):
    Path(path).write_text(data)

def remove_old_kahfi_provider():
    path = Path("app/Providers/AppServiceProvider.php")
    if not path.exists():
        raise SystemExit("AppServiceProvider.php tidak ditemukan")

    s = path.read_text()

    # Remove any old Kahfi middleware registrations/markers.
    s = re.sub(r"\n\s*//\s*KAHFI[^\n]*\n", "\n", s)
    s = re.sub(
        r"\n\s*\$this->app\[['\"]router['\"]\]->pushMiddlewareToGroup\(['\"][^'\"]+['\"],\s*\\\\Pterodactyl\\\\Http\\\\Middleware\\\\Kahfi[^;]+::class\);\s*",
        "\n",
        s,
    )

    cls = r"\\Pterodactyl\\Http\\Middleware\\KahfiMoodTzyPanelProtect::class"
    lines = [
        f"$this->app['router']->pushMiddlewareToGroup('web', {cls});",
        f"$this->app['router']->pushMiddlewareToGroup('api', {cls});",
        f"$this->app['router']->pushMiddlewareToGroup('client-api', {cls});",
        f"$this->app['router']->pushMiddlewareToGroup('application-api', {cls});",
    ]

    # Avoid duplicates.
    for line in lines:
        s = s.replace(line, "")

    inject = "\n        // KAHFIMOODTZYY_PANEL_PROTECT_BOOT_V15\n        " + "\n        ".join(lines) + "\n"

    m = re.search(r"public\s+function\s+boot\s*\([^)]*\)\s*(?::\s*void\s*)?\{", s)
    if m:
        pos = m.end()
        s = s[:pos] + inject + s[pos:]
    else:
        pos = s.rfind("\n}")
        if pos == -1:
            raise SystemExit("Gagal patch AppServiceProvider.php")
        method = "\n    public function boot(): void\n    {\n" + inject + "    }\n"
        s = s[:pos] + method + s[pos:]

    path.write_text(s)
    print("AppServiceProvider patched v15.")

def insert_after_handle(file, marker, guard):
    path = Path(file)
    if not path.exists():
        print(f"SKIP not found: {file}")
        return
    s = path.read_text()
    if marker in s:
        print(f"Already patched: {file}")
        return
    m = re.search(r"public\s+function\s+handle\s*\([^)]*\)\s*(?::\s*[^{]+)?\{", s)
    if not m:
        print(f"WARNING handle() not found: {file}")
        return
    pos = m.end()
    s = s[:pos] + "\n" + guard.rstrip() + "\n" + s[pos:]
    path.write_text(s)
    print(f"Patched: {file}")

def clean_old_server_creation_blockers():
    path = Path("app/Services/Servers/ServerCreationService.php")
    if not path.exists():
        print("ServerCreationService tidak ditemukan, skip clean old blocker.")
        return

    s = path.read_text()
    before = s

    old_throws = [
        r"throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh create server untuk akun admin/root_admin. Pilih user biasa.');",
        r'throw new \Pterodactyl\Exceptions\DisplayException("Admin selain utama tidak boleh create server untuk akun admin/root_admin. Pilih user biasa.");',
        r"throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh create server untuk akun admin/root_admin.');",
        r'throw new \Pterodactyl\Exceptions\DisplayException("Admin selain utama tidak boleh create server untuk akun admin/root_admin.");',
    ]

    new_throw = """if ((int) ($kahfiOwner->id ?? 0) !== (int) ($kahfiActorId ?? ($kahfiAuthUser->id ?? 0))) {
                throw new \\Pterodactyl\\Exceptions\\DisplayException('Admin selain utama tidak boleh create server untuk admin/root_admin lain termasuk admin utama.');
            }"""

    for old in old_throws:
        s = s.replace(old, new_throw)

    # Disable specific old v7/v8/v10/v11 guard conditions only when they are inside old marker areas.
    # Safer fallback: just convert any old "Pilih user biasa" message that remains.
    s = s.replace(
        "Admin selain utama tidak boleh create server untuk akun admin/root_admin. Pilih user biasa.",
        "Admin selain utama tidak boleh create server untuk admin/root_admin lain termasuk admin utama.",
    )

    if s != before:
        path.write_text(s)
        print("Cleaned old ServerCreationService blocker.")
    else:
        print("No old ServerCreationService blocker found.")

ACTOR_CODE = r"""
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
"""

SERVER_CREATE_GUARD = r"""
        // kahfimoodtzyy server owner admin self only guard v15
""" + ACTOR_CODE + r"""
        $kahfiShouldCheckServerCreate = false;

        if (str_starts_with($kahfiPath, 'api/application/servers')) {
            $kahfiShouldCheckServerCreate = true;
        }

        if ($kahfiAuthUser instanceof \Pterodactyl\Models\User && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== $kahfiMainAdminId) {
            $kahfiShouldCheckServerCreate = true;
        }

        if ($kahfiShouldCheckServerCreate && (int) $kahfiActorId !== $kahfiMainAdminId) {
            $kahfiOwnerId = null;
            if (isset($data) && is_array($data)) {
                $kahfiOwnerId = $data['owner_id'] ?? $data['user_id'] ?? $data['user'] ?? null;
            }

            if (!$kahfiOwnerId || !is_numeric($kahfiOwnerId)) {
                throw new \Pterodactyl\Exceptions\DisplayException('Create server wajib memilih owner.');
            }

            try {
                $kahfiOwner = \Pterodactyl\Models\User::query()->find((int) $kahfiOwnerId);
            } catch (\Throwable $e) {
                $kahfiOwner = null;
            }

            if (!$kahfiOwner) {
                throw new \Pterodactyl\Exceptions\DisplayException('Owner user tidak ditemukan.');
            }

            if (!empty($kahfiOwner->root_admin) && (int) $kahfiOwner->id !== (int) $kahfiActorId) {
                throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh create server untuk admin/root_admin lain termasuk admin utama.');
            }
        }
"""

SERVER_DELETE_GUARD = r"""
        // kahfimoodtzyy server deletion main admin only guard v15
""" + ACTOR_CODE + r"""
        if ((int) $kahfiActorId !== $kahfiMainAdminId) {
            throw new \Pterodactyl\Exceptions\DisplayException('Delete/delsrv server hanya untuk admin utama.');
        }
"""

USER_CREATE_GUARD = r"""
        // kahfimoodtzyy user admin hard error guard v15
""" + ACTOR_CODE + r"""
        $kahfiRootRequested = false;

        if (isset($data) && is_array($data)) {
            foreach (['root_admin', 'admin', 'is_admin'] as $kahfiKey) {
                if (array_key_exists($kahfiKey, $data) && filter_var($data[$kahfiKey], FILTER_VALIDATE_BOOLEAN)) {
                    $kahfiRootRequested = true;
                    break;
                }
            }
        }

        if (
            $kahfiRootRequested
            && (
                ($kahfiAuthUser instanceof \Pterodactyl\Models\User && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== $kahfiMainAdminId)
                || (str_starts_with($kahfiPath, 'api/application/users') && (int) $kahfiActorId !== $kahfiMainAdminId)
            )
        ) {
            throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh membuat user admin/root_admin.');
        }
"""

USER_UPDATE_GUARD = r"""
        // kahfimoodtzyy block admin privilege update guard v15
""" + ACTOR_CODE + r"""
        $kahfiRootTouched = isset($data) && is_array($data) && (
            array_key_exists('root_admin', $data)
            || array_key_exists('admin', $data)
            || array_key_exists('is_admin', $data)
        );

        if (
            $kahfiRootTouched
            && (
                ($kahfiAuthUser instanceof \Pterodactyl\Models\User && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== $kahfiMainAdminId)
                || (str_starts_with($kahfiPath, 'api/application/users') && (int) $kahfiActorId !== $kahfiMainAdminId)
            )
        ) {
            throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh mengubah privilege admin.');
        }

        if ($kahfiAuthUser instanceof \Pterodactyl\Models\User && !empty($kahfiAuthUser->root_admin) && (int) $kahfiAuthUser->id !== $kahfiMainAdminId) {
            if (isset($user) && is_object($user) && !empty($user->root_admin)) {
                throw new \Pterodactyl\Exceptions\DisplayException('Admin selain utama tidak boleh edit akun admin.');
            }
        }
"""

remove_old_kahfi_provider()
clean_old_server_creation_blockers()
insert_after_handle("app/Services/Servers/ServerCreationService.php", "kahfimoodtzyy server owner admin self only guard v15", SERVER_CREATE_GUARD)
insert_after_handle("app/Services/Servers/ServerDeletionService.php", "kahfimoodtzyy server deletion main admin only guard v15", SERVER_DELETE_GUARD)
insert_after_handle("app/Services/Users/UserCreationService.php", "kahfimoodtzyy user admin hard error guard v15", USER_CREATE_GUARD)
insert_after_handle("app/Services/Users/UserUpdateService.php", "kahfimoodtzyy block admin privilege update guard v15", USER_UPDATE_GUARD)
PY_PATCH

# Theme badge.
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
fi

info "Checking PHP syntax..."
BAD=0
for f in \
    app/Http/Middleware/KahfiMoodTzyPanelProtect.php \
    app/Providers/AppServiceProvider.php \
    app/Services/Servers/ServerCreationService.php \
    app/Services/Servers/ServerDeletionService.php \
    app/Services/Users/UserCreationService.php \
    app/Services/Users/UserUpdateService.php
do
    if [ -f "$f" ]; then
        php -l "$f" || BAD=1
    fi
done

if [ "$BAD" = "1" ]; then
    err "Ada syntax error. Backup ada di $BACKUP_DIR"
    exit 1
fi

if id www-data >/dev/null 2>&1; then
    chown -R www-data:www-data "$PANEL_PATH" 2>/dev/null || true
fi

chmod -R 755 "$CUSTOM_DIR" 2>/dev/null || true

info "Clearing cache..."
php artisan optimize:clear || true
php artisan config:clear || true
php artisan route:clear || true
php artisan view:clear || true
php artisan cache:clear || true
php artisan queue:restart || true

info "Restart service..."
systemctl restart nginx 2>/dev/null || true
for svc in php8.4-fpm php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm; do
    systemctl restart "$svc" 2>/dev/null || true
done

cat <<EOF

============================================================
kahfimoodtzyy FULL PROTECT v15 SELESAI
============================================================

Admin utama ID $MAIN_ADMIN_ID:
- full akses semua.

Admin selain utama:
- boleh create user biasa.
- tidak boleh create admin/root_admin.
- boleh create server untuk user biasa mana pun.
- boleh create server untuk akun admin dia sendiri.
- tidak boleh create server untuk admin/root_admin lain termasuk admin utama.
- tidak boleh list/detail/update/delete/delsrv server via PTLA/PTLC.
- dashboard/client list hanya menampilkan server owner_id dia sendiri.
- tidak boleh melihat data server orang lain.
- boleh create PTLA/PTLC.
- tidak boleh revoke/delete API key.
- tidak boleh buka Nodes/Nests/Settings.

User biasa:
- tidak boleh create PTLC.
- tetap bisa backup/download/file manager server sendiri sesuai permission.

Theme:
- badge admin tetap: Protected by kahfimoodtzyy

Backup:
$BACKUP_DIR

Test wajib:
1. Admin selain utama create server untuk admin dia sendiri: harus bisa.
2. Admin selain utama create server untuk user biasa mana pun: harus bisa.
3. Admin selain utama create server untuk admin utama/admin lain: harus 403.
4. Admin selain utama list server via bot/PTLA: harus 403.
5. Admin selain utama delete/delsrv via bot/PTLA: harus 403.
6. User biasa backup/download file server sendiri: harus bisa.

============================================================
EOF
