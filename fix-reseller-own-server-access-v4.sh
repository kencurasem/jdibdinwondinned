#!/bin/bash
# KahfiModTzy Reseller Own Server Access v4
# Final rule:
# - Admin utama ID 1: full access.
# - Admin 2/3/4/dst: boleh create server manual/bot, create PTLA/PTLC sendiri,
#   dan boleh manage server miliknya sendiri.
# - Admin 2/3/4/dst: dilarang intip/manage server orang lain.
# - Patch ini juga menghapus blocker v3 yang bikin dashboard client blank/error.

set -u

PANEL="${PANEL_PATH:-/var/www/pterodactyl}"
BACKUP="/root/pterodactyl_backups"
TS="$(date -u +%Y-%m-%d-%H-%M-%S)"

say(){ echo -e "$1"; }
fail(){ echo -e "ERROR: $1"; exit 1; }

[ -d "$PANEL" ] || fail "Folder panel tidak ketemu: $PANEL"
mkdir -p "$BACKUP"
cd "$PANEL" || exit 1

say "== KAHFIMODTZY RESELLER OWN SERVER ACCESS v4 =="
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

backup_file "app/Http/Controllers/Admin/ServersController.php" "Admin_ServersController_before_reseller_v4"
backup_file "app/Http/Controllers/Admin/Servers/ServerController.php" "Admin_Servers_ServerController_before_reseller_v4"
backup_file "app/Http/Controllers/Admin/Servers/ServerViewController.php" "Admin_Servers_ServerViewController_before_reseller_v4"
backup_file "app/Http/Controllers/Admin/Servers/ServerTransferController.php" "Admin_Servers_ServerTransferController_before_reseller_v4"
backup_file "app/Http/Controllers/Admin/Servers/CreateServerController.php" "Admin_Servers_CreateServerController_before_reseller_v4"
backup_file "app/Http/Controllers/Api/Client/ClientController.php" "Api_Client_ClientController_before_reseller_v4"

find app/Http/Controllers/Api/Client/Servers -type f -name '*.php' 2>/dev/null | while read -r f; do
  safe_name="$(echo "$f" | tr '/.' '__')"
  backup_file "$f" "${safe_name}_before_reseller_v4"
done

find app/Services/Servers -type f -name '*.php' 2>/dev/null | while read -r f; do
  safe_name="$(echo "$f" | tr '/.' '__')"
  backup_file "$f" "${safe_name}_before_reseller_v4"
done

echo "Patching reseller server access..."

php <<'PHP_PATCH'
<?php
$panel = '/var/www/pterodactyl';

function kahfi_read(string $file): ?string {
    if (!is_file($file)) {
        echo "SKIP not found: {$file}\n";
        return null;
    }
    $s = file_get_contents($file);
    if ($s === false) {
        echo "SKIP unreadable: {$file}\n";
        return null;
    }
    return $s;
}

function kahfi_write(string $file, string $s): void {
    file_put_contents($file, $s);
    echo "Patched: {$file}\n";
}

function kahfi_remove_function_block(string $s, string $functionName): string {
    while (($pos = strpos($s, 'function ' . $functionName)) !== false) {
        $brace = strpos($s, '{', $pos);
        if ($brace === false) break;

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
        if ($end === null) break;

        $start = strrpos(substr($s, 0, $pos), "\n");
        $start = ($start === false) ? 0 : $start + 1;

        // Kalau baris sebelumnya adalah marker komentar, hapus sekalian.
        $before = substr($s, 0, max(0, $start - 1));
        $prevLineStart = strrpos($before, "\n");
        $prevLineStart = ($prevLineStart === false) ? 0 : $prevLineStart + 1;
        $prevLine = substr($s, $prevLineStart, $start - $prevLineStart);
        if (strpos($prevLine, 'KAHFI_ROOT_ONLY_SERVER_PANEL_HELPER_V3') !== false) {
            $start = $prevLineStart;
        }

        $s = substr($s, 0, $start) . "\n" . substr($s, $end);
    }
    return $s;
}

