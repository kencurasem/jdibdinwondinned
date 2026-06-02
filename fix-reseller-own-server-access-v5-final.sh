#!/bin/bash
# KahfiModTzy Reseller Own Server Access v5 FINAL
# Rule final:
# - Admin utama ID 1: full akses semua.
# - Admin reseller selain ID 1: boleh create server manual/bot, create PTLA/PTLC sendiri,
#   dan boleh buka/manage server miliknya sendiri.
# - Admin reseller selain ID 1: dilarang intip/manage server orang lain.
# - Fix utama: hapus blocker root-only lama yang bikin /server/<id> milik sendiri tetap 403.

set -u

PANEL="${PANEL_PATH:-/var/www/pterodactyl}"
BACKUP="/root/pterodactyl_backups"
TS="$(date -u +%Y-%m-%d-%H-%M-%S)"

say(){ echo -e "$1"; }
fail(){ echo -e "ERROR: $1"; exit 1; }

[ -d "$PANEL" ] || fail "Folder panel tidak ketemu: $PANEL"
mkdir -p "$BACKUP"
cd "$PANEL" || exit 1

say "== KAHFIMODTZY RESELLER OWN SERVER ACCESS v5 FINAL =="
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

backup_file "app/Http/Controllers/Admin/ServersController.php" "Admin_ServersController_before_reseller_v5"
backup_file "app/Http/Controllers/Admin/Servers/ServerController.php" "Admin_Servers_ServerController_before_reseller_v5"
backup_file "app/Http/Controllers/Admin/Servers/ServerViewController.php" "Admin_Servers_ServerViewController_before_reseller_v5"
backup_file "app/Http/Controllers/Admin/Servers/ServerTransferController.php" "Admin_Servers_ServerTransferController_before_reseller_v5"
backup_file "app/Http/Controllers/Admin/Servers/CreateServerController.php" "Admin_Servers_CreateServerController_before_reseller_v5"
backup_file "app/Http/Controllers/Api/Client/ClientController.php" "Api_Client_ClientController_before_reseller_v5"
backup_file "app/Services/Servers/ServerCreationService.php" "ServerCreationService_before_reseller_v5"

find app/Http/Controllers/Api/Client/Servers -type f -name '*.php' 2>/dev/null | while read -r f; do
  safe_name="$(echo "$f" | tr '/.' '__')"
  backup_file "$f" "${safe_name}_before_reseller_v5"
done

find app/Services/Servers -type f -name '*.php' 2>/dev/null | while read -r f; do
  safe_name="$(echo "$f" | tr '/.' '__')"
  backup_file "$f" "${safe_name}_before_reseller_v5"
done

echo "Patching root-only blocker -> own-server-only..."

PANEL_PATH="$PANEL" php <<'PHP_PATCH'
<?php
$panel = getenv('PANEL_PATH') ?: '/var/www/pterodactyl';

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

function kahfi_add_use(string $s, string $useLine): string {
    if (strpos($s, $useLine) !== false) return $s;
    return preg_replace('/namespace\s+[^;]+;\s*/', "$0\n{$useLine}\n", $s, 1) ?? $s;
}

function kahfi_remove_marked_guard(string $s, string $marker, array $terminals): string {
    while (($pos = strpos($s, $marker)) !== false) {
        $start = strrpos(substr($s, 0, $pos), "\n");
        $start = ($start === false) ? 0 : $start + 1;

        $termPos = false;
        foreach ($terminals as $needle) {
            $p = strpos($s, $needle, $pos);
            if ($p !== false && ($termPos === false || $p < $termPos)) {
                $termPos = $p;
            }
        }

        if ($termPos === false) {
            // Fallback: hapus satu baris marker saja agar tidak loop.
            $lineEnd = strpos($s, "\n", $pos);
            if ($lineEnd === false) $lineEnd = strlen($s);
            $s = substr($s, 0, $start) . substr($s, $lineEnd + 1);
            continue;
        }

        $close = strpos($s, "\n", strpos($s, "}", $termPos));
        if ($close === false) {
            $close = strpos($s, "}", $termPos);
            $close = ($close === false) ? strlen($s) : $close + 1;
        } else {
            $close += 1;
        }

        $s = substr($s, 0, $start) . substr($s, $close);
    }
    return $s;
}

