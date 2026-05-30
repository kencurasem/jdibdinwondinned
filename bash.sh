#!/bin/bash
set -euo pipefail

PANEL_PATH="${PANEL_PATH:-/var/www/pterodactyl}"
BACKUP_DIR="${BACKUP_DIR:-/root/pterodactyl_backups}"
TS="$(date -u +%Y-%m-%d-%H-%M-%S)"

if [ ! -d "$PANEL_PATH" ]; then
  echo "ERROR: Folder panel tidak ketemu: $PANEL_PATH"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
cd "$PANEL_PATH"

echo "=== Daftar akun root_admin di panel ==="
php artisan tinker --execute='Pterodactyl\Models\User::where("root_admin",1)->orderBy("id")->get(["id","username","email","root_admin"])->each(function($u){ echo "ID={$u->id} | USER={$u->username} | EMAIL={$u->email}\n"; });' 2>/dev/null || true
echo ""

if [ "${1:-}" != "" ]; then
  MAIN_ADMIN_ID="$1"
else
  read -rp "Masukkan ID ADMIN UTAMA yang boleh delete server: " MAIN_ADMIN_ID
fi

if ! [[ "$MAIN_ADMIN_ID" =~ ^[0-9]+$ ]]; then
  echo "ERROR: ID admin utama harus angka."
  exit 1
fi

echo "Admin utama yang boleh delete server: ID $MAIN_ADMIN_ID"

# Simpan ID admin utama ke .env agar tidak hardcode ID 1 terus.
cp .env "$BACKUP_DIR/env_before_delete_fix_$TS.bak"
if grep -q '^KAHFI_MAIN_ADMIN_ID=' .env; then
  sed -i "s/^KAHFI_MAIN_ADMIN_ID=.*/KAHFI_MAIN_ADMIN_ID=$MAIN_ADMIN_ID/" .env
else
  printf '\nKAHFI_MAIN_ADMIN_ID=%s\n' "$MAIN_ADMIN_ID" >> .env
fi

# Backup file penting.
[ -f app/Services/Servers/ServerDeletionService.php ] && cp app/Services/Servers/ServerDeletionService.php "$BACKUP_DIR/ServerDeletionService_before_delete_fix_$TS.bak"
[ -f app/Http/Controllers/Admin/ServersController.php ] && cp app/Http/Controllers/Admin/ServersController.php "$BACKUP_DIR/ServersController_before_delete_fix_$TS.bak"

cat > app/Services/Servers/ServerDeletionService.php <<'PHP'
<?php

namespace Pterodactyl\Services\Servers;

use Illuminate\Http\Response;
use Pterodactyl\Models\Server;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Log;
use Pterodactyl\Exceptions\DisplayException;
use Illuminate\Database\ConnectionInterface;
use Pterodactyl\Repositories\Wings\DaemonServerRepository;
use Pterodactyl\Services\Databases\DatabaseManagementService;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;

class ServerDeletionService
{
    protected bool $force = false;

    public function __construct(
        private ConnectionInterface $connection,
        private DaemonServerRepository $daemonServerRepository,
        private DatabaseManagementService $databaseManagementService
    ) {}

    public function withForce(bool $bool = true): self
    {
        $this->force = $bool;
        return $this;
    }

    private function getMainAdminId(): int
    {
        return (int) (env('KAHFI_MAIN_ADMIN_ID') ?: 1);
    }

    private function getCurrentUser()
    {
        $user = Auth::user();

        if (!$user) {
            try {
                $user = request()->user();
            } catch (\Throwable $e) {
                $user = null;
            }
        }

        return $user;
    }

    private function ensureMainAdminCanDelete(): void
    {
        $user = $this->getCurrentUser();
        $mainAdminId = $this->getMainAdminId();

        if (!$user || (int) $user->id !== $mainAdminId) {
            throw new DisplayException('✖ KahfiModTzy Protection :: Only Main Admin can delete servers');
        }

        if (isset($user->root_admin) && !$user->root_admin) {
            throw new DisplayException('✖ KahfiModTzy Protection :: Main Admin account must be root_admin');
        }
    }

    public function handle(Server $server): void
    {
        // FIX: hanya admin utama sesuai KAHFI_MAIN_ADMIN_ID yang bisa delete server.
        // Admin 2/3 tetap diblokir walaupun root_admin.
        $this->ensureMainAdminCanDelete();

        try {
            $this->daemonServerRepository->setServer($server)->delete();
        } catch (DaemonConnectionException $exception) {
            if (!$this->force && $exception->getStatusCode() !== Response::HTTP_NOT_FOUND) {
                throw $exception;
            }

            Log::warning($exception);
        }

        $this->connection->transaction(function () use ($server) {
            foreach ($server->databases as $database) {
                try {
                    $this->databaseManagementService->delete($database);
                } catch (\Exception $exception) {
                    if (!$this->force) {
                        throw $exception;
                    }

                    $database->delete();
                    Log::warning($exception);
                }
            }

            $server->delete();
        });
    }
}
PHP

