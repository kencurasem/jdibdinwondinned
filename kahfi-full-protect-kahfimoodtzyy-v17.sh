#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# KahfiMoodtzyy FULL PROTECT v17 CLEAN
#
# Dibuat agar bisa dipasang lewat GitHub raw.
# Tidak overwrite full controller besar-besaran supaya fitur panel tidak rusak.
# Protect dipasang lewat middleware global Laravel + cleanup file lama yang error.
#
# RULE:
# Admin utama:
# - full akses semua.
#
# Admin selain utama:
# - boleh create user biasa.
# - tidak boleh create admin/root_admin.
# - boleh create server untuk user biasa mana pun.
# - boleh create server untuk akun admin dia sendiri.
# - tidak boleh create server untuk admin/root_admin lain termasuk admin utama.
# - tidak boleh list/detail/update/delete/delsrv server lewat PTLA/PTLC.
# - dashboard/client list hanya menampilkan server owner_id dia sendiri.
# - tidak boleh melihat data server orang lain.
# - boleh create PTLA/PTLC.
# - tidak boleh revoke/delete API key.
# - tidak boleh buka Nodes/Nests/Settings/Locations/Databases/Mounts.
#
# User biasa:
# - tidak boleh create PTLC.
# - tetap bisa backup/download/file manager server sendiri sesuai permission.
#
# Install:
# MAIN_ADMIN_ID=1 bash kahfi-full-protect-kahfimoodtzyy-v17.sh
# MAIN_ADMIN_ID=1 bash kahfi-full-protect-kahfimoodtzyy-v17.sh /var/www/pterodactyl
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

info "Starting KahfiMoodtzyy FULL PROTECT v17 CLEAN"
info "Panel: $PANEL_PATH"
info "Main admin ID: $MAIN_ADMIN_ID"
info "Backup: $BACKUP_DIR"

backup_file(){
    local file_path="$1"
    local backup_name="$2"
    if [ -f "$file_path" ]; then
        cp -a "$file_path" "$BACKUP_DIR/${backup_name}_${TIMESTAMP}.bak"
        info "Backed up current: $backup_name"
    fi
}

backup_file ".env" "env"
backup_file "app/Http/Kernel.php" "Kernel"
backup_file "app/Providers/AppServiceProvider.php" "AppServiceProvider"
backup_file "resources/views/layouts/admin.blade.php" "admin_layout"
backup_file "app/Services/Servers/ServerCreationService.php" "ServerCreationService"
backup_file "app/Services/Servers/ServerDeletionService.php" "ServerDeletionService"
backup_file "app/Services/Users/UserCreationService.php" "UserCreationService"
backup_file "app/Services/Users/UserUpdateService.php" "UserUpdateService"
backup_file "app/Http/Controllers/Admin/Servers/ServerController.php" "AdminServersServerController"
backup_file "app/Http/Controllers/Admin/ServersController.php" "ServersController"
backup_file "app/Http/Controllers/Admin/UserController.php" "UserController"
backup_file "app/Http/Controllers/Api/Client/Servers/FileController.php" "FileController"
backup_file "app/Http/Controllers/Api/Client/Servers/ServerController.php" "ClientServerController"

if grep -q '^KAHFI_MAIN_ADMIN_ID=' .env 2>/dev/null; then
    sed -i "s/^KAHFI_MAIN_ADMIN_ID=.*/KAHFI_MAIN_ADMIN_ID=${MAIN_ADMIN_ID}/" .env
else
    printf '\nKAHFI_MAIN_ADMIN_ID=%s\n' "$MAIN_ADMIN_ID" >> .env
fi

# Cleanup dan restore file yang sempat rusak oleh versi protect lama.
python3 <<'PY_CLEAN'
from pathlib import Path
import subprocess
import shutil
import re

backup_dir = Path("/root/pterodactyl_backups")

targets = {
    "app/Http/Kernel.php": ["Kernel"],
    "app/Providers/AppServiceProvider.php": ["AppServiceProvider"],
    "app/Services/Servers/ServerCreationService.php": ["ServerCreationService"],
    "app/Services/Servers/ServerDeletionService.php": ["ServerDeletionService"],
    "app/Services/Users/UserCreationService.php": ["UserCreationService"],
    "app/Services/Users/UserUpdateService.php": ["UserUpdateService"],
    "app/Http/Controllers/Admin/Servers/ServerController.php": ["AdminServersServerController", "ServerController"],
    "app/Http/Controllers/Admin/ServersController.php": ["ServersController"],
    "app/Http/Controllers/Admin/UserController.php": ["UserController"],
    "app/Http/Controllers/Api/Client/Servers/FileController.php": ["FileController"],
    "app/Http/Controllers/Api/Client/Servers/ServerController.php": ["ClientServerController", "ServerController"],
}

bad_markers = [
    "KahfiMoodTzyPanelProtect",
    "KahfiFullAdminProtect",
    "KahfiAdminOwnServerAccess",
    "KahfiPanelFullProtect",
    "KahfiModTzy",
    "kahfimoodtzyy server",
    "kahfimoodtzyy user",
    "KAHFIMOODTZYY_PANEL_PROTECT",
    "YogzProtect",
    "@BarzzAkunNew",
    "Gagal Mengintip",
    "Pilih user biasa",
]