function kahfi_cleanup_old_root_only_v3(string $s): string {
    // Hapus guard client area/API v3 yang memblokir semua admin selain ID 1.
    $s = preg_replace('/\n\s*\/\/ KAHFI_ROOT_ONLY_CLIENT_SERVER_BLOCK_V3[\s\S]*?abort\(403,\s*[\s\S]*?\);\s*\}\s*/m', "\n", $s) ?? $s;

    // Hapus guard service v3 yang memblokir semua admin selain ID 1 dari modify service.
    $s = preg_replace('/\n\s*\/\/ KAHFI_ROOT_ONLY_SERVER_SERVICE_V3[\s\S]*?throw new \\Pterodactyl\\Exceptions\\DisplayException\([\s\S]*?\);\s*\}\s*/m', "\n", $s) ?? $s;

    // Hapus guard action admin panel v3.
    $s = preg_replace('/\n\s*\/\/ KAHFI_ROOT_ONLY_SERVER_PANEL_ACTION_V3\s*\n\s*\$this->kahfiRootOnlyServerPanelV3\([^;]*\);\s*/m', "\n", $s) ?? $s;

    // Hapus helper root-only v3 dengan brace matching agar tidak merusak controller.
    $s = kahfi_remove_function_block($s, 'kahfiRootOnlyServerPanelV3');

    // Hapus redirect khusus admin2 dari create v3 jika pernah kepasang, supaya create server normal lagi.
    $s = preg_replace('/\n\s*\/\/ KAHFI_CREATE_SERVER_ADMIN2_REDIRECT_V3[\s\S]*?return redirect\(\)->route\(\'admin\.servers\.new\'\);\s*}\s*/m', "\n", $s) ?? $s;

    return $s;
}

function kahfi_insert_admin_owner_helper(string $s): string {
    if (strpos($s, 'KAHFI_RESELLER_SERVER_OWNER_HELPER_V4') !== false) {
        return $s;
    }

    $helper = <<<'PHP'
    // KAHFI_RESELLER_SERVER_OWNER_HELPER_V4
    private function kahfiRootOrOwnServerV4($server = null, string $action = 'akses server'): void
    {
        $kahfiUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiUser) {
            try { $kahfiUser = request()->user(); } catch (\Throwable $e) { $kahfiUser = null; }
        }

        if (!$kahfiUser) {
            throw new \Pterodactyl\Exceptions\DisplayException('✖ KahfiModTzy Protection :: akses ditolak.');
        }

        if ((int) $kahfiUser->id === 1) {
            return;
        }

        if ($server && isset($server->owner_id) && (int) $server->owner_id === (int) $kahfiUser->id) {
            return;
        }

        throw new \Pterodactyl\Exceptions\DisplayException('✖ KahfiModTzy Protection :: admin reseller hanya boleh ' . $action . ' miliknya sendiri. Server orang lain dilarang diintip atau dimodifikasi.');
    }

    // KAHFI_RESELLER_SERVER_QUERY_HELPER_V4
    private function kahfiServerBaseQueryV4()
    {
        $query = \Pterodactyl\Models\Server::query();
        $kahfiUser = \Illuminate\Support\Facades\Auth::user();
        if ($kahfiUser && (int) $kahfiUser->id !== 1) {
            $query->where('servers.owner_id', (int) $kahfiUser->id);
        }
        return $query;
    }
PHP;

    return preg_replace('/(class\s+[^\{]+\{)/m', "$1\n" . $helper . "\n", $s, 1) ?? $s;
}

function kahfi_patch_admin_controller(string $file): void {
    $s = kahfi_read($file);
    if ($s === null) return;

    $s = kahfi_cleanup_old_root_only_v3($s);
    $s = kahfi_insert_admin_owner_helper($s);

    // Untuk halaman list server di admin panel, admin reseller hanya melihat server miliknya sendiri.
    $s = str_replace('Server::query()', '$this->kahfiServerBaseQueryV4()', $s);

    // Bersihkan kemungkinan helper ikut kepatch oleh str_replace.
    $s = str_replace('\\Pterodactyl\\Models\\$this->kahfiServerBaseQueryV4()', '\\Pterodactyl\\Models\\Server::query()', $s);

    // Method yang mempunyai parameter Server $server: root boleh semua, reseller hanya server miliknya.
    $s = preg_replace_callback('/(public\s+function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*(?::\s*[^\{]+)?\s*\{)/m', function ($m) {
        $method = strtolower($m[2]);
        $params = $m[3];
        if (in_array($method, ['__construct', 'create', 'store'], true)) {
            return $m[1];
        }

        if (strpos($params, '$server') === false) {
            return $m[1];
        }

        if (preg_match('/(Server|\\\\Pterodactyl\\\\Models\\\\Server)\s+\$server/', $params)) {
            return $m[1] . "\n        // KAHFI_RESELLER_OWN_SERVER_ACTION_V4\n        \$this->kahfiRootOrOwnServerV4(\$server, 'mengakses atau mengubah server');";
        }

        // Beberapa controller lama memakai int $server.
        if (preg_match('/int\s+\$server/', $params)) {
            return $m[1] . "\n        // KAHFI_RESELLER_OWN_SERVER_INT_ACTION_V4\n        \$kahfiTargetServerV4 = \\Pterodactyl\\Models\\Server::query()->findOrFail(\$server);\n        \$this->kahfiRootOrOwnServerV4(\$kahfiTargetServerV4, 'mengakses atau mengubah server');";
        }

        return $m[1];
    }, $s) ?? $s;

    // Create server tetap dibuka. Hapus sisa guard root-only yang biasanya nempel di create/store.
    $s = preg_replace('/\n\s*\$this->checkAdmin\([\'\"]create[\'\"]\);\s*/i', "\n        // KAHFI v4: admin reseller tetap boleh create server.\n", $s) ?? $s;
    $s = preg_replace('/\n\s*\$this->kahfiRootOrOwnServerV4\([^;]*(create|membuat)[^;]*\);\s*/i', "\n        // KAHFI v4: admin reseller tetap boleh create server.\n", $s) ?? $s;

    kahfi_write($file, $s);
}

