#!/bin/bash
# KahfiModTzy FINAL SERVER LOCK
# Tujuan:
# - Admin utama ID 1 boleh semua.
# - Admin selain ID 1 tetap BOLEH create server manual/bot.
# - Admin selain ID 1 DILARANG lihat/intip server, console, file, startup, build, manage, delete, dan modifikasi server.
# - User biasa tetap bisa akses server miliknya sendiri.

set -u

PANEL="/var/www/pterodactyl"
BACKUP="/root/pterodactyl_backups"
TS="$(date -u +%Y-%m-%d-%H-%M-%S)"

say(){ echo -e "$1"; }
fail(){ echo -e "ERROR: $1"; exit 1; }

[ -d "$PANEL" ] || fail "Folder panel tidak ketemu: $PANEL"
mkdir -p "$BACKUP"
cd "$PANEL" || exit 1

say "== KAHFIMODTZY FINAL SERVER ACCESS LOCK =="
say "Panel  : $PANEL"
say "Backup : $BACKUP"
say "Waktu  : $TS"
echo

backup_file(){
  local f="$1"
  local n="$2"
  if [ -f "$f" ]; then
    cp "$f" "$BACKUP/${n}_${TS}.bak"
    echo "Backup: $n"
  fi
}

backup_file "app/Http/Controllers/Admin/ServersController.php" "ServersController_before_final_root_lock"
backup_file "app/Services/Servers/DetailsModificationService.php" "DetailsModificationService_before_final_root_lock"
backup_file "app/Services/Servers/BuildModificationService.php" "BuildModificationService_before_final_root_lock"
backup_file "app/Services/Servers/StartupModificationService.php" "StartupModificationService_before_final_root_lock"
backup_file "app/Services/Servers/ReinstallServerService.php" "ReinstallServerService_before_final_root_lock"
backup_file "app/Services/Servers/SuspendServerService.php" "SuspendServerService_before_final_root_lock"
backup_file "app/Services/Servers/UnsuspendServerService.php" "UnsuspendServerService_before_final_root_lock"
backup_file "app/Services/Servers/ServerDeletionService.php" "ServerDeletionService_before_final_root_lock"

echo "Patch controller & service..."

php <<'PHP_PATCH'
<?php
$panel = '/var/www/pterodactyl';

function read_file_or_skip(string $file): ?string {
    if (!is_file($file)) {
        echo "SKIP not found: $file\n";
        return null;
    }
    $s = file_get_contents($file);
    if ($s === false) {
        echo "SKIP unreadable: $file\n";
        return null;
    }
    return $s;
}

function write_file(string $file, string $s): void {
    file_put_contents($file, $s);
    echo "Patched: $file\n";
}

function add_use_if_missing(string $s, string $useLine): string {
    if (strpos($s, $useLine) !== false) return $s;
    return preg_replace('/namespace\s+[^;]+;\s*/', "$0\n$useLine\n", $s, 1);
}

function insert_method_after_class_open(string $s, string $methodCode, string $marker): string {
    if (strpos($s, $marker) !== false) return $s;
    return preg_replace('/class\s+\w+\s+extends\s+[^\{]+\{/', "$0\n" . $methodCode . "\n", $s, 1);
}

function insert_guard_in_method(string $s, string $method, string $guard): string {
    $pattern = '/(public\s+function\s+' . preg_quote($method, '/') . '\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{)(?!\s*\n\s*\/\/ KAHFI_FINAL_ROOT_ONLY_SERVER)/m';
    $s2 = preg_replace($pattern, "$1\n" . rtrim($guard) . "\n", $s, 1, $count);
    if ($s2 !== null && $count > 0) return $s2;
    return $s;
}

function remove_root_guard_from_create_store(string $s): string {
    // Buka lagi create server untuk admin 2/3/dst.
    $patterns = [
        '/\n\s*\$this->checkAdmin\(["\']create["\']\);\s*/',
        '/\n\s*\$this->kahfiRootOnly\(["\'][^"\']*create[^"\']*["\']\);\s*/i',
        '/\n\s*\$this->kahfiRootOnlyServer\(["\'][^"\']*create[^"\']*["\']\);\s*/i',
        '/\n\s*\$this->kahfiRootOnly\(["\'][^"\']*membuat[^"\']*["\']\);\s*/i',
        '/\n\s*\$this->kahfiRootOnlyServer\(["\'][^"\']*membuat[^"\']*["\']\);\s*/i',
    ];
    foreach ($patterns as $p) {
        $s = preg_replace($p, "\n        // KAHFI FINAL: admin selain ID 1 tetap boleh create server.\n", $s) ?? $s;
    }
    return $s;
}

