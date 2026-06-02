#!/bin/bash
# KahfiModTzy ROOT ONLY SERVER LOCK v3
# Final aturan:
# - Admin utama ID 1 boleh semua.
# - Admin selain ID 1 tetap BOLEH create server manual/bot.
# - Admin selain ID 1 DILARANG akses/intip/modifikasi server: list, detail, manage, install status, suspend, transfer, console, files, startup, build, database, mounts, delete.
# - User biasa tetap boleh akses server miliknya lewat client area seperti Pterodactyl normal.

set -u

PANEL="/var/www/pterodactyl"
BACKUP="/root/pterodactyl_backups"
TS="$(date -u +%Y-%m-%d-%H-%M-%S)"

say(){ echo -e "$1"; }
fail(){ echo -e "ERROR: $1"; exit 1; }

[ -d "$PANEL" ] || fail "Folder panel tidak ketemu: $PANEL"
mkdir -p "$BACKUP"
cd "$PANEL" || exit 1

say "== KAHFIMODTZY ROOT ONLY SERVER LOCK v3 =="
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

backup_file "app/Http/Controllers/Admin/ServersController.php" "Admin_ServersController_before_root_lock_v3"
backup_file "app/Http/Controllers/Admin/Servers/ServerController.php" "Admin_Servers_ServerController_before_root_lock_v3"
backup_file "app/Http/Controllers/Admin/Servers/ServerViewController.php" "Admin_Servers_ServerViewController_before_root_lock_v3"
backup_file "app/Http/Controllers/Admin/Servers/ServerTransferController.php" "Admin_Servers_ServerTransferController_before_root_lock_v3"
backup_file "app/Http/Controllers/Admin/Servers/CreateServerController.php" "Admin_Servers_CreateServerController_before_root_lock_v3"
backup_file "app/Http/Controllers/Api/Client/ClientController.php" "Api_Client_ClientController_before_root_lock_v3"

find app/Http/Controllers/Api/Client/Servers -type f -name '*.php' 2>/dev/null | while read -r f; do
  safe_name="$(echo "$f" | tr '/.' '__')"
  backup_file "$f" "${safe_name}_before_root_lock_v3"
done

find app/Services/Servers -type f \( -iname '*ModificationService.php' -o -iname '*Reinstall*.php' -o -iname '*Suspend*.php' -o -iname '*Suspension*.php' -o -iname '*Deletion*.php' -o -iname '*Transfer*.php' -o -iname '*Database*.php' \) 2>/dev/null | while read -r f; do
  safe_name="$(echo "$f" | tr '/.' '__')"
  backup_file "$f" "${safe_name}_before_root_lock_v3"
done

echo "Patching controller/service..."

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

function kahfi_insert_admin_helper(string $s): string {
    if (strpos($s, 'KAHFI_ROOT_ONLY_SERVER_PANEL_HELPER_V3') !== false) {
        return $s;
    }

    $helper = <<<'PHP'
    // KAHFI_ROOT_ONLY_SERVER_PANEL_HELPER_V3
    private function kahfiRootOnlyServerPanelV3(string $action = 'akses fitur server'): void
    {
        $kahfiUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiUser) {
            try { $kahfiUser = request()->user(); } catch (\Throwable $e) { $kahfiUser = null; }
        }

        if (!$kahfiUser || (int) $kahfiUser->id !== 1) {
            throw new \Pterodactyl\Exceptions\DisplayException('✖ KahfiModTzy Protection :: fitur ini khusus admin utama ID 1. Selain admin utama dilarang ' . $action . '.');
        }
    }
PHP;

    return preg_replace('/(class\s+[^\{]+\{)/m', "$1\n" . $helper . "\n", $s, 1) ?? $s;
}