function kahfi_patch_client_controller(string $file): void {
    $s = kahfi_read($file);
    if ($s === null) return;

    $s = kahfi_cleanup_old_root_only_v3($s);

    // Helper filter list server client area: reseller admin hanya lihat server miliknya sendiri.
    if (strpos($s, 'KAHFI_CLIENT_RESELLER_QUERY_HELPER_V4') === false) {
        $helper = <<<'PHP'
    // KAHFI_CLIENT_RESELLER_QUERY_HELPER_V4
    private function kahfiClientServerBaseQueryV4()
    {
        $query = \Pterodactyl\Models\Server::query();
        $kahfiUser = \Illuminate\Support\Facades\Auth::user();
        if ($kahfiUser && !empty($kahfiUser->root_admin) && (int) $kahfiUser->id !== 1) {
            $query->where('servers.owner_id', (int) $kahfiUser->id);
        }
        return $query;
    }
PHP;
        $s = preg_replace('/(class\s+[^\{]+\{)/m', "$1\n" . $helper . "\n", $s, 1) ?? $s;
    }

    $s = str_replace('Server::query()', '$this->kahfiClientServerBaseQueryV4()', $s);
    $s = str_replace('\\Pterodactyl\\Models\\$this->kahfiClientServerBaseQueryV4()', '\\Pterodactyl\\Models\\Server::query()', $s);

    kahfi_write($file, $s);
}

function kahfi_patch_client_server_file(string $file): void {
    $s = kahfi_read($file);
    if ($s === null) return;

    $s = kahfi_cleanup_old_root_only_v3($s);

    if (strpos($s, 'KAHFI_CLIENT_RESELLER_OWN_SERVER_GUARD_V4') === false) {
        $s = preg_replace_callback('/(public\s+function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*(?::\s*[^\{]+)?\s*\{)/m', function ($m) {
            $method = strtolower($m[2]);
            $params = $m[3];
            if ($method === '__construct') {
                return $m[1];
            }
            if (!preg_match('/(Server|\\\\Pterodactyl\\\\Models\\\\Server)\s+\$server/', $params)) {
                return $m[1];
            }
            $guard = <<<'PHP'
        // KAHFI_CLIENT_RESELLER_OWN_SERVER_GUARD_V4
        $kahfiUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiUser) {
            try { $kahfiUser = request()->user(); } catch (\Throwable $e) { $kahfiUser = null; }
        }
        if ($kahfiUser && !empty($kahfiUser->root_admin) && (int) $kahfiUser->id !== 1) {
            if ((int) $server->owner_id !== (int) $kahfiUser->id) {
                abort(403, '✖ KahfiModTzy Protection :: admin reseller hanya boleh akses console/file/API server miliknya sendiri.');
            }
        }
PHP;
            return $m[1] . "\n" . rtrim($guard);
        }, $s) ?? $s;
    }

    kahfi_write($file, $s);
}

function kahfi_patch_service_file(string $file): void {
    $s = kahfi_read($file);
    if ($s === null) return;

    $s = kahfi_cleanup_old_root_only_v3($s);

    if (strpos($s, 'KAHFI_RESELLER_OWN_SERVER_SERVICE_V4') === false) {
        $s = preg_replace_callback('/(public\s+function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*(?::\s*[^\{]+)?\s*\{)/m', function ($m) {
            $method = strtolower($m[2]);
            $params = $m[3];
            if ($method === '__construct') {
                return $m[1];
            }
            if (strpos($params, '$server') === false) {
                return $m[1];
            }

            $guard = <<<'PHP'
        // KAHFI_RESELLER_OWN_SERVER_SERVICE_V4
        $kahfiUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiUser) {
            try { $kahfiUser = request()->user(); } catch (\Throwable $e) { $kahfiUser = null; }
        }
        if ($kahfiUser && !empty($kahfiUser->root_admin) && (int) $kahfiUser->id !== 1) {
            if (!isset($server) || !isset($server->owner_id) || (int) $server->owner_id !== (int) $kahfiUser->id) {
                throw new \Pterodactyl\Exceptions\DisplayException('✖ KahfiModTzy Protection :: admin reseller hanya boleh memodifikasi server miliknya sendiri.');
            }
        }
PHP;
            return $m[1] . "\n" . rtrim($guard);
        }, $s) ?? $s;
    }

    kahfi_write($file, $s);
}