// =============================
// 1) Admin ServersController
// =============================
$serversController = $panel . '/app/Http/Controllers/Admin/ServersController.php';
$s = read_file_or_skip($serversController);
if ($s !== null) {
    $s = add_use_if_missing($s, 'use Illuminate\Support\Facades\Auth;');
    $s = add_use_if_missing($s, 'use Pterodactyl\Exceptions\DisplayException;');

    $helper = <<<'PHP'
    // KAHFI_FINAL_ROOT_ONLY_SERVER helper
    private function kahfiRootOnlyServer(string $action = 'akses server'): void
    {
        $kahfiUser = Auth::user();
        if (!$kahfiUser) {
            try { $kahfiUser = request()->user(); } catch (\Throwable $e) { $kahfiUser = null; }
        }

        if (!$kahfiUser || (int) $kahfiUser->id !== 1) {
            throw new DisplayException('✖ KahfiModTzy Protection :: selain admin utama ID 1 dilarang ' . $action . '.');
        }
    }
PHP;
    $s = insert_method_after_class_open($s, $helper, 'KAHFI_FINAL_ROOT_ONLY_SERVER helper');

    // Jangan blokir create/store server. Admin kedua wajib bisa create server.
    $s = remove_root_guard_from_create_store($s);

    $guardMap = [
        'index' => 'melihat daftar server',
        'view' => 'melihat detail server',
        'viewDetails' => 'melihat detail server',
        'viewBuild' => 'melihat build/resource server',
        'viewStartup' => 'melihat startup server',
        'viewDatabase' => 'melihat database server',
        'viewManage' => 'manage server',
        'viewDelete' => 'membuka halaman delete server',
        'setDetails' => 'mengubah detail server',
        'setContainer' => 'mengubah container/image server',
        'updateBuild' => 'mengubah RAM/CPU/disk/build server',
        'saveStartup' => 'mengubah startup server',
        'addDatabase' => 'menambah database server',
        'resetDatabasePassword' => 'reset password database server',
        'deleteDatabase' => 'menghapus database server',
        'manageSuspend' => 'suspend/unsuspend server',
        'manageReinstall' => 'reinstall server',
        'delete' => 'delete server',
    ];

    foreach ($guardMap as $method => $action) {
        $guard = "        // KAHFI_FINAL_ROOT_ONLY_SERVER\n        \$this->kahfiRootOnlyServer('" . addslashes($action) . "');";
        $s = insert_guard_in_method($s, $method, $guard);
    }

    // Pastikan create() dan store() tidak mengandung guard final root-only.
    foreach (['create', 'store'] as $m) {
        $s = preg_replace_callback('/(public\s+function\s+' . $m . '\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{)(.*?)(\n\s*\})/s', function($mm) {
            $body = $mm[2];
            $body = preg_replace('/\n\s*\/\/ KAHFI_FINAL_ROOT_ONLY_SERVER\s*\n\s*\$this->kahfiRootOnlyServer\([^;]+;/', "", $body) ?? $body;
            $body = preg_replace('/\n\s*\$this->checkAdmin\(["\']create["\']\);/', "\n        // KAHFI FINAL: admin selain ID 1 tetap boleh create server.", $body) ?? $body;
            return $mm[1] . $body . $mm[3];
        }, $s, 1) ?? $s;
    }

    write_file($serversController, $s);
}

// =============================
// 2) Service-level modification guard
// =============================
$serviceFiles = [
    $panel . '/app/Services/Servers/DetailsModificationService.php' => 'mengubah detail server',
    $panel . '/app/Services/Servers/BuildModificationService.php' => 'mengubah resource/build server',
    $panel . '/app/Services/Servers/StartupModificationService.php' => 'mengubah startup server',
    $panel . '/app/Services/Servers/ReinstallServerService.php' => 'reinstall server',
    $panel . '/app/Services/Servers/SuspendServerService.php' => 'suspend server',
    $panel . '/app/Services/Servers/UnsuspendServerService.php' => 'unsuspend server',
    $panel . '/app/Services/Servers/ServerDeletionService.php' => 'delete server',
];

