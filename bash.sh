#!/bin/bash
set -e

PANEL_PATH="/var/www/pterodactyl"
BACKUP_DIR="/root/pterodactyl_backups"
TS="$(date -u +%Y-%m-%d-%H-%M-%S)"

if [ ! -d "$PANEL_PATH" ]; then
  echo "ERROR: Folder panel tidak ketemu: $PANEL_PATH"
  exit 1
fi

mkdir -p "$BACKUP_DIR"

echo "== Fix protect delete server ID 1 =="

cd "$PANEL_PATH"

# Backup file penting
[ -f app/Services/Servers/ServerDeletionService.php ] && cp app/Services/Servers/ServerDeletionService.php "$BACKUP_DIR/ServerDeletionService_before_id1_delete_fix_$TS.bak"
[ -f app/Http/Controllers/Admin/ServersController.php ] && cp app/Http/Controllers/Admin/ServersController.php "$BACKUP_DIR/ServersController_before_id1_delete_fix_$TS.bak"
[ -f app/Http/Controllers/Api/Client/Servers/FileController.php ] && cp app/Http/Controllers/Api/Client/Servers/FileController.php "$BACKUP_DIR/FileController_before_id1_delete_fix_$TS.bak"

# 1) ServerDeletionService: hanya user ID 1 yang boleh delete server.
#    Admin ID 1 dibuat force delete otomatis agar tidak 500 saat Wings/node bermasalah.
cat > app/Services/Servers/ServerDeletionService.php <<'PHP'
<?php

namespace Pterodactyl\Services\Servers;

use Illuminate\Http\Response;
use Pterodactyl\Models\Server;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\Log;
use Illuminate\Database\ConnectionInterface;
use Pterodactyl\Exceptions\DisplayException;
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

    public function handle(Server $server): void
    {
        $user = Auth::user();

        // KahfiModTzy Protection:
        // Hanya ADMIN UTAMA panel ID 1 yang boleh delete server.
        // Admin kedua/ketiga dan user biasa tidak boleh delete server.
        if (!$user || (int) $user->id !== 1) {
            throw new DisplayException('KahfiModTzy Protection :: Only admin utama ID 1 can delete servers');
        }

        try {
            $this->daemonServerRepository->setServer($server)->delete();
        } catch (DaemonConnectionException $exception) {
            // Kalau Wings/node offline, admin ID 1 tetap bisa hapus data server dari panel.
            // Ini mencegah 500 polos saat delete server.
            Log::warning($exception);

            if (!$this->force && $exception->getStatusCode() !== Response::HTTP_NOT_FOUND) {
                // Untuk jaga kompatibilitas service, exception tetap bisa dilempar kalau controller tidak force.
                // Controller admin di bawah dipatch agar selalu force untuk ID 1.
                throw $exception;
            }
        }

        $this->connection->transaction(function () use ($server) {
            foreach ($server->databases as $database) {
                try {
                    $this->databaseManagementService->delete($database);
                } catch (\Throwable $exception) {
                    if (!$this->force) {
                        throw $exception;
                    }

                    try {
                        $database->delete();
                    } catch (\Throwable $ignored) {
                        // Abaikan agar force delete admin utama tetap lanjut.
                    }

                    Log::warning($exception);
                }
            }

            $server->delete();
        });
    }
}
PHP

# 2) Patch ServersController tanpa rewrite penuh:
#    - checkAdmin wajib ID 1
#    - method delete dibuat force delete otomatis
php <<'PHP_PATCH'
<?php

$file = '/var/www/pterodactyl/app/Http/Controllers/Admin/ServersController.php';
$s = file_get_contents($file);
if ($s === false) {
    fwrite(STDERR, "ERROR: Tidak bisa baca ServersController.php\n");
    exit(1);
}

function findMethodBlock(string $s, string $methodName): ?array {
    if (!preg_match('/public\s+function\s+' . preg_quote($methodName, '/') . '\s*\([^)]*\)\s*(?::\s*[^{]+)?\s*\{/m', $s, $m, PREG_OFFSET_CAPTURE)) {
        return null;
    }
    $start = $m[0][1];
    $brace = $start + strlen($m[0][0]) - 1;
    $depth = 0;
    $len = strlen($s);
    for ($i = $brace; $i < $len; $i++) {
        $ch = $s[$i];
        if ($ch === '{') $depth++;
        if ($ch === '}') {
            $depth--;
            if ($depth === 0) return [$start, $i + 1];
        }
    }
    return null;
}

function findPrivateMethodBlock(string $s, string $methodName): ?array {
    if (!preg_match('/private\s+function\s+' . preg_quote($methodName, '/') . '\s*\([^)]*\)\s*(?::\s*[^{]+)?\s*\{/m', $s, $m, PREG_OFFSET_CAPTURE)) {
        return null;
    }
    $start = $m[0][1];
    $brace = $start + strlen($m[0][0]) - 1;
    $depth = 0;
    $len = strlen($s);
    for ($i = $brace; $i < $len; $i++) {
        $ch = $s[$i];
        if ($ch === '{') $depth++;
        if ($ch === '}') {
            $depth--;
            if ($depth === 0) return [$start, $i + 1];
        }
    }
    return null;
}

