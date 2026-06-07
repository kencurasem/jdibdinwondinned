#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# KahfiMoodtzyy ProtectAll BOT-STYLE v18
# Convert rule dari command bot /installprotectall:
# - Main admin ID 1 full akses
# - Selain ID 1 hanya boleh lihat/manage server milik sendiri
# - Selain ID 1 create server owner otomatis/dibatasi ke akun sendiri
# - Selain ID 1 tidak boleh create admin
# - Nodes, Nests, Settings, Location, Database, Mount, Application API hanya ID 1
# - Client API key/PTLC hanya ID 1, sesuai kode bot yang kamu kasih
# - File/backup/download tetap jalan untuk server milik sendiri
# ==========================================================

MAIN_ADMIN_ID="${MAIN_ADMIN_ID:-1}"
PANEL_PATH="${1:-/var/www/pterodactyl}"
BACKUP_DIR="/root/pterodactyl_backups"
TS="$(date +%Y%m%d-%H%M%S)"

info(){ echo "[INFO] $1"; }
ok(){ echo "[OK] $1"; }
fail(){ echo "[ERROR] $1"; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Jalankan sebagai root."
[ -f "$PANEL_PATH/artisan" ] || fail "Panel tidak ketemu: $PANEL_PATH"

cd "$PANEL_PATH"
mkdir -p "$BACKUP_DIR"

info "Install KahfiMoodtzyy ProtectAll BOT-STYLE v18"
info "Panel: $PANEL_PATH"
info "Main admin: $MAIN_ADMIN_ID"

backup(){
  [ -f "$1" ] && cp -a "$1" "$BACKUP_DIR/$(basename "$1").botstyle-v18-$TS.bak" && info "Backup $1" || true
}

backup .env
backup app/Http/Kernel.php
backup app/Providers/AppServiceProvider.php
backup resources/views/layouts/admin.blade.php

if grep -q '^KAHFI_MAIN_ADMIN_ID=' .env 2>/dev/null; then
  sed -i "s/^KAHFI_MAIN_ADMIN_ID=.*/KAHFI_MAIN_ADMIN_ID=$MAIN_ADMIN_ID/" .env
else
  printf '\nKAHFI_MAIN_ADMIN_ID=%s\n' "$MAIN_ADMIN_ID" >> .env
fi

# Hapus protect lama biar tidak bentrok.
rm -f app/Http/Middleware/KahfiMoodTzyPanelProtect.php
rm -f app/Http/Middleware/KahfiFullAdminProtect.php
rm -f app/Http/Middleware/KahfiAdminOwnServerAccess.php
rm -f app/Http/Middleware/KahfiPanelFullProtect.php

mkdir -p app/Http/Middleware

cat > app/Http/Middleware/KahfiMoodtzyyBotStyleProtect.php <<'PHP'
<?php

namespace Pterodactyl\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Pterodactyl\Models\Server;
use Pterodactyl\Models\User;
use Symfony\Component\HttpFoundation\Response;

class KahfiMoodtzyyBotStyleProtect
{
    public function handle(Request $request, Closure $next): Response
    {
        $path = trim($request->path(), '/');
        $method = strtoupper($request->method());
        $mainAdminId = (int) env('KAHFI_MAIN_ADMIN_ID', 1);
        $user = $request->user();
        $actorId = $this->actingUserId($request);

        /*
         * Application API/PTLA sesuai protect bot:
         * Application API menu dan endpoint hanya admin utama.
         */
        if ($this->starts($path, 'api/application')) {
            if ((int) $actorId !== $mainAdminId) {
                return $this->deny($request, 'Application API hanya untuk admin utama. Protect By KahfiMoodtzyy.');
            }
        }

        /*
         * User biasa:
         * Tidak bisa create PTLC/API key.
         * File, backup, download server sendiri tetap ikut permission bawaan panel.
         */
        if ($user && empty($user->root_admin)) {
            if ($this->isClientApiKeyArea($request, $path)) {
                return $this->deny($request, 'Client API key/PTLC hanya untuk admin utama. Protect By KahfiMoodtzyy.');
            }

            return $next($request);
        }

        if (!$user) {
            return $next($request);
        }

        /*
         * Admin utama full akses.
         */
        if ((int) $user->id === $mainAdminId) {
            return $next($request);
        }

        /*
         * Admin selain utama:
         * Bot-style: hanya manage milik sendiri.
         */

        // Client API key/PTLC hanya admin utama, sesuai code ApiKeyController di bot.
        if ($this->isClientApiKeyArea($request, $path)) {
            return $this->deny($request, 'Client API key/PTLC hanya untuk admin utama. Protect By KahfiMoodtzyy.');
        }

        // Tidak boleh revoke/delete API key.
        if ($this->isApiKeyDelete($request, $path)) {
            return $this->deny($request, 'Revoke/delete API key hanya untuk admin utama. Protect By KahfiMoodtzyy.');
        }

        // Tidak boleh akses area global.
        $blocked = $this->blockedAdminArea($request, $path);
        if ($blocked instanceof Response) {
            return $blocked;
        }

        // Create user boleh, tapi root_admin/admin dipaksa gagal.
        if ($this->isUserCreateOrUpdate($request, $path) && $this->requestTouchesAdminFlag($request)) {
            return $this->deny($request, 'Selain admin utama tidak boleh create/edit user admin. Protect By KahfiMoodtzyy.');
        }

        // Create server bot-style: selain ID 1 hanya boleh owner dirinya sendiri.
        if ($this->isAdminServerCreate($request, $path)) {
            $ownerId = $this->requestedServerOwnerId($request);
            if (!$ownerId) {
                return $this->deny($request, 'Owner server wajib dipilih. Protect By KahfiMoodtzyy.');
            }

            if ((int) $ownerId !== (int) $user->id) {
                return $this->deny($request, 'Selain admin utama hanya boleh create server untuk akun sendiri. Protect By KahfiMoodtzyy.');
            }
        }

        // List server admin diarahkan ke create, agar tidak intip list semua server.
        if (($path === 'admin/servers' || $path === 'admin/servers/') && $request->isMethod('GET')) {
            return redirect('/admin/servers/new');
        }

        // List user diarahkan ke create, agar tidak intip semua user.
        if (($path === 'admin/users' || $path === 'admin/users/') && $request->isMethod('GET')) {
            return redirect('/admin/users/new');
        }

        // Client/dashboard list hanya server owner_id dirinya sendiri.
        if ($this->isClientServerList($request, $path)) {
            $response = $next($request);
            return $this->filterOwnServerListResponse($request, $response);
        }

        // Direct access server hanya owner sendiri.
        $server = $this->serverFromRequest($request, $path);
        if ($server instanceof Server && (int) $server->owner_id !== (int) $user->id) {
            return $this->deny($request, 'Akses ditolak, hanya boleh membuka server milik sendiri. Protect By KahfiMoodtzyy.');
        }

        return $next($request);
    }

    private function blockedAdminArea(Request $request, string $path): ?Response
    {
        $blockedPrefixes = [
            'admin/settings',
            'admin/system',
            'admin/api',
            'admin/locations',
            'admin/nodes',
            'admin/nests',
            'admin/databases',
            'admin/mounts',
        ];

        foreach ($blockedPrefixes as $prefix) {
            if ($this->starts($path, $prefix)) {
                return $this->deny($request, 'Menu ini hanya untuk admin utama. Protect By KahfiMoodtzyy.');
            }
        }

        foreach (['admin/users/view', 'admin/users/edit', 'admin/users/delete', 'admin/users/two-factor'] as $prefix) {
            if ($this->starts($path, $prefix)) {
                return $this->deny($request, 'Selain admin utama tidak boleh membuka detail/edit/delete user. Protect By KahfiMoodtzyy.');
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

    private function actingUserId(Request $request): ?int
    {
        $user = $request->user();
        if ($user instanceof User && isset($user->id)) return (int) $user->id;

        try {
            $authUser = \Illuminate\Support\Facades\Auth::user();
            if ($authUser instanceof User && isset($authUser->id)) return (int) $authUser->id;
        } catch (\Throwable $e) {}

        foreach ($request->attributes->all() as $value) {
            if (is_object($value) && isset($value->user_id)) return (int) $value->user_id;
            if (is_array($value) && isset($value['user_id'])) return (int) $value['user_id'];
        }

        return $this->apiKeyOwnerId($request);
    }

    private function apiKeyOwnerId(Request $request): ?int
    {
        $token = (string) $request->bearerToken();
        if ($token === '') {
            $header = (string) $request->header('Authorization', '');
            if (preg_match('/Bearer\s+(.+)/i', $header, $m)) $token = trim($m[1]);
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

        if (preg_match('/^((?:ptla|ptlc)_[A-Za-z0-9]+)/', $token, $m)) $candidates[] = $m[1];

        foreach (array_values(array_unique(array_filter($candidates))) as $identifier) {
            try {
                $row = \Illuminate\Support\Facades\DB::table('api_keys')->where('identifier', $identifier)->first();
                if ($row && isset($row->user_id)) return (int) $row->user_id;
            } catch (\Throwable $e) {}
        }

        return null;
    }

    private function isClientApiKeyArea(Request $request, string $path): bool
    {
        return $this->starts($path, 'api/client/account/api-keys')
            || $this->starts($path, 'account/api');
    }

    private function isApiKeyDelete(Request $request, string $path): bool
    {
        if (!in_array(strtoupper($request->method()), ['DELETE', 'POST'], true)) return false;

        $isDeleteAction = $request->isMethod('DELETE')
            || strtoupper((string) $request->input('_method')) === 'DELETE'
            || strtolower((string) $request->input('action')) === 'delete'
            || strtolower((string) $request->input('action')) === 'revoke';

        if (!$isDeleteAction) return false;

        return $this->starts($path, 'admin/api')
            || $this->starts($path, 'api/client/account/api-keys')
            || $this->starts($path, 'account/api')
            || $this->starts($path, 'api/application/api-keys');
    }

    private function isUserCreateOrUpdate(Request $request, string $path): bool
    {
        return in_array(strtoupper($request->method()), ['POST', 'PUT', 'PATCH'], true)
            && (
                $path === 'admin/users'
                || $path === 'admin/users/'
                || $path === 'admin/users/new'
                || $path === 'admin/users/new/'
                || $this->starts($path, 'admin/users/view')
                || $this->starts($path, 'admin/users/edit')
                || $this->starts($path, 'api/application/users')
            );
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
        if (ctype_digit($identifier)) $query->orWhere('id', (int) $identifier);

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
            $identifier = $attr['identifier'] ?? $attr['uuidShort'] ?? $attr['uuid_short'] ?? $attr['uuid'] ?? null;
            if (!$identifier) continue;

            $server = $this->findServer((string) $identifier);
            if ($server instanceof Server && (int) $server->owner_id === (int) $user->id) $filtered[] = $item;
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
PHP

# Register di Kernel global.
python3 <<'PY'
from pathlib import Path
import re

p = Path("app/Http/Kernel.php")
if not p.exists():
    raise SystemExit("Kernel.php tidak ditemukan")

s = p.read_text(errors="ignore")

# bersihkan register lama
for name in [
    "KahfiMoodtzyyBotStyleProtect",
    "KahfiMoodTzyPanelProtect",
    "KahfiFullAdminProtect",
    "KahfiAdminOwnServerAccess",
    "KahfiPanelFullProtect",
]:
    s = re.sub(r"\n\s*\\?Pterodactyl\\Http\\Middleware\\" + re.escape(name) + r"::class,\s*", "\n", s)

line = r"        \Pterodactyl\Http\Middleware\KahfiMoodtzyyBotStyleProtect::class,"
m = re.search(r"protected\s+\$middleware\s*=\s*\[", s)
if not m:
    raise SystemExit("protected $middleware tidak ditemukan")

s = s[:m.end()] + "\n" + line + s[m.end():]
p.write_text(s)
print("[OK] Kernel patched")
PY

# Patch new server blade supaya non-admin owner auto self seperti bot.
BLADE="resources/views/admin/servers/new.blade.php"
if [ -f "$BLADE" ]; then
  backup "$BLADE"
  python3 <<'PY'
from pathlib import Path
import re

p = Path("resources/views/admin/servers/new.blade.php")
s = p.read_text(errors="ignore")

# Patch ringan: inject script agar owner non-main otomatis self dan select disabled.
inject = r"""
@if(Auth::user()->id != (int) env('KAHFI_MAIN_ADMIN_ID', 1))
<script>
document.addEventListener('DOMContentLoaded', function () {
    var owner = document.querySelector('[name="owner_id"], [name="user_id"], [name="user"]');
    if (owner) {
        owner.value = '{{ Auth::user()->id }}';
        owner.dispatchEvent(new Event('change'));
        owner.style.pointerEvents = 'none';
        owner.style.opacity = '0.65';
    }
});
</script>
@endif
"""
if "KahfiMoodtzyy owner auto self" not in s:
    s = s.replace("@endsection", "<!-- KahfiMoodtzyy owner auto self -->\n" + inject + "\n@endsection", 1)

p.write_text(s)
PY
fi

# Badge theme sesuai nama.
mkdir -p public/assets/custom
cat > public/assets/custom/kahfimoodtzyy-botstyle.css <<'CSS'
.kahfi-security-badge{position:fixed;top:16px;right:16px;background:linear-gradient(135deg,#ea4335,#7f1d1d);color:#fff;padding:8px 14px;border-radius:18px;font-size:12px;font-weight:700;z-index:99999;box-shadow:0 4px 14px rgba(0,0,0,.25);letter-spacing:.3px}
CSS
cat > public/assets/custom/kahfimoodtzyy-botstyle.js <<'JS'
document.addEventListener("DOMContentLoaded",function(){if(!document.querySelector(".kahfi-security-badge")){const b=document.createElement("div");b.className="kahfi-security-badge";b.textContent="Protected by KahfiMoodtzyy";document.body.appendChild(b);}});
JS

LAYOUT="resources/views/layouts/admin.blade.php"
if [ -f "$LAYOUT" ]; then
  if ! grep -q "kahfimoodtzyy-botstyle.css" "$LAYOUT"; then
    sed -i '/<\/head>/i\    <link rel="stylesheet" href="{{ asset('\''assets/custom/kahfimoodtzyy-botstyle.css'\'') }}">' "$LAYOUT"
  fi
  if ! grep -q "kahfimoodtzyy-botstyle.js" "$LAYOUT"; then
    sed -i '/<\/body>/i\    <script src="{{ asset('\''assets/custom/kahfimoodtzyy-botstyle.js'\'') }}"></script>' "$LAYOUT"
  fi
fi

info "Cek syntax..."
php -l app/Http/Middleware/KahfiMoodtzyyBotStyleProtect.php
php -l app/Http/Kernel.php

info "Clear cache..."
php artisan optimize:clear || true
php artisan config:clear || true
php artisan route:clear || true
php artisan view:clear || true
php artisan cache:clear || true
php artisan queue:restart || true

chown -R www-data:www-data "$PANEL_PATH" 2>/dev/null || true
systemctl restart nginx 2>/dev/null || true
for svc in php8.4-fpm php8.3-fpm php8.2-fpm php8.1-fpm php8.0-fpm php7.4-fpm; do
  systemctl restart "$svc" 2>/dev/null || true
done

ok "KahfiMoodtzyy ProtectAll BOT-STYLE v18 selesai"
echo "Backup: $BACKUP_DIR"