foreach ($serviceFiles as $file => $action) {
    $s = read_file_or_skip($file);
    if ($s === null) continue;

    $s = add_use_if_missing($s, 'use Pterodactyl\Exceptions\DisplayException;');

    $guard = "        // KAHFI_FINAL_SERVICE_ROOT_ONLY\n        \$kahfiUser = \\Illuminate\\Support\\Facades\\Auth::user();\n        if (!\$kahfiUser) {\n            try { \$kahfiUser = request()->user(); } catch (\\Throwable \$e) { \$kahfiUser = null; }\n        }\n\n        if (\$kahfiUser && !empty(\$kahfiUser->root_admin) && (int) \$kahfiUser->id !== 1) {\n            throw new DisplayException('✖ KahfiModTzy Protection :: selain admin utama ID 1 dilarang $action.');\n        }";

    if (strpos($s, 'KAHFI_FINAL_SERVICE_ROOT_ONLY') === false) {
        $s = preg_replace('/(public\s+function\s+handle\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{)/m', "$1\n" . rtrim($guard) . "\n", $s, 1) ?? $s;
    }

    write_file($file, $s);
}

// =============================
// 3) Client API Server controllers: block admin2/3/dst from console/files/etc.
// Normal non-admin owner tetap bisa akses server miliknya.
// =============================
$clientDir = $panel . '/app/Http/Controllers/Api/Client/Servers';
if (is_dir($clientDir)) {
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($clientDir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $info) {
        if (!$info->isFile() || strtolower($info->getExtension()) !== 'php') continue;
        $file = $info->getPathname();
        $s = read_file_or_skip($file);
        if ($s === null) continue;
        if (strpos($s, 'Server $server') === false && strpos($s, 'Server $') === false) continue;
        if (strpos($s, 'KAHFI_FINAL_CLIENT_ADMIN_BLOCK') !== false) {
            echo "Already client protected: $file\n";
            continue;
        }

        $clientGuard = <<<'PHP'
        // KAHFI_FINAL_CLIENT_ADMIN_BLOCK
        $kahfiUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiUser) {
            try { $kahfiUser = request()->user(); } catch (\Throwable $e) { $kahfiUser = null; }
        }

        // Admin selain ID 1 dilarang intip console/file/server lewat client route/API.
        // User biasa tetap boleh akses server miliknya melalui permission normal Pterodactyl.
        if ($kahfiUser && !empty($kahfiUser->root_admin) && (int) $kahfiUser->id !== 1) {
            abort(403, '✖ KahfiModTzy Protection :: selain admin utama ID 1 dilarang membuka console/file/server.');
        }
PHP;

        $pattern = '/(public\s+function\s+\w+\s*\([^)]*Server\s+\$server[^)]*\)\s*(?::\s*[^\{]+)?\s*\{)/m';
        $patched = preg_replace($pattern, "$1\n" . rtrim($clientGuard) . "\n", $s, -1, $count);
        if ($patched !== null && $count > 0) {
            write_file($file, $patched);
        }
    }
}
PHP_PATCH

# Bersihkan cache Laravel agar controller/service baru kepakai.
echo "Clearing Laravel cache..."
php artisan optimize:clear >/dev/null 2>&1 || true
php artisan view:clear >/dev/null 2>&1 || true
php artisan route:clear >/dev/null 2>&1 || true
php artisan config:clear >/dev/null 2>&1 || true
php artisan cache:clear >/dev/null 2>&1 || true
php artisan queue:restart >/dev/null 2>&1 || true

# Permission normal.
chown -R www-data:www-data "$PANEL" >/dev/null 2>&1 || true

echo
echo "DONE. Aturan final:"
echo "- Admin utama ID 1 boleh semua."
echo "- Admin selain ID 1 boleh create server manual/bot."
echo "- Admin selain ID 1 tidak boleh lihat daftar/detail server, console, file, startup, build, manage, delete, atau modifikasi server."
echo "- User biasa tetap akses server miliknya seperti normal."
echo
echo "Test: login admin kedua, coba buka Admin > Servers, console, Files, Startup. Harus 403/Protection."