function kahfi_cleanup_all_old_blocks(string $s): string {
    $markers = [
        'KAHFI_FINAL_CLIENT_ADMIN_BLOCK' => ['abort(403'],
        'KAHFI_ROOT_ONLY_CLIENT_SERVER_BLOCK_V3' => ['abort(403'],
        'KAHFI_CLIENT_RESELLER_OWN_SERVER_GUARD_V4' => ['abort(403'],
        'KAHFI_FINAL_SERVICE_ROOT_ONLY' => ['throw new DisplayException', 'throw new \\Pterodactyl\\Exceptions\\DisplayException'],
        'KAHFI_ROOT_ONLY_SERVER_SERVICE_V3' => ['throw new DisplayException', 'throw new \\Pterodactyl\\Exceptions\\DisplayException'],
        'KAHFI_RESELLER_OWN_SERVER_SERVICE_V4' => ['throw new DisplayException', 'throw new \\Pterodactyl\\Exceptions\\DisplayException'],
        'KAHFI_RESELLER_OWN_SERVER_ACTION_V4' => ['$this->kahfiRootOrOwnServerV4'],
        'KAHFI_RESELLER_OWN_SERVER_INT_ACTION_V4' => ['$this->kahfiRootOrOwnServerV4'],
        'KAHFI_ROOT_ONLY_SERVER_PANEL_ACTION_V3' => ['$this->kahfiRootOnlyServerPanelV3'],
        'KAHFI_FINAL_ROOT_ONLY_SERVER' => ['$this->kahfiRootOnlyServer'],
    ];

    foreach ($markers as $marker => $terminals) {
        $s = kahfi_remove_marked_guard($s, $marker, $terminals);
    }

    // Hapus call guard root-only satu baris yang mungkin tidak punya marker.
    $s = preg_replace('/\n\s*\$this->kahfiRootOnlyServer\([^;]*\);\s*/m', "\n", $s) ?? $s;
    $s = preg_replace('/\n\s*\$this->kahfiRootOnlyServerPanelV3\([^;]*\);\s*/m', "\n", $s) ?? $s;
    $s = preg_replace('/\n\s*\$this->checkAdmin\(["\']create["\']\);\s*/mi', "\n        // KAHFI v5: reseller admin tetap boleh create server.\n", $s) ?? $s;

    // Hapus method helper lama root-only/v4 kalau ada, supaya tidak bentrok.
    foreach (['kahfiRootOnlyServer', 'kahfiRootOnlyServerPanelV3', 'kahfiRootOrOwnServerV4', 'kahfiServerBaseQueryV4', 'kahfiClientServerBaseQueryV4'] as $fn) {
        $s = kahfi_remove_function($s, $fn);
    }

    return $s;
}

function kahfi_remove_function(string $s, string $functionName): string {
    while (($pos = strpos($s, 'function ' . $functionName)) !== false) {
        $brace = strpos($s, '{', $pos);
        if ($brace === false) break;
        $depth = 0;
        $end = null;
        $len = strlen($s);
        for ($i = $brace; $i < $len; $i++) {
            if ($s[$i] === '{') $depth++;
            if ($s[$i] === '}') {
                $depth--;
                if ($depth === 0) { $end = $i + 1; break; }
            }
        }
        if ($end === null) break;
        $start = strrpos(substr($s, 0, $pos), "\n");
        $start = ($start === false) ? 0 : $start + 1;
        $s = substr($s, 0, $start) . "\n" . substr($s, $end);
    }
    return $s;
}

function kahfi_insert_after_class_open(string $s, string $code, string $marker): string {
    if (strpos($s, $marker) !== false) return $s;
    return preg_replace('/(class\s+[^\{]+\{)/m', "$1\n" . rtrim($code) . "\n", $s, 1) ?? $s;
}

function kahfi_owner_expr_code(): string {
    return <<<'PHP'
        $kahfiDescV5 = (string) ($server->description ?? '');
        $kahfiOwnerOkV5 = isset($server->owner_id) && (int) $server->owner_id === (int) $kahfiUser->id;
        $kahfiCreatorOkV5 = false;
        foreach ([
            'KAHFI_RESELLER_CREATOR_ID=',
            'created_by_admin_id=',
            'creator_id=',
            'telegram_creator_id=',
            'admin_creator_id=',
        ] as $kahfiNeedleV5) {
            if (strpos($kahfiDescV5, $kahfiNeedleV5 . (string) $kahfiUser->id) !== false) {
                $kahfiCreatorOkV5 = true;
                break;
            }
        }
PHP;
}