def php_ok(path: Path) -> bool:
    try:
        r = subprocess.run(["php", "-l", str(path)], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=20)
        return r.returncode == 0
    except Exception:
        return False

def is_clean_backup(path: Path) -> bool:
    try:
        data = path.read_text(errors="ignore")
    except Exception:
        return False
    if any(m in data for m in bad_markers):
        return False
    return php_ok(path)

for target, prefixes in targets.items():
    tp = Path(target)
    need_restore = False

    if tp.exists():
        data = tp.read_text(errors="ignore")
        if not php_ok(tp) or any(m in data for m in bad_markers):
            need_restore = True
    else:
        continue

    if not need_restore:
        continue

    candidates = []
    for prefix in prefixes:
        candidates.extend(backup_dir.glob(f"{prefix}_*.bak"))

    candidates = sorted(set(candidates), key=lambda p: p.stat().st_mtime)

    clean = [p for p in candidates if is_clean_backup(p)]

    if clean:
        src = clean[-1]
        shutil.copy2(src, tp)
        print(f"[OK] Restored clean {target} <= {src}")
    else:
        print(f"[WARN] No clean backup for {target}; trying regex cleanup only.")

# Cleanup provider and kernel from any old bad lines.
for pth in ["app/Providers/AppServiceProvider.php", "app/Http/Kernel.php"]:
    p = Path(pth)
    if not p.exists():
        continue
    s = p.read_text(errors="ignore")
    s = re.sub(r"\n\s*//\s*KAHFI[^\n]*\n", "\n", s)
    s = re.sub(r"\n\s*//\s*Kahfi[^\n]*\n", "\n", s)
    s = re.sub(r"\n\s*.*KahfiMoodTzyPanelProtect::class.*\n", "\n", s)
    s = re.sub(r"\n\s*.*KahfiFullAdminProtect::class.*\n", "\n", s)
    s = re.sub(r"\n\s*.*KahfiAdminOwnServerAccess::class.*\n", "\n", s)
    s = re.sub(r"\n\s*.*KahfiPanelFullProtect::class.*\n", "\n", s)
    p.write_text(s)
PY_CLEAN

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
                        return $this->deny($request, 'Create server wajib memilih owner. Protect By KahfiMoodtzyy.');
                    }

                    if ($this->isRootAdminUserId($ownerId) && (int) $ownerId !== (int) $actorId) {
                        return $this->deny($request, 'Admin selain utama tidak boleh create server untuk admin/root_admin lain termasuk admin utama. Protect By KahfiMoodtzyy.');
                    }

                    return $next($request);
                }

                return $this->deny($request, 'List/detail/update/delete/delsrv server lewat PTLA hanya untuk admin utama. Protect By KahfiMoodtzyy.');
            }
        }

        if ($this->starts($path, 'api/application/users') && in_array($method, ['POST', 'PUT', 'PATCH'], true)) {
            $actorId = $this->actingUserId($request);
            $isMain = $actorId !== null && (int) $actorId === $mainAdminId;

            if (!$isMain && $this->requestTouchesAdminFlag($request)) {
                return $this->deny($request, 'Admin selain utama tidak boleh create/edit user admin/root_admin lewat PTLA. Protect By KahfiMoodtzyy.');
            }
        }

        $user = $request->user();

        if ($user && empty($user->root_admin)) {
            if ($this->isPtlcCreate($request, $path)) {
                return $this->deny($request, 'User biasa tidak boleh membuat PTLC/API key. Protect By KahfiMoodtzyy.');
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
            return $this->deny($request, 'Hanya admin utama yang boleh revoke/delete API key. Protect By KahfiMoodtzyy.');
        }

        if ($this->isUserCreateRequest($request, $path) && $this->requestTouchesAdminFlag($request)) {
            return $this->deny($request, 'Admin selain utama tidak boleh membuat user admin/root_admin. Protect By KahfiMoodtzyy.');
        }

        if ($this->isUserPrivilegeUpdate($request, $path) && ($request->has('root_admin') || $request->has('admin') || $request->has('is_admin'))) {
            return $this->deny($request, 'Admin selain utama tidak boleh mengubah privilege admin. Protect By KahfiMoodtzyy.');
        }

        if ($this->isAdminServerCreate($request, $path)) {
            $ownerId = $this->requestedServerOwnerId($request);

            if (!$ownerId) {
                return $this->deny($request, 'Create server wajib memilih owner. Protect By KahfiMoodtzyy.');
            }

            if ($this->isRootAdminUserId($ownerId) && (int) $ownerId !== (int) $user->id) {
                return $this->deny($request, 'Admin selain utama tidak boleh create server untuk admin/root_admin lain termasuk admin utama. Protect By KahfiMoodtzyy.');
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
            return $this->deny($request, 'Admin selain utama tidak boleh melihat data server orang lain. Protect By KahfiMoodtzyy.');
        }

        return $next($request);
    }

    private function blockedAdminArea(Request $request, string $path): ?Response
    {
        foreach (['admin/settings', 'admin/system', 'admin/roles', 'admin/mounts', 'admin/locations', 'admin/databases'] as $prefix) {
            if ($this->starts($path, $prefix)) {
                return $this->deny($request, 'Area ini hanya untuk admin utama. Protect By KahfiMoodtzyy.');
            }
        }

        foreach (['admin/nodes', 'admin/nests'] as $prefix) {
            if ($this->starts($path, $prefix)) {
                if ($request->isMethod('GET') && ($request->ajax() || $request->expectsJson())) {
                    return null;
                }

                return $this->deny($request, 'Nodes dan Nests hanya boleh diakses admin utama. Protect By KahfiMoodtzyy.');
            }
        }

        foreach (['admin/users/view', 'admin/users/edit', 'admin/users/delete', 'admin/users/two-factor'] as $prefix) {
            if ($this->starts($path, $prefix)) {
                return $this->deny($request, 'Admin selain utama tidak boleh membuka detail/edit/delete user. Protect By KahfiMoodtzyy.');
            }
        }

        if (($path === 'admin/users' || $path === 'admin/users/') && $request->isMethod('GET')) {
            return redirect('/admin/users/new');
        }

        if (($path === 'admin/servers' || $path === 'admin/servers/') && $request->isMethod('GET')) {
            return redirect('/admin/servers/new');
        }

        if ($this->isAdminServerDelete($request, $path)) {
            return $this->deny($request, 'Delete/delsrv server hanya untuk admin utama. Protect By KahfiMoodtzyy.');
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

    private function isAdminServerDelete(Request $request, string $path): bool
    {
        if (!in_array(strtoupper($request->method()), ['POST', 'DELETE'], true)) return false;

        $action = strtolower((string) $request->input('action'));
        $method = strtoupper((string) $request->input('_method'));

        return $this->starts($path, 'admin/servers')
            && (
                str_contains($path, 'delete')
                || $action === 'delete'
                || $action === 'force_delete'
                || $method === 'DELETE'
            );
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
                    'code' => 'KahfiMoodtzyyProtected',
                    'status' => '403',
                    'detail' => $message,
                ]],
            ], 403);
        }

        abort(403, $message);
    }
}
PHP_MIDDLEWARE

