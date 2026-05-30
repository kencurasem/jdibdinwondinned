#!/bin/bash
# Reset + fix delete server Pterodactyl:
# - Admin utama panel ID 1 bisa delete server
# - Admin 2/3/user biasa tidak bisa delete server
# - Download/backup SC tidak diblokir protect FileController
# - Restore controller dari backup clean kalau ada, lalu patch minimal
set -u

PANEL="/var/www/pterodactyl"
BACKUP="/root/pterodactyl_backups"
TS="$(date -u +%Y-%m-%d-%H-%M-%S)"

say(){ echo -e "$1"; }
fail(){ echo -e "ERROR: $1"; exit 1; }

[ -d "$PANEL" ] || fail "Folder panel tidak ketemu: $PANEL"
mkdir -p "$BACKUP"
cd "$PANEL" || exit 1

say "== KAHFI FIX DELETE SERVER FINAL =="
say "Panel: $PANEL"
say "Backup: $BACKUP"
echo

backup_now() {
  local f="$1"
  local n="$2"
  if [ -f "$f" ]; then
    cp "$f" "$BACKUP/${n}_before_final_delete_fix_${TS}.bak"
    echo "Backup: $n"
  fi
}

backup_now "app/Http/Controllers/Admin/ServersController.php" "ServersController"
backup_now "app/Services/Servers/ServerDeletionService.php" "ServerDeletionService"
backup_now "app/Http/Controllers/Api/Client/Servers/FileController.php" "FileController"

# Ambil backup ServersController clean sebelum protect, kalau ada.
RESTORED=0
for f in $(ls -t "$BACKUP"/ServersController_*.bak 2>/dev/null || true); do
  if grep -q "class ServersController" "$f" && ! grep -q "KahfiModTzy" "$f"; then
    cp "$f" "app/Http/Controllers/Admin/ServersController.php"
    echo "Restore clean ServersController dari: $f"
    RESTORED=1
    break
  fi
done

if [ "$RESTORED" = "0" ]; then
  echo "INFO: Backup clean ServersController tidak ketemu, patch file yang ada sekarang."
fi

# Tulis ServerDeletionService yang tegas:
# ID 1 boleh delete, selain ID 1 blok.
# Force daemon/database error agar UI admin ID1 tidak 500 cuma karena Wings/node bermasalah.
cat > app/Services/Servers/ServerDeletionService.php <<'PHP'
<?php

namespace Pterodactyl\Services\Servers;

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

        // FIX FINAL:
        // Admin utama panel = ID 1.
        // Selain ID 1, termasuk admin 2/3, tidak bisa delete server.
        if (!$user || (int) $user->id !== 1) {
            throw new DisplayException('KahfiModTzy Protection :: hanya admin utama ID 1 yang boleh delete server.');
        }

        // Paksa force untuk admin utama ID 1 agar tidak 500 kalau Wings/node lagi error.
        $this->force = true;

        try {
            $this->daemonServerRepository->setServer($server)->delete();
        } catch (DaemonConnectionException $exception) {
            Log::warning($exception);
        } catch (\Throwable $exception) {
            Log::warning($exception);
        }

        $this->connection->transaction(function () use ($server) {
            foreach ($server->databases as $database) {
                try {
                    $this->databaseManagementService->delete($database);
                } catch (\Throwable $exception) {
                    Log::warning($exception);

                    try {
                        $database->delete();
                    } catch (\Throwable $ignored) {
                        Log::warning($ignored);
                    }
                }
            }

            $server->delete();
        });
    }
}
PHP

# Patch controller secara minimal, tanpa rewrite semua fitur.
php <<'PHP_PATCH'
<?php

$file = '/var/www/pterodactyl/app/Http/Controllers/Admin/ServersController.php';
$s = file_get_contents($file);
if ($s === false) {
    fwrite(STDERR, "ERROR: Tidak bisa baca ServersController.php\n");
    exit(1);
}

function addUseIfMissing(string $s, string $use): string {
    if (strpos($s, $use) !== false) return $s;
    return preg_replace('/namespace\s+Pterodactyl\\\\Http\\\\Controllers\\\\Admin;\s*/', "namespace Pterodactyl\\Http\\Controllers\\Admin;\n\n{$use}\n", $s, 1);
}