function kahfi_client_guard_code(): string {
    return <<<'PHP'
        // KAHFI_RESELLER_OWN_SERVER_GUARD_V5
        $kahfiUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiUser) {
            try { $kahfiUser = request()->user(); } catch (\Throwable $e) { $kahfiUser = null; }
        }
        if ($kahfiUser && !empty($kahfiUser->root_admin) && (int) $kahfiUser->id !== 1) {
PHP
        . kahfi_owner_expr_code() . <<<'PHP'
            if (!$kahfiOwnerOkV5 && !$kahfiCreatorOkV5) {
                abort(403, '✖ KahfiModTzy Protection :: admin reseller hanya boleh membuka console/file/server miliknya sendiri.');
            }
        }
PHP;
}

function kahfi_service_guard_code(string $action = 'memodifikasi server'): string {
    return "        // KAHFI_RESELLER_OWN_SERVER_SERVICE_V5\n        \$kahfiUser = \\Illuminate\\Support\\Facades\\Auth::user();\n        if (!\$kahfiUser) {\n            try { \$kahfiUser = request()->user(); } catch (\\Throwable \$e) { \$kahfiUser = null; }\n        }\n        if (\$kahfiUser && !empty(\$kahfiUser->root_admin) && (int) \$kahfiUser->id !== 1) {\n" . kahfi_owner_expr_code() . "            if (!\$kahfiOwnerOkV5 && !\$kahfiCreatorOkV5) {\n                throw new \\Pterodactyl\\Exceptions\\DisplayException('✖ KahfiModTzy Protection :: admin reseller hanya boleh {$action} miliknya sendiri.');\n            }\n        }";
}

function kahfi_patch_methods_with_server_param(string $s, string $guard): string {
    return preg_replace_callback('/(public\s+function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*(?::\s*[^\{]+)?\s*\{)/m', function($m) use ($guard) {
        $method = strtolower($m[2]);
        $params = $m[3];
        if ($method === '__construct') return $m[1];
        if (!preg_match('/(Server|\\\\Pterodactyl\\\\Models\\\\Server)\s+\$server/', $params)) return $m[1];
        return $m[1] . "\n" . rtrim($guard) . "\n";
    }, $s) ?? $s;
}

function kahfi_patch_client_server_file(string $file): void {
    $s = kahfi_read($file);
    if ($s === null) return;
    $s = kahfi_cleanup_all_old_blocks($s);

    if (strpos($s, 'KAHFI_RESELLER_OWN_SERVER_GUARD_V5') === false) {
        $s = kahfi_patch_methods_with_server_param($s, kahfi_client_guard_code());
    }

    // Kalau ada helper checkServerAccess lama, longgarkan untuk admin reseller owner/creator.
    if (strpos($s, 'private function checkServerAccess') !== false && strpos($s, 'KAHFI_RESELLER_CHECK_SERVER_ACCESS_V5') === false) {
        $s = preg_replace_callback('/(private\s+function\s+checkServerAccess\s*\([^)]*\)\s*\{)([\s\S]*?)(\n\s*\}\s*\n\s*public\s+function)/m', function($m) {
            $body = <<<'PHP'
        // KAHFI_RESELLER_CHECK_SERVER_ACCESS_V5
        $user = $request->user();
        if (!$user) {
            abort(403, '✖ KahfiModTzy Protection :: akses server ditolak.');
        }
        if ((int) $user->id === 1) {
            return;
        }

        $kahfiDescV5 = (string) ($server->description ?? '');
        $kahfiOwnerOkV5 = isset($server->owner_id) && (int) $server->owner_id === (int) $user->id;
        $kahfiCreatorOkV5 = false;
        foreach (['KAHFI_RESELLER_CREATOR_ID=', 'created_by_admin_id=', 'creator_id=', 'telegram_creator_id=', 'admin_creator_id='] as $kahfiNeedleV5) {
            if (strpos($kahfiDescV5, $kahfiNeedleV5 . (string) $user->id) !== false) {
                $kahfiCreatorOkV5 = true;
                break;
            }
        }

        if (!$kahfiOwnerOkV5 && !$kahfiCreatorOkV5) {
            abort(403, '✖ KahfiModTzy Protection :: file access hanya untuk server milik sendiri.');
        }
PHP;
            return $m[1] . "\n" . $body . $m[3];
        }, $s, 1) ?? $s;
    }

    kahfi_write($file, $s);
}