function kahfi_inject_admin_guard_all_public(string $s, array $skipMethods = []): string {
    $skip = array_fill_keys(array_map('strtolower', $skipMethods), true);

    return preg_replace_callback('/(public\s+function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{)/m', function ($m) use ($skip) {
        $method = $m[2];
        $methodLower = strtolower($method);

        if (isset($skip[$methodLower])) {
            return $m[1];
        }

        // Jangan double-insert kalau script dijalankan ulang dan guard sudah tepat setelah method.
        if (strpos($m[1], 'KAHFI_ROOT_ONLY_SERVER_PANEL_ACTION_V3') !== false) {
            return $m[1];
        }

        $readable = preg_replace('/(?<!^)[A-Z]/', ' $0', $method);
        $readable = strtolower(str_replace('_', ' ', $readable));
        $guard = "\n        // KAHFI_ROOT_ONLY_SERVER_PANEL_ACTION_V3\n        \$this->kahfiRootOnlyServerPanelV3('" . addslashes($readable) . "');";

        return $m[1] . $guard;
    }, $s) ?? $s;
}


function kahfi_open_create_store_if_present(string $s): string {
    // Pastikan create server tetap dibuka untuk admin selain ID 1.
    // Hapus guard lama yang pernah memblokir create/store server.
    $s = preg_replace('/\n\s*\$this->checkAdmin\([\'\"]create[\'\"]\);\s*/i', "\n        // KAHFI v3: admin selain ID 1 tetap boleh create server.\n", $s) ?? $s;
    $s = preg_replace('/\n\s*\/\/[^\n]*(?:create|membuat)[^\n]*\n\s*\$this->kahfi[A-Za-z0-9_]*\([^;]*(?:create|membuat)[^;]*\);\s*/i', "\n        // KAHFI v3: admin selain ID 1 tetap boleh create server.\n", $s) ?? $s;
    $s = preg_replace('/\n\s*\$this->kahfi[A-Za-z0-9_]*\([^;]*(?:create|membuat)[^;]*\);\s*/i', "\n        // KAHFI v3: admin selain ID 1 tetap boleh create server.\n", $s) ?? $s;
    return $s;
}

function kahfi_patch_admin_controller(string $file, array $skipMethods = []): void {
    $s = kahfi_read($file);
    if ($s === null) return;

    $s = kahfi_insert_admin_helper($s);

    if (in_array('create', $skipMethods, true) || in_array('store', $skipMethods, true)) {
        $s = kahfi_open_create_store_if_present($s);
    }

    $s = kahfi_inject_admin_guard_all_public($s, array_merge(['__construct', 'kahfiRootOnlyServerPanelV3'], $skipMethods));

    kahfi_write($file, $s);
}

function kahfi_patch_create_redirect(string $file): void {
    $s = kahfi_read($file);
    if ($s === null) return;

    // Bersihkan guard lama di create/store kalau pernah kepasang dari patch sebelumnya.
    $s = kahfi_open_create_store_if_present($s);

    if (strpos($s, 'KAHFI_CREATE_SERVER_ADMIN2_REDIRECT_V3') !== false) {
        kahfi_write($file, $s);
        echo "Already create redirect patched: {$file}\n";
        return;
    }

    // Setelah admin selain ID 1 create server, jangan lempar ke halaman view/manage server karena memang dikunci.
    $pattern = '/(\$this->alert->success\(trans\([\'\"]admin\/server\.alerts\.server_created[\'\"]\)\)->flash\(\);\s*)return\s+new\s+RedirectResponse\(\s*[\'\"]\/admin\/servers\/view\/[\'\"]\s*\.\s*\$server->id\s*\)\s*;/s';
    $replacement = <<<'PHP'
$1
        // KAHFI_CREATE_SERVER_ADMIN2_REDIRECT_V3
        // Admin selain ID 1 boleh create server, tapi tidak boleh langsung masuk halaman detail/manage server.
        $kahfiUser = \Illuminate\Support\Facades\Auth::user();
        if ($kahfiUser && (int) $kahfiUser->id !== 1) {
            $this->alert->success('Server berhasil dibuat. Akses detail/manage server hanya untuk admin utama ID 1.')->flash();
            return redirect()->route('admin.servers.new');
        }

        return new RedirectResponse('/admin/servers/view/' . $server->id);
PHP;

    $patched = preg_replace($pattern, $replacement, $s, 1, $count);
    if ($patched !== null && $count > 0) {
        kahfi_write($file, $patched);
        return;
    }

    echo "INFO: redirect pattern not found in {$file}, skipped redirect patch.\n";
}