$checkAdmin = <<<'PHP'
    private function checkAdmin(string $action = "access"): void
    {
        $user = Auth::user();

        // KahfiModTzy Protection:
        // Admin utama panel pasti ID 1.
        // Selain ID 1, termasuk admin ke-2/3, tidak boleh akses aksi server penting.
        if (!$user || (int) $user->id !== 1) {
            throw new DisplayException("KahfiModTzy Protection :: Only admin utama ID 1 can {$action} servers");
        }
    }
PHP;

$deleteMethod = <<<'PHP'
    public function delete(Request $request, Server $server): RedirectResponse
    {
        $this->checkAdmin("delete");

        // Force delete otomatis untuk admin utama ID 1.
        // Ini bikin delete tetap jalan walau Wings/node sedang error/offline.
        $this->deletionService->withForce(true)->handle($server);

        $this->alert->success("Server deleted successfully.")->flash();

        return redirect()->route("admin.servers");
    }
PHP;

// Pastikan import Auth dan DisplayException ada.
if (strpos($s, 'use Illuminate\Support\Facades\Auth;') === false) {
    $s = preg_replace('/namespace\s+Pterodactyl\\\\Http\\\\Controllers\\\\Admin;\s*/', "namespace Pterodactyl\\Http\\Controllers\\Admin;\n\nuse Illuminate\\Support\\Facades\\Auth;\n", $s, 1);
}
if (strpos($s, 'use Pterodactyl\Exceptions\DisplayException;') === false) {
    $s = preg_replace('/namespace\s+Pterodactyl\\\\Http\\\\Controllers\\\\Admin;\s*/', "namespace Pterodactyl\\Http\\Controllers\\Admin;\n\nuse Pterodactyl\\Exceptions\\DisplayException;\n", $s, 1);
}

// Patch checkAdmin kalau ada.
$block = findPrivateMethodBlock($s, 'checkAdmin');
if ($block) {
    [$a, $b] = $block;
    $s = substr($s, 0, $a) . $checkAdmin . substr($s, $b);
} else {
    // Sisipkan setelah constructor pertama.
    $pos = strpos($s, "\n    public function index");
    if ($pos === false) {
        fwrite(STDERR, "WARNING: Tidak ketemu posisi checkAdmin. Lewati patch checkAdmin.\n");
    } else {
        $s = substr($s, 0, $pos) . "\n\n" . $checkAdmin . "\n" . substr($s, $pos);
    }
}

// Patch delete method.
$block = findMethodBlock($s, 'delete');
if ($block) {
    [$a, $b] = $block;
    $s = substr($s, 0, $a) . $deleteMethod . substr($s, $b);
} else {
    fwrite(STDERR, "ERROR: Method delete() tidak ketemu di ServersController.php\n");
    exit(1);
}

file_put_contents($file, $s);
echo "OK: ServersController delete dipatch ID 1 + force delete.\n";
PHP_PATCH

# 3) FileController: jangan blokir backup/download SC user.
#    Permission file manager biarkan request bawaan Pterodactyl yang handle.
php <<'PHP_PATCH'
<?php

$file = '/var/www/pterodactyl/app/Http/Controllers/Api/Client/Servers/FileController.php';
if (!is_file($file)) {
    echo "WARNING: FileController.php tidak ketemu, skip.\n";
    exit(0);
}

$s = file_get_contents($file);
if ($s === false) {
    echo "WARNING: Tidak bisa baca FileController.php, skip.\n";
    exit(0);
}

if (!preg_match('/private\s+function\s+checkServerAccess\s*\([^)]*\)\s*(?::\s*[^{]+)?\s*\{/m', $s, $m, PREG_OFFSET_CAPTURE)) {
    echo "INFO: checkServerAccess tidak ketemu, mungkin sudah bawaan panel.\n";
    exit(0);
}

$start = $m[0][1];
$brace = $start + strlen($m[0][0]) - 1;
$depth = 0;
$end = null;
$len = strlen($s);

for ($i = $brace; $i < $len; $i++) {
    $ch = $s[$i];
    if ($ch === '{') $depth++;
    if ($ch === '}') {
        $depth--;
        if ($depth === 0) {
            $end = $i + 1;
            break;
        }
    }
}

if ($end === null) {
    echo "WARNING: Gagal patch checkServerAccess.\n";
    exit(0);
}

$new = <<<'PHP'
    private function checkServerAccess($request, Server $server)
    {
        // Fix backup/download SC:
        // Jangan blokir File Manager dengan protect custom.
        // Permission bawaan Pterodactyl tetap jalan dari request class.
        return;
    }
PHP;

$s = substr($s, 0, $start) . $new . substr($s, $end);
file_put_contents($file, $s);

echo "OK: FileController checkServerAccess dimatikan agar backup/download normal.\n";
PHP_PATCH

chown -R www-data:www-data "$PANEL_PATH"

php artisan optimize:clear >/dev/null 2>&1 || true
php artisan view:clear >/dev/null 2>&1 || true
php artisan route:clear >/dev/null 2>&1 || true
php artisan config:clear >/dev/null 2>&1 || true
php artisan queue:restart >/dev/null 2>&1 || true

if systemctl list-unit-files | grep -q '^wings.service'; then
  systemctl restart wings || true
fi

echo ""
echo "DONE."
echo "Sekarang coba delete server pakai admin utama ID 1."
echo "Admin ke-2/3 tidak bisa delete server."
echo "Backup/download SC user tidak diblokir protect custom."