function kahfi_patch_client_index_controller(string $file): void {
    $s = kahfi_read($file);
    if ($s === null) return;
    $s = kahfi_cleanup_all_old_blocks($s);

    // Filter query list server untuk admin reseller: hanya owner/created marker.
    if (strpos($s, 'KAHFI_CLIENT_RESELLER_QUERY_HELPER_V5') === false) {
        $helper = <<<'PHP'
    // KAHFI_CLIENT_RESELLER_QUERY_HELPER_V5
    private function kahfiClientServerBaseQueryV5()
    {
        $query = \Pterodactyl\Models\Server::query();
        $kahfiUser = \Illuminate\Support\Facades\Auth::user();
        if ($kahfiUser && !empty($kahfiUser->root_admin) && (int) $kahfiUser->id !== 1) {
            $id = (int) $kahfiUser->id;
            $query->where(function ($q) use ($id) {
                $q->where('servers.owner_id', $id)
                    ->orWhere('servers.description', 'like', '%KAHFI_RESELLER_CREATOR_ID=' . $id . '%')
                    ->orWhere('servers.description', 'like', '%created_by_admin_id=' . $id . '%')
                    ->orWhere('servers.description', 'like', '%creator_id=' . $id . '%')
                    ->orWhere('servers.description', 'like', '%admin_creator_id=' . $id . '%');
            });
        }
        return $query;
    }
PHP;
        $s = kahfi_insert_after_class_open($s, $helper, 'KAHFI_CLIENT_RESELLER_QUERY_HELPER_V5');
    }

    $s = str_replace('Server::query()', '$this->kahfiClientServerBaseQueryV5()', $s);
    $s = str_replace('\\Pterodactyl\\Models\\$this->kahfiClientServerBaseQueryV5()', '\\Pterodactyl\\Models\\Server::query()', $s);
    $s = str_replace('\\Pterodactyl\\Models\\$this->kahfiClientServerBaseQueryV5()', '\\Pterodactyl\\Models\\Server::query()', $s);

    kahfi_write($file, $s);
}

function kahfi_admin_helper_code(): string {
    return <<<'PHP'
    // KAHFI_RESELLER_ADMIN_SERVER_HELPER_V5
    private function kahfiRootOrOwnServerV5($server = null, string $action = 'akses server'): void
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
        if (!$server) {
            throw new \Pterodactyl\Exceptions\DisplayException('✖ KahfiModTzy Protection :: admin reseller hanya boleh ' . $action . ' miliknya sendiri.');
        }

        $kahfiDescV5 = (string) ($server->description ?? '');
        $kahfiOwnerOkV5 = isset($server->owner_id) && (int) $server->owner_id === (int) $kahfiUser->id;
        $kahfiCreatorOkV5 = false;
        foreach (['KAHFI_RESELLER_CREATOR_ID=', 'created_by_admin_id=', 'creator_id=', 'telegram_creator_id=', 'admin_creator_id='] as $kahfiNeedleV5) {
            if (strpos($kahfiDescV5, $kahfiNeedleV5 . (string) $kahfiUser->id) !== false) {
                $kahfiCreatorOkV5 = true;
                break;
            }
        }

        if (!$kahfiOwnerOkV5 && !$kahfiCreatorOkV5) {
            throw new \Pterodactyl\Exceptions\DisplayException('✖ KahfiModTzy Protection :: admin reseller hanya boleh ' . $action . ' miliknya sendiri. Server orang lain dilarang.');
        }
    }

    // KAHFI_RESELLER_ADMIN_SERVER_QUERY_HELPER_V5
    private function kahfiServerBaseQueryV5()
    {
        $query = \Pterodactyl\Models\Server::query();
        $kahfiUser = \Illuminate\Support\Facades\Auth::user();
        if ($kahfiUser && (int) $kahfiUser->id !== 1) {
            $id = (int) $kahfiUser->id;
            $query->where(function ($q) use ($id) {
                $q->where('servers.owner_id', $id)
                    ->orWhere('servers.description', 'like', '%KAHFI_RESELLER_CREATOR_ID=' . $id . '%')
                    ->orWhere('servers.description', 'like', '%created_by_admin_id=' . $id . '%')
                    ->orWhere('servers.description', 'like', '%creator_id=' . $id . '%')
                    ->orWhere('servers.description', 'like', '%admin_creator_id=' . $id . '%');
            });
        }
        return $query;
    }
PHP;
}