// A. Admin controllers: create tetap bisa, akses server dibatasi root atau owner.
$adminFiles = [
    $panel . '/app/Http/Controllers/Admin/ServersController.php',
    $panel . '/app/Http/Controllers/Admin/Servers/ServerController.php',
    $panel . '/app/Http/Controllers/Admin/Servers/ServerViewController.php',
    $panel . '/app/Http/Controllers/Admin/Servers/ServerTransferController.php',
];
foreach ($adminFiles as $file) {
    kahfi_patch_admin_controller($file);
}

// Create server controller: hapus redirect aneh v3, biar create server normal lagi.
$createFile = $panel . '/app/Http/Controllers/Admin/Servers/CreateServerController.php';
$s = kahfi_read($createFile);
if ($s !== null) {
    $s = kahfi_cleanup_old_root_only_v3($s);
    kahfi_write($createFile, $s);
}

// B. Client area/API: hilangkan blokir total, ganti jadi own-server-only untuk admin reseller.
kahfi_patch_client_controller($panel . '/app/Http/Controllers/Api/Client/ClientController.php');
$clientDir = $panel . '/app/Http/Controllers/Api/Client/Servers';
if (is_dir($clientDir)) {
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($clientDir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $info) {
        if (!$info->isFile() || strtolower($info->getExtension()) !== 'php') continue;
        kahfi_patch_client_server_file($info->getPathname());
    }
}

// C. Service level: modifikasi server boleh untuk root atau owner server saja.
$serviceDir = $panel . '/app/Services/Servers';
if (is_dir($serviceDir)) {
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($serviceDir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $info) {
        if (!$info->isFile() || strtolower($info->getExtension()) !== 'php') continue;
        $base = $info->getBasename();
        if (preg_match('/(ModificationService|Reinstall|Suspend|Suspension|Deletion|Delete|Transfer|Database)/i', $base)) {
            if (stripos($base, 'Creation') !== false) continue;
            kahfi_patch_service_file($info->getPathname());
        }
    }
}
PHP_PATCH

echo "Checking PHP syntax..."
FILES_TO_CHECK=(
  "app/Http/Controllers/Admin/ServersController.php"
  "app/Http/Controllers/Admin/Servers/ServerController.php"
  "app/Http/Controllers/Admin/Servers/ServerViewController.php"
  "app/Http/Controllers/Admin/Servers/ServerTransferController.php"
  "app/Http/Controllers/Admin/Servers/CreateServerController.php"
  "app/Http/Controllers/Api/Client/ClientController.php"
)

for f in "${FILES_TO_CHECK[@]}"; do
  if [ -f "$f" ]; then php -l "$f" || exit 1; fi
done

find app/Http/Controllers/Api/Client/Servers -type f -name '*.php' 2>/dev/null | while read -r f; do php -l "$f" || exit 1; done
find app/Services/Servers -type f -name '*.php' 2>/dev/null | while read -r f; do php -l "$f" || exit 1; done

echo "Clearing Laravel cache..."
php artisan optimize:clear >/dev/null 2>&1 || true
php artisan view:clear >/dev/null 2>&1 || true
php artisan route:clear >/dev/null 2>&1 || true
php artisan config:clear >/dev/null 2>&1 || true
php artisan cache:clear >/dev/null 2>&1 || true
php artisan queue:restart >/dev/null 2>&1 || true

chown -R www-data:www-data "$PANEL" >/dev/null 2>&1 || true

echo
echo "DONE RESELLER OWN SERVER ACCESS v4."
echo "Admin utama ID 1: full akses."
echo "Admin selain ID 1: boleh create server manual/bot, boleh akses dan manage server miliknya sendiri."
echo "Admin selain ID 1: dilarang intip/manage server orang lain."
echo "Dashboard client tidak lagi diblokir total oleh error merah v3."
echo
echo "Test: logout admin reseller lalu login ulang."
echo "- Server milik sendiri: console/files/power/startup harus bisa."
echo "- Server orang lain: harus 403/protection."
echo "- Create server manual dan bot tetap bisa."