function kahfi_inject_service_guard_all_public(string $s, string $action): string {
    return preg_replace_callback('/(public\s+function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{)/m', function ($m) use ($action) {
        $method = strtolower($m[2]);
        if ($method === '__construct') {
            return $m[1];
        }

        $guard = "\n        // KAHFI_ROOT_ONLY_SERVER_SERVICE_V3\n        \$kahfiUser = \\Illuminate\\Support\\Facades\\Auth::user();\n        if (!\$kahfiUser) {\n            try { \$kahfiUser = request()->user(); } catch (\\Throwable \$e) { \$kahfiUser = null; }\n        }\n\n        if (\$kahfiUser && !empty(\$kahfiUser->root_admin) && (int) \$kahfiUser->id !== 1) {\n            throw new \\Pterodactyl\\Exceptions\\DisplayException('✖ KahfiModTzy Protection :: fitur ini khusus admin utama ID 1. Selain admin utama dilarang " . addslashes($action) . ".');\n        }";

        return $m[1] . $guard;
    }, $s) ?? $s;
}

function kahfi_patch_service_file(string $file): void {
    $s = kahfi_read($file);
    if ($s === null) return;

    if (strpos($s, 'KAHFI_ROOT_ONLY_SERVER_SERVICE_V3') !== false) {
        echo "Already service protected: {$file}\n";
        return;
    }

    $base = basename($file);
    $action = 'memodifikasi server';
    if (stripos($base, 'Startup') !== false) $action = 'mengubah startup server';
    if (stripos($base, 'Build') !== false) $action = 'mengubah RAM CPU disk build server';
    if (stripos($base, 'Details') !== false) $action = 'mengubah detail server';
    if (stripos($base, 'Reinstall') !== false) $action = 'reinstall server';
    if (stripos($base, 'Suspend') !== false || stripos($base, 'Suspension') !== false) $action = 'suspend atau unsuspend server';
    if (stripos($base, 'Delete') !== false || stripos($base, 'Deletion') !== false) $action = 'delete server';
    if (stripos($base, 'Transfer') !== false) $action = 'transfer server';
    if (stripos($base, 'Database') !== false) $action = 'mengubah database server';

    $s = kahfi_inject_service_guard_all_public($s, $action);
    kahfi_write($file, $s);
}

function kahfi_inject_client_guard_all_public(string $s): string {
    return preg_replace_callback('/(public\s+function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{)/m', function ($m) {
        $method = strtolower($m[2]);
        if ($method === '__construct') {
            return $m[1];
        }

        $guard = <<<'PHP'
        // KAHFI_ROOT_ONLY_CLIENT_SERVER_BLOCK_V3
        $kahfiUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiUser) {
            try { $kahfiUser = request()->user(); } catch (\Throwable $e) { $kahfiUser = null; }
        }

        // Admin selain ID 1 dilarang buka/intip server lewat client area/API.
        // User biasa tetap mengikuti permission normal Pterodactyl.
        if ($kahfiUser && !empty($kahfiUser->root_admin) && (int) $kahfiUser->id !== 1) {
            abort(403, '✖ KahfiModTzy Protection :: console, file, power, command, backup, dan client server API khusus admin utama ID 1.');
        }
PHP;
        return $m[1] . "\n" . rtrim($guard);
    }, $s) ?? $s;
}

function kahfi_patch_client_file(string $file): void {
    $s = kahfi_read($file);
    if ($s === null) return;

    if (strpos($s, 'KAHFI_ROOT_ONLY_CLIENT_SERVER_BLOCK_V3') !== false) {
        echo "Already client protected: {$file}\n";
        return;
    }

    $s = kahfi_inject_client_guard_all_public($s);
    kahfi_write($file, $s);
}

// =======================================================
// A. Admin server controllers Pterodactyl baru 1.11/1.12
// =======================================================
// List semua server: wajib root only.
kahfi_patch_admin_controller($panel . '/app/Http/Controllers/Admin/Servers/ServerController.php');

// Semua halaman detail/manage server: wajib root only.
kahfi_patch_admin_controller($panel . '/app/Http/Controllers/Admin/Servers/ServerViewController.php');

// Transfer server: wajib root only.
kahfi_patch_admin_controller($panel . '/app/Http/Controllers/Admin/Servers/ServerTransferController.php');