function kahfi_patch_admin_server_controller(string $file): void {
    $s = kahfi_read($file);
    if ($s === null) return;

    $s = kahfi_cleanup_all_old_blocks($s);
    $s = kahfi_add_use($s, 'use Illuminate\Support\Facades\Auth;');
    $s = kahfi_add_use($s, 'use Pterodactyl\Exceptions\DisplayException;');
    $s = kahfi_insert_after_class_open($s, kahfi_admin_helper_code(), 'KAHFI_RESELLER_ADMIN_SERVER_HELPER_V5');

    // Admin server list: reseller hanya lihat server milik/created dia.
    $s = str_replace('Server::query()', '$this->kahfiServerBaseQueryV5()', $s);
    $s = str_replace('\\Pterodactyl\\Models\\$this->kahfiServerBaseQueryV5()', '\\Pterodactyl\\Models\\Server::query()', $s);

    if (strpos($s, 'KAHFI_RESELLER_ADMIN_OWN_SERVER_ACTION_V5') === false) {
        $s = preg_replace_callback('/(public\s+function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*(?::\s*[^\{]+)?\s*\{)/m', function($m) {
            $method = strtolower($m[2]);
            $params = $m[3];
            if (in_array($method, ['__construct', 'create', 'store'], true)) return $m[1];

            if (preg_match('/(Server|\\\\Pterodactyl\\\\Models\\\\Server)\s+\$server/', $params)) {
                return $m[1] . "\n        // KAHFI_RESELLER_ADMIN_OWN_SERVER_ACTION_V5\n        \$this->kahfiRootOrOwnServerV5(\$server, 'mengakses/mengubah server');";
            }
            if (preg_match('/int\s+\$server/', $params)) {
                return $m[1] . "\n        // KAHFI_RESELLER_ADMIN_OWN_SERVER_ACTION_V5\n        \$kahfiTargetServerV5 = \\Pterodactyl\\Models\\Server::query()->findOrFail(\$server);\n        \$this->kahfiRootOrOwnServerV5(\$kahfiTargetServerV5, 'mengakses/mengubah server');";
            }
            return $m[1];
        }, $s) ?? $s;
    }

    // Create/store server wajib tetap bebas untuk admin reseller.
    foreach (['create', 'store'] as $m) {
        $s = preg_replace_callback('/(public\s+function\s+' . $m . '\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{)([\s\S]*?)(\n\s*\})/m', function($mm) {
            $body = $mm[2];
            $body = preg_replace('/\n\s*\/\/ KAHFI_RESELLER_ADMIN_OWN_SERVER_ACTION_V5\s*\n\s*[^\n]*kahfiRootOrOwnServerV5[^;]*;/', "\n", $body) ?? $body;
            $body = preg_replace('/\n\s*\$this->checkAdmin\(["\']create["\']\);/', "\n        // KAHFI v5: reseller admin tetap boleh create server.", $body) ?? $body;
            return $mm[1] . $body . $mm[3];
        }, $s, 1) ?? $s;
    }

    kahfi_write($file, $s);
}

function kahfi_patch_service_file(string $file): void {
    $s = kahfi_read($file);
    if ($s === null) return;
    $s = kahfi_cleanup_all_old_blocks($s);

    if (strpos($s, 'KAHFI_RESELLER_OWN_SERVER_SERVICE_V5') === false) {
        $s = preg_replace_callback('/(public\s+function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*(?::\s*[^\{]+)?\s*\{)/m', function($m) {
            $method = strtolower($m[2]);
            $params = $m[3];
            if ($method === '__construct') return $m[1];
            if (!preg_match('/(Server|\\\\Pterodactyl\\\\Models\\\\Server)\s+\$server/', $params)) return $m[1];
            return $m[1] . "\n" . kahfi_service_guard_code('memodifikasi server') . "\n";
        }, $s) ?? $s;
    }
    kahfi_write($file, $s);
}

function kahfi_patch_creation_service(string $file): void {
    $s = kahfi_read($file);
    if ($s === null) return;
    if (strpos($s, 'KAHFI_RESELLER_CREATOR_MARKER_V5') !== false) return;

    $marker = <<<'PHP'
        // KAHFI_RESELLER_CREATOR_MARKER_V5
        // Server yang dibuat oleh admin reseller diberi tanda creator supaya bisa dibedakan dari server orang lain.
        $kahfiCreatorV5 = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiCreatorV5) {
            try { $kahfiCreatorV5 = request()->user(); } catch (\Throwable $e) { $kahfiCreatorV5 = null; }
        }
        if ($kahfiCreatorV5 && !empty($kahfiCreatorV5->root_admin) && (int) $kahfiCreatorV5->id !== 1 && isset($data) && is_array($data)) {
            $kahfiOldDescV5 = trim((string) ($data['description'] ?? ''));
            if (strpos($kahfiOldDescV5, 'KAHFI_RESELLER_CREATOR_ID=') === false) {
                $kahfiAddDescV5 = "KAHFI_RESELLER_CREATOR_ID=" . $kahfiCreatorV5->id
                    . "\nKAHFI_RESELLER_CREATOR_EMAIL=" . ($kahfiCreatorV5->email ?? '-')
                    . "\nKAHFI_RESELLER_CREATED_AT=" . date('Y-m-d H:i:s');
                $data['description'] = trim($kahfiOldDescV5 . "\n" . $kahfiAddDescV5);
            }
        }