python3 <<'PY'
from pathlib import Path
import re

p = Path('/var/www/pterodactyl/app/Http/Controllers/Admin/ServersController.php')
s = p.read_text()

# Fix checkAdmin: jangan hardcode ID 1, pakai KAHFI_MAIN_ADMIN_ID dari .env.
pattern = r'''    // ── Helper cek akses ─────────────────────────────────────\n    private function checkAdmin\(string \$action = "access"\): void\n    \{\n        \$user = Auth::user\(\);\n        if \(!\$user \|\| \$user->id !== 1\) \{\n            throw new DisplayException\("✖ KahfiModTzy Protection :: Only Root Admin can \$action servers"\);\n        \}\n    \}\n'''
replacement = '''    // ── Helper cek akses ─────────────────────────────────────
    private function mainAdminId(): int
    {
        return (int) (env("KAHFI_MAIN_ADMIN_ID") ?: 1);
    }

    private function checkAdmin(string $action = "access"): void
    {
        $user = Auth::user();
        $mainAdminId = $this->mainAdminId();

        if (!$user || (int) $user->id !== $mainAdminId || !$user->root_admin) {
            throw new DisplayException("✖ KahfiModTzy Protection :: Only Main Admin can $action servers");
        }
    }
'''

s2 = re.sub(pattern, replacement, s, count=1)
if s2 == s:
    # Fallback regex kalau komentar/spacing beda.
    pattern2 = r'''    private function checkAdmin\(string \$action = "access"\): void\s*\{.*?\n    \}\n\n    public function index'''
    replacement2 = replacement + '''
    public function index'''
    s2 = re.sub(pattern2, replacement2, s, count=1, flags=re.S)

if s2 == s:
    print('WARNING: checkAdmin tidak ketemu, file ServersController mungkin beda versi.')
else:
    s = s2
    print('OK: checkAdmin sudah pakai KAHFI_MAIN_ADMIN_ID.')

# Fix delete method: jangan 500 polos; tampilkan alert dan arahkan balik.
pattern3 = r'''    public function delete\(Request \$request, Server \$server\): RedirectResponse\s*\{\s*\$this->checkAdmin\("delete"\);\s*\$this->deletionService->withForce\(\$request->filled\("force_delete"\)\)->handle\(\$server\);\s*return redirect\(\)->route\("admin\.servers"\);\s*\}\n'''
replacement3 = '''    public function delete(Request $request, Server $server): RedirectResponse
    {
        $this->checkAdmin("delete");

        try {
            $this->deletionService->withForce($request->filled("force_delete"))->handle($server);
            $this->alert->success("Server deleted successfully.")->flash();

            return redirect()->route("admin.servers");
        } catch (\\Throwable $exception) {
            \\Illuminate\\Support\\Facades\\Log::error("KahfiModTzy server delete failed", [
                "server_id" => $server->id,
                "force_delete" => $request->filled("force_delete"),
                "error" => $exception->getMessage(),
            ]);

            $message = $request->filled("force_delete")
                ? "Delete server gagal: " . $exception->getMessage()
                : "Delete server gagal. Jika Node/Wings bermasalah, coba centang Force Delete. Detail: " . $exception->getMessage();

            $this->alert->danger($message)->flash();

            return redirect()->route("admin.servers.view.delete", $server->id);
        }
    }
'''

s3 = re.sub(pattern3, replacement3, s, count=1, flags=re.S)
if s3 == s:
    print('WARNING: method delete tidak ketemu, mungkin sudah berubah. Cek manual ServersController.php')
else:
    s = s3
    print('OK: method delete sudah difix agar tidak 500 polos.')

p.write_text(s)
PY

chown www-data:www-data app/Services/Servers/ServerDeletionService.php app/Http/Controllers/Admin/ServersController.php

php artisan optimize:clear >/dev/null 2>&1 || true
php artisan route:clear >/dev/null 2>&1 || true
php artisan view:clear >/dev/null 2>&1 || true
php artisan config:clear >/dev/null 2>&1 || true
php artisan queue:restart >/dev/null 2>&1 || true

if systemctl list-unit-files | grep -q '^wings.service'; then
  systemctl restart wings || true
fi

echo ""
echo "DONE. Admin utama ID $MAIN_ADMIN_ID sekarang yang boleh delete server."
echo "Admin 2/3 tetap tidak bisa delete server."
echo "Kalau delete normal masih gagal karena Wings/Node, buka halaman Delete lalu centang Force Delete."