function findMethod(string $s, string $name): ?array {
    $pattern = '/public\s+function\s+' . preg_quote($name, '/') . '\s*\([^)]*\)\s*(?::\s*[^\\{]+)?\s*\\{/m';
    if (!preg_match($pattern, $s, $m, PREG_OFFSET_CAPTURE)) return null;

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

$s = addUseIfMissing($s, 'use Illuminate\Support\Facades\Auth;');
$s = addUseIfMissing($s, 'use Pterodactyl\Exceptions\DisplayException;');
$s = addUseIfMissing($s, 'use Illuminate\Http\Request;');

$newDelete = <<<'PHP'
    public function delete(Request $request, Server $server): RedirectResponse
    {
        $authUser = Auth::user();

        // FIX FINAL:
        // Admin utama panel = ID 1.
        // Admin 2/3 dan user biasa tidak bisa delete server.
        if (!$authUser || (int) $authUser->id !== 1) {
            throw new DisplayException('KahfiModTzy Protection :: hanya admin utama ID 1 yang boleh delete server.');
        }

        // Force delete otomatis agar admin utama tidak kena 500 saat Wings/node error.
        $this->deletionService->withForce(true)->handle($server);

        $this->alert->success('Server berhasil dihapus.')->flash();

        return redirect()->route('admin.servers');
    }
PHP;

$block = findMethod($s, 'delete');

if (!$block) {
    fwrite(STDERR, "ERROR: Method public function delete(...) tidak ketemu di ServersController.php\n");
    exit(1);
}

[$a, $b] = $block;
$s = substr($s, 0, $a) . $newDelete . substr($s, $b);

file_put_contents($file, $s);
echo "OK: ServersController delete method sudah dipatch.\n";
PHP_PATCH

# FileController: matikan check custom yang bikin backup/download SC error.
php <<'PHP_PATCH'
<?php

$file = '/var/www/pterodactyl/app/Http/Controllers/Api/Client/Servers/FileController.php';
if (!is_file($file)) {
    echo "SKIP: FileController tidak ketemu.\n";
    exit(0);
}

$s = file_get_contents($file);
if ($s === false) {
    echo "SKIP: Tidak bisa baca FileController.\n";
    exit(0);
}

function findPrivateMethod(string $s, string $name): ?array {
    $pattern = '/private\s+function\s+' . preg_quote($name, '/') . '\s*\([^)]*\)\s*(?::\s*[^\\{]+)?\s*\\{/m';
    if (!preg_match($pattern, $s, $m, PREG_OFFSET_CAPTURE)) return null;

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

$block = findPrivateMethod($s, 'checkServerAccess');
if (!$block) {
    echo "INFO: checkServerAccess tidak ada, FileController mungkin sudah bawaan.\n";
    exit(0);
}

$newMethod = <<<'PHP'
    private function checkServerAccess($request, Server $server)
    {
        // FIX: jangan blokir file manager/backup/download dengan protect custom.
        // Permission bawaan Pterodactyl tetap berjalan dari request class.
        return;
    }
PHP;

[$a, $b] = $block;
$s = substr($s, 0, $a) . $newMethod . substr($s, $b);

file_put_contents($file, $s);
echo "OK: FileController checkServerAccess dimatikan.\n";
PHP_PATCH

echo
echo "== CEK SYNTAX PHP =="
php -l app/Services/Servers/ServerDeletionService.php || exit 1
php -l app/Http/Controllers/Admin/ServersController.php || exit 1
[ -f app/Http/Controllers/Api/Client/Servers/FileController.php ] && php -l app/Http/Controllers/Api/Client/Servers/FileController.php || true

echo
echo "== CEK ADMIN ID 1 =="
php artisan tinker --execute='
$u = Pterodactyl\Models\User::find(1);
if (!$u) { echo "WARNING: User ID 1 tidak ada\n"; exit; }
echo "ID=1 USER={$u->username} EMAIL={$u->email} ROOT_ADMIN=" . ((int)$u->root_admin) . PHP_EOL;
' || true

echo
echo "== CLEAR CACHE + RESTART SERVICE =="
chown -R www-data:www-data "$PANEL" || true
php artisan optimize:clear || true
php artisan view:clear || true
php artisan route:clear || true
php artisan config:clear || true
php artisan cache:clear || true
php artisan queue:restart || true

# Restart php-fpm agar opcache tidak pakai file lama.
for svc in $(systemctl list-units --type=service --all | awk '{print $1}' | grep -E '^php[0-9.]+-fpm\.service$' || true); do
  echo "Restart $svc"
  systemctl restart "$svc" || true
done

systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
systemctl restart wings 2>/dev/null || true

echo
echo "DONE."
echo "Sekarang login admin utama ID 1, lalu coba delete server lagi."
echo "Kalau masih gagal, langsung kirim output ini:"
echo "tail -n 80 /var/www/pterodactyl/storage/logs/laravel-*.log"