PHP;

    $s = preg_replace('/(public\s+function\s+handle\s*\([^)]*\)\s*(?::\s*[^\{]+)?\s*\{)/m', "$1\n" . rtrim($marker) . "\n", $s, 1) ?? $s;
    kahfi_write($file, $s);
}

// 1. Client controller list dan client server endpoints.
kahfi_patch_client_index_controller($panel . '/app/Http/Controllers/Api/Client/ClientController.php');
$clientDir = $panel . '/app/Http/Controllers/Api/Client/Servers';
if (is_dir($clientDir)) {
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($clientDir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $info) {
        if ($info->isFile() && strtolower($info->getExtension()) === 'php') {
            kahfi_patch_client_server_file($info->getPathname());
        }
    }
}

// 2. Admin server controllers: reseller boleh own-server, bukan server orang.
foreach ([
    $panel . '/app/Http/Controllers/Admin/ServersController.php',
    $panel . '/app/Http/Controllers/Admin/Servers/ServerController.php',
    $panel . '/app/Http/Controllers/Admin/Servers/ServerViewController.php',
    $panel . '/app/Http/Controllers/Admin/Servers/ServerTransferController.php',
] as $file) {
    kahfi_patch_admin_server_controller($file);
}

// 3. Create server controller tetap bersih dari root-only guard.
$createFile = $panel . '/app/Http/Controllers/Admin/Servers/CreateServerController.php';
$s = kahfi_read($createFile);
if ($s !== null) {
    $s = kahfi_cleanup_all_old_blocks($s);
    $s = preg_replace('/\n\s*\$this->checkAdmin\(["\']create["\']\);\s*/mi', "\n        // KAHFI v5: reseller admin tetap boleh create server.\n", $s) ?? $s;
    kahfi_write($createFile, $s);
}

// 4. Service modifikasi server: root atau own/created only.
$serviceDir = $panel . '/app/Services/Servers';
if (is_dir($serviceDir)) {
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($serviceDir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $info) {
        if (!$info->isFile() || strtolower($info->getExtension()) !== 'php') continue;
        $base = $info->getBasename();
        if (stripos($base, 'Creation') !== false) continue;
        if (preg_match('/(ModificationService|Reinstall|Suspend|Suspension|Deletion|Delete|Transfer|Database)/i', $base)) {
            kahfi_patch_service_file($info->getPathname());
        }
    }
}

// 5. Tandai server baru yang dibuat admin reseller, supaya bot/manual create ke user lain tetap dianggap milik reseller pembuat.
kahfi_patch_creation_service($panel . '/app/Services/Servers/ServerCreationService.php');
PHP_PATCH

echo "Checking PHP syntax..."
FILES_TO_CHECK=(
  "app/Http/Controllers/Admin/ServersController.php"
  "app/Http/Controllers/Admin/Servers/ServerController.php"
  "app/Http/Controllers/Admin/Servers/ServerViewController.php"
  "app/Http/Controllers/Admin/Servers/ServerTransferController.php"
  "app/Http/Controllers/Admin/Servers/CreateServerController.php"
  "app/Http/Controllers/Api/Client/ClientController.php"
  "app/Services/Servers/ServerCreationService.php"
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
echo "DONE v5 FINAL."
echo "Admin utama ID 1: full akses semua."
echo "Admin reseller selain ID 1: bisa create server manual/bot, PTLA/PTLC sendiri, dan akses/manage server miliknya sendiri."
echo "Admin reseller selain ID 1: dilarang intip/manage server orang lain."
echo "Server baru yang dibuat admin reseller akan diberi marker KAHFI_RESELLER_CREATOR_ID di description."
echo
echo "WAJIB: logout admin reseller lalu login ulang / buka incognito."
echo "Test:"
echo "- server milik sendiri: buka /server/<identifier>, console, file, startup harus bisa."
echo "- server orang lain: harus 403/protection."
echo "- create server manual/bot harus tetap bisa."
