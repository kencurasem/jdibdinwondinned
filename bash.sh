#!/usr/bin/env bash
set -euo pipefail

PANEL_PATH="/var/www/pterodactyl"
BACKUP_ROOT="/root/pterodactyl_backups"
STAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_DIR="$BACKUP_ROOT/delete_server_fix_v3_$STAMP"

if [ ! -d "$PANEL_PATH" ]; then
  echo "ERROR: Folder panel tidak ketemu: $PANEL_PATH"
  exit 1
fi

cd "$PANEL_PATH"
mkdir -p "$BACKUP_DIR"

echo "=== DAFTAR ADMIN PANEL PTERODACTYL ==="
php artisan tinker --execute='foreach (\Pterodactyl\Models\User::where("root_admin", 1)->orderBy("id")->get(["id","username","email"]) as $u) { echo "ID=".$u->id." | USER=".$u->username." | EMAIL=".$u->email.PHP_EOL; }' || true

echo ""
if [ "${1:-}" != "" ]; then
  MAIN_ADMIN_ID="$1"
else
  read -rp "Masukkan ID akun PANEL admin utama yang boleh delete server: " MAIN_ADMIN_ID
fi

if ! [[ "$MAIN_ADMIN_ID" =~ ^[0-9]+$ ]]; then
  echo "ERROR: ID harus angka ID akun PANEL, bukan ID Telegram. Contoh biasanya: 1"
  exit 1
fi

echo "Admin utama yang boleh delete server: ID $MAIN_ADMIN_ID"
echo "Backup disimpan ke: $BACKUP_DIR"

backup_file() {
  local f="$1"
  if [ -f "$f" ]; then
    mkdir -p "$BACKUP_DIR/$(dirname "$f")"
    cp -a "$f" "$BACKUP_DIR/$f"
    echo "Backup: $f"
  fi
}

# 1) Fix FileController: jangan blokir download/backup file manager.
FILE_CONTROLLER="app/Http/Controllers/Api/Client/Servers/FileController.php"
if [ -f "$FILE_CONTROLLER" ]; then
  backup_file "$FILE_CONTROLLER"
  php <<'PHP_PATCH'
<?php
$file = 'app/Http/Controllers/Api/Client/Servers/FileController.php';
$s = file_get_contents($file);
if ($s === false) { fwrite(STDERR, "Gagal baca FileController\n"); exit(1); }

$pattern = '/\/\*\*\s*\n\s*\* KahfiModTzy Protection :: File Access Security\s*\n\s*\*\/\s*\n\s*private function checkServerAccess\(\$request, Server \$server\)\s*\{.*?\n\s*\}\s*\n\s*public function directory/s';
$replacement = <<<'REP'
/**
     * File access uses native Pterodactyl request permissions.
     * This prevents backup/download errors for normal users.
     */
    private function checkServerAccess($request, Server $server)
    {
        return;
    }

    public function directory
REP;

$new = preg_replace($pattern, $replacement, $s, 1, $count);
if ($new === null) { fwrite(STDERR, "Regex FileController error\n"); exit(1); }
if ($count > 0) {
    file_put_contents($file, $new);
    echo "OK: FileController fixed, download/backup tidak diblokir protect.\n";
} else {
    echo "INFO: Block protect FileController tidak ketemu / sudah difix.\n";
}
PHP_PATCH
  php -l "$FILE_CONTROLLER" >/dev/null
fi

# 2) Patch Admin ServersController: admin utama pakai ID yang benar, bukan selalu ID 1.
SERVERS_CONTROLLER="app/Http/Controllers/Admin/ServersController.php"
if [ -f "$SERVERS_CONTROLLER" ]; then
  backup_file "$SERVERS_CONTROLLER"
  MAIN_ADMIN_ID="$MAIN_ADMIN_ID" php <<'PHP_PATCH'
<?php
$file = 'app/Http/Controllers/Admin/ServersController.php';
$main = (int) getenv('MAIN_ADMIN_ID');
$s = file_get_contents($file);
if ($s === false) { fwrite(STDERR, "Gagal baca ServersController\n"); exit(1); }

// Ganti cek lama yang hardcode ID 1 menjadi ID admin utama yang diinput.
$s = str_replace('if (!$user || $user->id !== 1) {', 'if (!$user || (int) $user->id !== '.$main.') {', $s);
$s = str_replace('if (!$user || (int) $user->id !== 1) {', 'if (!$user || (int) $user->id !== '.$main.') {', $s);
$s = str_replace('if (!$user || $user->id != 1) {', 'if (!$user || (int) $user->id !== '.$main.') {', $s);
$s = str_replace('if (!$user || (int) $user->id != 1) {', 'if (!$user || (int) $user->id !== '.$main.') {', $s);

file_put_contents($file, $s);
echo "OK: ServersController admin delete/checkAdmin pakai ID {$main}.\n";
PHP_PATCH
  php -l "$SERVERS_CONTROLLER" >/dev/null
fi

# 3) Overwrite ServerDeletionService: hanya admin utama yang boleh delete server.
SERVER_DELETION="app/Services/Servers/ServerDeletionService.php"
if [ -f "$SERVER_DELETION" ]; then
  backup_file "$SERVER_DELETION"
fi

cat > /tmp/ServerDeletionService.php <<'PHP_SERVICE'
<?php

namespace Pterodactyl\Services\Servers;

use Illuminate\Support\Facades\Auth;
use Pterodactyl\Exceptions\DisplayException;
use Illuminate\Http\Response;
use Pterodactyl\Models\Server;
use Illuminate\Support\Facades\Log;
use Illuminate\Database\ConnectionInterface;
use Pterodactyl\Repositories\Wings\DaemonServerRepository;
use Pterodactyl\Services\Databases\DatabaseManagementService;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;

class ServerDeletionService
{
    protected bool $force = false;

    private int $mainAdminId = __MAIN_ADMIN_ID__;

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

        if (!$user) {
            try {
                $user = request()->user();
            } catch (\Throwable $e) {
                $user = null;
            }
        }

        // Hanya admin utama panel yang boleh delete server.
        // Admin ke-2/3/root_admin lain tetap tidak boleh delete.
        if (!$user || (int) $user->id !== $this->mainAdminId) {
            throw new DisplayException('KahfiModTzy Protection :: Hanya Admin Utama yang boleh delete server');
        }

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
PHP_SERVICE

sed -i "s/__MAIN_ADMIN_ID__/$MAIN_ADMIN_ID/g" /tmp/ServerDeletionService.php
php -l /tmp/ServerDeletionService.php >/dev/null
cp /tmp/ServerDeletionService.php "$SERVER_DELETION"
chown www-data:www-data "$SERVER_DELETION" 2>/dev/null || true

echo "OK: ServerDeletionService fixed. Admin utama ID $MAIN_ADMIN_ID bisa delete, admin lain tidak."

# 4) Clear cache.
chown -R www-data:www-data "$PANEL_PATH" 2>/dev/null || true
php artisan optimize:clear >/dev/null 2>&1 || true
php artisan view:clear >/dev/null 2>&1 || true
php artisan route:clear >/dev/null 2>&1 || true
php artisan config:clear >/dev/null 2>&1 || true
php artisan cache:clear >/dev/null 2>&1 || true
php artisan queue:restart >/dev/null 2>&1 || true

echo "DONE. Coba delete server lagi dari akun admin utama. Kalau Wings/Node error, centang Force Delete."
echo "Jangan jalankan bash protect lama lagi, nanti fix ini ketimpa."
