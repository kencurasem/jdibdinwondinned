#!/bin/bash
# KahfiModTzy FINAL fix for Pterodactyl Files/Download/Backup unexpected error.
# Fokus:
# - Restore controller client server/files/backups dari backup clean kalau tersedia.
# - Kalau backup clean tidak ada, matikan protect owner_id custom yang memblokir akses file/backup.
# - Set semua server minimal backup_limit agar tombol Create Backup bisa dipakai.
# - Clear cache + restart PHP-FPM/Nginx/Wings.

set -u

PANEL="/var/www/pterodactyl"
BACKUP="/root/pterodactyl_backups"
TS="$(date -u +%Y-%m-%d-%H-%M-%S)"
MIN_BACKUP_LIMIT="${MIN_BACKUP_LIMIT:-3}"

say(){ echo -e "$1"; }
fail(){ echo -e "ERROR: $1"; exit 1; }

[ -d "$PANEL" ] || fail "Folder panel tidak ketemu: $PANEL"
mkdir -p "$BACKUP"
cd "$PANEL" || exit 1

say "== KAHFI FINAL FIX FILES + DOWNLOAD + BACKUP =="
say "Panel            : $PANEL"
say "Backup folder    : $BACKUP"
say "Min backup limit : $MIN_BACKUP_LIMIT"
echo

backup_now() {
  local f="$1"
  local n="$2"
  if [ -f "$f" ]; then
    cp "$f" "$BACKUP/${n}_before_files_backup_final_${TS}.bak"
    echo "Backup file sekarang: $n"
  fi
}

backup_now "app/Http/Controllers/Api/Client/Servers/FileController.php" "FileController"
backup_now "app/Http/Controllers/Api/Client/Servers/ServerController.php" "ClientServerController"
backup_now "app/Http/Controllers/Api/Client/Servers/BackupController.php" "BackupController"
backup_now "app/Http/Requests/Api/Client/Servers/Files/ListFilesRequest.php" "ListFilesRequest"
backup_now "app/Http/Requests/Api/Client/Servers/Backups/StoreBackupRequest.php" "StoreBackupRequest"

echo
say "== RESTORE CLEAN BACKUP JIKA ADA =="

restore_clean() {
  local target="$1"
  local label="$2"
  local pattern="$3"
  local restored=0

  for f in $(ls -t "$BACKUP"/${pattern}_*.bak 2>/dev/null || true); do
    if grep -q "class ${label}" "$f" && ! grep -q "KahfiModTzy" "$f"; then
      cp "$f" "$target"
      echo "OK: Restore clean $label dari $f"
      restored=1
      break
    fi
  done

  if [ "$restored" = "0" ]; then
    echo "INFO: Clean backup $label tidak ketemu, lanjut patch file sekarang."
  fi
}

restore_clean "app/Http/Controllers/Api/Client/Servers/FileController.php" "FileController" "FileController"
restore_clean "app/Http/Controllers/Api/Client/Servers/ServerController.php" "ServerController" "ServerController"
restore_clean "app/Http/Controllers/Api/Client/Servers/BackupController.php" "BackupController" "BackupController"

echo
say "== PATCH CONTROLLER CLIENT AGAR PAKAI PERMISSION BAWAAN PTERODACTYL =="

# 1) FileController: no-op custom check + pastikan semua call tidak bikin error.
php <<'PHP_PATCH'
<?php
$file = '/var/www/pterodactyl/app/Http/Controllers/Api/Client/Servers/FileController.php';
if (!is_file($file)) { echo "SKIP: FileController tidak ketemu.\n"; exit(0); }
$s = file_get_contents($file);
if ($s === false) { echo "SKIP: Tidak bisa baca FileController.\n"; exit(0); }