# Register middleware global via Kernel, bukan AppServiceProvider, supaya tidak bikin parse error.
python3 <<'PY_KERNEL'
from pathlib import Path
import re

file = Path("app/Http/Kernel.php")
if not file.exists():
    raise SystemExit("Kernel.php tidak ditemukan")

s = file.read_text(errors="ignore")

# remove previous registrations
s = re.sub(r"\n\s*\\?Pterodactyl\\Http\\Middleware\\KahfiMoodTzyPanelProtect::class,\s*", "\n", s)
s = re.sub(r"\n\s*\\?Pterodactyl\\Http\\Middleware\\KahfiFullAdminProtect::class,\s*", "\n", s)
s = re.sub(r"\n\s*\\?Pterodactyl\\Http\\Middleware\\KahfiAdminOwnServerAccess::class,\s*", "\n", s)
s = re.sub(r"\n\s*\\?Pterodactyl\\Http\\Middleware\\KahfiPanelFullProtect::class,\s*", "\n", s)

line = r"        \Pterodactyl\Http\Middleware\KahfiMoodTzyPanelProtect::class,"

m = re.search(r"protected\s+\$middleware\s*=\s*\[", s)
if not m:
    raise SystemExit("Tidak menemukan protected $middleware di Kernel.php")

pos = m.end()
s = s[:pos] + "\n" + line + s[pos:]

file.write_text(s)
print("[OK] Kernel global middleware patched.")
PY_KERNEL

# Theme badge KahfiMoodtzyy.
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
        badge.textContent = "Protected by KahfiMoodtzyy";
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
    app/Http/Kernel.php \
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
    err "Masih ada syntax error. Backup ada di $BACKUP_DIR"
    err "Cek manual: php -l app/Http/Kernel.php && php -l app/Providers/AppServiceProvider.php"
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
KahfiMoodtzyy FULL PROTECT v17 CLEAN SELESAI
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
- tidak boleh buka Nodes/Nests/Settings/Locations/Databases/Mounts.

User biasa:
- tidak boleh create PTLC.
- tetap bisa backup/download/file manager server sendiri sesuai permission.

Theme:
- badge admin: Protected by KahfiMoodtzyy

Backup:
$BACKUP_DIR

Test:
1. Admin selain utama create server untuk admin dia sendiri: harus bisa.
2. Admin selain utama create server untuk user biasa mana pun: harus bisa.
3. Admin selain utama create server untuk admin utama/admin lain: harus 403.
4. Admin selain utama list server via bot/PTLA: harus 403.
5. Admin selain utama delete/delsrv via bot/PTLA: harus 403.
6. User biasa backup/download file server sendiri: harus bisa.

============================================================
EOF