// Action controller: toggle install, suspension, reinstall, startup, build, database, delete, mounts.
// Kalau panel/fork lama masih punya create/store di file ini, create/store tetap dibuka.
kahfi_patch_admin_controller($panel . '/app/Http/Controllers/Admin/ServersController.php', ['create', 'store']);

// Create server tetap boleh untuk admin selain ID 1, tapi redirect setelah sukses jangan ke halaman detail server yang dikunci.
kahfi_patch_create_redirect($panel . '/app/Http/Controllers/Admin/Servers/CreateServerController.php');

// =======================================================
// B. Service-level guard supaya akses lewat route/API tetap ditolak
// =======================================================
$serviceFiles = [];
$serviceDir = $panel . '/app/Services/Servers';
if (is_dir($serviceDir)) {
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($serviceDir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $info) {
        if (!$info->isFile() || strtolower($info->getExtension()) !== 'php') continue;
        $base = $info->getBasename();
        if (preg_match('/(ModificationService|Reinstall|Suspend|Suspension|Deletion|Delete|Transfer|Database)/i', $base)) {
            // Jangan sentuh ServerCreationService supaya admin kedua tetap bisa create server.
            if (stripos($base, 'Creation') !== false) continue;
            $serviceFiles[] = $info->getPathname();
        }
    }
}
foreach (array_unique($serviceFiles) as $file) {
    kahfi_patch_service_file($file);
}

// =======================================================
// C. Client server API: console, files, power, command, resources, backups
// =======================================================
kahfi_patch_client_file($panel . '/app/Http/Controllers/Api/Client/ClientController.php');

$clientServersDir = $panel . '/app/Http/Controllers/Api/Client/Servers';
if (is_dir($clientServersDir)) {
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($clientServersDir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $info) {
        if (!$info->isFile() || strtolower($info->getExtension()) !== 'php') continue;
        kahfi_patch_client_file($info->getPathname());
    }
}
PHP_PATCH

# Validasi sintaks PHP untuk file yang dipatch.
echo "Checking PHP syntax..."
for f in \
  app/Http/Controllers/Admin/ServersController.php \
  app/Http/Controllers/Admin/Servers/ServerController.php \
  app/Http/Controllers/Admin/Servers/ServerViewController.php \
  app/Http/Controllers/Admin/Servers/ServerTransferController.php \
  app/Http/Controllers/Admin/Servers/CreateServerController.php \
  app/Http/Controllers/Api/Client/ClientController.php
  do
    if [ -f "$f" ]; then php -l "$f" || exit 1; fi
  done

find app/Http/Controllers/Api/Client/Servers -type f -name '*.php' 2>/dev/null | while read -r f; do php -l "$f" || exit 1; done
find app/Services/Servers -type f \( -iname '*ModificationService.php' -o -iname '*Reinstall*.php' -o -iname '*Suspend*.php' -o -iname '*Suspension*.php' -o -iname '*Deletion*.php' -o -iname '*Transfer*.php' -o -iname '*Database*.php' \) 2>/dev/null | while read -r f; do php -l "$f" || exit 1; done

# Bersihkan cache Laravel agar controller/service baru langsung kepakai.
echo "Clearing Laravel cache..."
php artisan optimize:clear >/dev/null 2>&1 || true
php artisan view:clear >/dev/null 2>&1 || true
php artisan route:clear >/dev/null 2>&1 || true
php artisan config:clear >/dev/null 2>&1 || true
php artisan cache:clear >/dev/null 2>&1 || true
php artisan queue:restart >/dev/null 2>&1 || true

chown -R www-data:www-data "$PANEL" >/dev/null 2>&1 || true

echo
echo "DONE ROOT LOCK v3."
echo "Admin utama ID 1: boleh semua."
echo "Admin selain ID 1: BOLEH create server manual/bot, tapi DILARANG list/detail/manage server, toggle install status, suspend, transfer, startup, build, database, mounts, delete, console, files, power, command."
echo
echo "Test wajib: logout admin kedua, login ulang, lalu coba:"
echo "- /admin/servers"
echo "- /admin/servers/view/ID/manage"
echo "- Toggle Install Status"
echo "- Suspend Server"
echo "- Transfer Server"
echo "- /server/identifier console/files"
echo "Semuanya harus 403/protection untuk admin selain ID 1."