function find_method_block_fc(string $s, string $visibility, string $name): ?array {
    $pattern = '/' . preg_quote($visibility, '/') . '\s+function\s+' . preg_quote($name, '/') . '\s*\([^)]*\)\s*(?::\s*[^\\{]+)?\s*\\{/m';
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

$block = find_method_block_fc($s, 'private', 'checkServerAccess');
$newMethod = <<<'PHP'
    private function checkServerAccess($request, Server $server)
    {
        // FIX FINAL:
        // Jangan pakai owner_id custom protect di FileController.
        // Permission bawaan Pterodactyl dari request class tetap aktif.
        // Ini mengizinkan owner/subuser berizin untuk Files, Download, Compress, Pull, Delete, dll.
        return;
    }
PHP;

if ($block) {
    [$a, $b] = $block;
    $s = substr($s, 0, $a) . $newMethod . substr($s, $b);
    echo "OK: FileController checkServerAccess dibuat no-op.\n";
} else {
    echo "INFO: checkServerAccess tidak ada di FileController.\n";
}

// Jaga-jaga kalau ada abort custom yang disisipkan langsung di method file.
$s = preg_replace('/\n\s*if\s*\([^\n{}]*owner_id[^{}]*\)\s*\{\s*abort\(403,[^;]+;\s*\}/m', "\n        // removed custom owner_id abort by final fix", $s) ?? $s;

file_put_contents($file, $s);
PHP_PATCH

# 2) Client ServerController: buang custom owner_id check supaya subuser/owner sah tidak kena 403.
php <<'PHP_PATCH'
<?php
$file = '/var/www/pterodactyl/app/Http/Controllers/Api/Client/Servers/ServerController.php';
if (!is_file($file)) { echo "SKIP: Client ServerController tidak ketemu.\n"; exit(0); }
$s = file_get_contents($file);
if ($s === false) { echo "SKIP: Tidak bisa baca Client ServerController.\n"; exit(0); }

function add_use_sc(string $s, string $use): string {
    if (strpos($s, $use) !== false) return $s;
    return preg_replace('/namespace\s+[^;]+;\s*/', "$0\n" . $use . "\n", $s, 1) ?? $s;
}
function find_method_block_sc(string $s, string $name): ?array {
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

$s = add_use_sc($s, 'use Pterodactyl\\Models\\Server;');
$s = add_use_sc($s, 'use Pterodactyl\\Transformers\\Api\\Client\\ServerTransformer;');
$s = add_use_sc($s, 'use Pterodactyl\\Services\\Servers\\GetUserPermissionsService;');
$s = add_use_sc($s, 'use Pterodactyl\\Http\\Requests\\Api\\Client\\Servers\\GetServerRequest;');

$block = find_method_block_sc($s, 'index');
$newMethod = <<<'PHP'
    public function index(GetServerRequest $request, Server $server): array
    {
        // FIX FINAL:
        // Jangan cek owner_id manual di sini.
        // GetServerRequest bawaan Pterodactyl sudah memastikan hanya user yang punya akses server yang lolos.
        // Ini penting untuk fitur Files/Backups milik user sendiri dan subuser yang punya permission.
        return $this->fractal->item($server)
            ->transformWith($this->getTransformer(ServerTransformer::class))
            ->addMeta([
                'is_server_owner' => $request->user()->id === $server->owner_id,
                'user_permissions' => $this->permissionsService->handle($server, $request->user()),
            ])
            ->toArray();
    }
PHP;

if ($block) {
    [$a, $b] = $block;
    $s = substr($s, 0, $a) . $newMethod . substr($s, $b);
    echo "OK: Client ServerController index dipatch ke permission bawaan.\n";
} else {
    echo "INFO: Method index tidak ada di Client ServerController.\n";
}

// Hapus import Auth kalau cuma dari protect lama; tidak wajib, tapi aman dibiarkan juga.
file_put_contents($file, $s);
PHP_PATCH

# 3) BackupController: tidak overwrite penuh, hanya hapus custom owner_id abort kalau ada.
php <<'PHP_PATCH'
<?php
$file = '/var/www/pterodactyl/app/Http/Controllers/Api/Client/Servers/BackupController.php';
if (!is_file($file)) { echo "SKIP: BackupController tidak ketemu.\n"; exit(0); }
$s = file_get_contents($file);
if ($s === false) { echo "SKIP: Tidak bisa baca BackupController.\n"; exit(0); }
$before = $s;

// Buang pola protect custom yang sering bikin backup user sendiri kena 403.
$s = preg_replace('/\n\s*\$authUser\s*=\s*[^;]+;\s*\n\s*if\s*\([^\n{}]*owner_id[^{}]*\)\s*\{\s*abort\(403,[^;]+;\s*\}/m', "\n        // removed custom owner_id backup abort by final fix", $s) ?? $s;
$s = preg_replace('/\n\s*if\s*\([^\n{}]*owner_id[^{}]*\)\s*\{\s*abort\(403,[^;]+;\s*\}/m', "\n        // removed custom owner_id backup abort by final fix", $s) ?? $s;

if ($s !== $before) echo "OK: BackupController custom owner_id abort dibuang.\n";
else echo "INFO: BackupController tidak ada custom owner_id abort.\n";

file_put_contents($file, $s);
PHP_PATCH

echo
say "== SET SEMUA SERVER BISA CREATE BACKUP =="
# Buat semua server minimal bisa punya backup, supaya tombol Create Backup tidak gagal karena limit 0.
php artisan tinker --execute="
try {
    \Pterodactyl\Models\Server::query()->where('backup_limit', '<', (int) ${MIN_BACKUP_LIMIT})->update(['backup_limit' => (int) ${MIN_BACKUP_LIMIT}]);
    echo 'OK: Semua server sekarang backup_limit minimal ${MIN_BACKUP_LIMIT}' . PHP_EOL;
} catch (Throwable \$e) {
    echo 'WARNING: Gagal update backup_limit: ' . \$e->getMessage() . PHP_EOL;
}
" || true

echo
say "== CEK SYNTAX PHP =="
php -l app/Http/Controllers/Api/Client/Servers/FileController.php || exit 1
php -l app/Http/Controllers/Api/Client/Servers/ServerController.php || exit 1
[ -f app/Http/Controllers/Api/Client/Servers/BackupController.php ] && php -l app/Http/Controllers/Api/Client/Servers/BackupController.php || true

echo
say "== CLEAR CACHE + RESTART SERVICE =="
chown -R www-data:www-data "$PANEL" || true
php artisan optimize:clear || true
php artisan view:clear || true
php artisan route:clear || true
php artisan config:clear || true
php artisan cache:clear || true
php artisan queue:restart || true

for svc in $(systemctl list-units --type=service --all | awk '{print $1}' | grep -E '^php[0-9.]+-fpm\.service$' || true); do
  echo "Restart $svc"
  systemctl restart "$svc" || true
done

systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
systemctl restart wings 2>/dev/null || true

echo
say "== TEST CEPAT LOG TERAKHIR =="
php artisan route:clear >/dev/null 2>&1 || true
ls -1 storage/logs/laravel-*.log 2>/dev/null | tail -n 1 | xargs -r tail -n 5 || true

echo
say "DONE FINAL."
echo "Coba hard refresh / logout-login lalu test:"
echo "1) Files > klik file > Download"
echo "2) Files > pilih file/folder > Archive/Compress"
echo "3) Backups > Create Backup"
echo
cat <<'MSG'
Kalau MASIH merah, kirim output command ini supaya ketahuan error aslinya:
cd /var/www/pterodactyl && tail -n 160 storage/logs/laravel-*.log
MSG
