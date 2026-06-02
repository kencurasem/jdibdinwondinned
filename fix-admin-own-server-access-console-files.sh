#!/usr/bin/env bash
# KahfiModTzy Fix:
# - Admin utama ID 1 tetap bisa akses semua server.
# - Admin selain ID 1 hanya bisa buka console/files/backups server miliknya sendiri.
# - User biasa tetap bisa download/backup/file server miliknya sendiri.
# - Akses server orang lain akan ditolak dengan peringatan.

set -euo pipefail

PANEL="/var/www/pterodactyl"
BACKUP="/root/pterodactyl_backups"
TS="$(date -u +%Y-%m-%d-%H-%M-%S)"

say(){ printf '%s\n' "$1"; }
fail(){ printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ -d "$PANEL" ] || fail "Folder panel tidak ketemu: $PANEL"
mkdir -p "$BACKUP"
cd "$PANEL"

say "== FIX ADMIN OWN SERVER ACCESS =="
say "Panel : $PANEL"
say "Backup: $BACKUP"
say ""

php <<'PHP_PATCH'
<?php
$panel = '/var/www/pterodactyl';
$backup = '/root/pterodactyl_backups';
$ts = gmdate('Y-m-d-H-i-s');

if (!is_dir($backup)) {
    mkdir($backup, 0755, true);
}

function backup_file_once(string $file, string $name, string $backup, string $ts): void {
    if (is_file($file)) {
        copy($file, rtrim($backup, '/') . '/' . $name . '_own_server_access_' . $ts . '.bak');
        echo "Backup: {$name}\n";
    }
}

function add_use_if_missing(string $contents, string $useLine): string {
    if (strpos($contents, $useLine) !== false) {
        return $contents;
    }
    return preg_replace('/namespace\s+[^;]+;\s*/', "$0\n{$useLine}\n", $contents, 1) ?? $contents;
}

function patch_client_server_controller(string $file, string $backup, string $ts): void {
    if (!is_file($file)) return;

    $name = 'Client_' . basename($file, '.php');
    $contents = file_get_contents($file);
    if ($contents === false) return;

    $original = $contents;
    backup_file_once($file, $name, $backup, $ts);

    $guard = <<<'GUARD'
        // KahfiModTzy Own Server Guard
        // Admin utama ID 1 boleh semua. Admin lain/user biasa hanya server miliknya sendiri/subuser.
        $kahfiUser = null;
        try {
            if (isset($request) && is_object($request) && method_exists($request, 'user')) {
                $kahfiUser = $request->user();
            }
        } catch (\Throwable $e) {
            $kahfiUser = null;
        }
        if (!$kahfiUser) {
            try {
                $kahfiUser = \Illuminate\Support\Facades\Auth::user();
            } catch (\Throwable $e) {
                $kahfiUser = null;
            }
        }
        if ($kahfiUser && isset($server)) {
            $kahfiIsMainAdmin = ((int) $kahfiUser->id === 1);
            $kahfiIsOwner = ((int) ($server->owner_id ?? 0) === (int) $kahfiUser->id);
            $kahfiIsSubuser = false;
            try {
                if (method_exists($server, 'subusers')) {
                    $kahfiIsSubuser = $server->subusers()->where('user_id', $kahfiUser->id)->exists();
                }
            } catch (\Throwable $e) {
                $kahfiIsSubuser = false;
            }
            if (!$kahfiIsMainAdmin && !$kahfiIsOwner && !$kahfiIsSubuser) {
                abort(403, 'KahfiModTzy Protection :: kamu hanya boleh membuka console/file/backup server milikmu sendiri.');
            }
        }
GUARD;

    // Masukkan guard ke semua method Client API yang menerima Server $server.
    if (strpos($contents, 'KahfiModTzy Own Server Guard') === false) {
        $pattern = '/(public\s+function\s+\w+\s*\([^)]*Server\s+\$server[^)]*\)\s*(?::\s*[^\{]+)?\s*\{)/m';
        $contents = preg_replace_callback($pattern, function ($m) use ($guard) {
            return $m[1] . "\n" . $guard . "\n";
        }, $contents) ?? $contents;
    }

    // Kalau FileController masih punya checkServerAccess lama/no-op, paksa isinya benar.
    if (basename($file) === 'FileController.php' && strpos($contents, 'function checkServerAccess') !== false) {
        $method = <<<'METHOD'
    private function checkServerAccess($request, Server $server)
    {
        $user = $request->user();

        if (!$user) {
            abort(403, 'KahfiModTzy Protection :: file access denied');
        }

        if ((int) $user->id === 1) {
            return;
        }

        if ((int) ($server->owner_id ?? 0) === (int) $user->id) {
            return;
        }

        try {
            if (method_exists($server, 'subusers') && $server->subusers()->where('user_id', $user->id)->exists()) {
                return;
            }
        } catch (\Throwable $e) {
            // lanjut block
        }

        abort(403, 'KahfiModTzy Protection :: kamu hanya boleh membuka/download file server milikmu sendiri.');
    }
METHOD;
        $contents = replace_method_by_name($contents, 'checkServerAccess', $method);
    }

    // Kalau ServerController masih ada owner_id check lama, guard baru tetap aman.
    // Tidak perlu hapus paksa agar tidak merusak struktur versi panel.

    if ($contents !== $original) {
        file_put_contents($file, $contents);
        echo "Patched: {$name}\n";
    } else {
        echo "No change: {$name}\n";
    }
}

function replace_method_by_name(string $contents, string $methodName, string $replacement): string {
    $pos = strpos($contents, 'function ' . $methodName . '(');
    if ($pos === false) return $contents;

    $start = $pos;
    while ($start > 0 && substr($contents, $start, 1) !== "\n") {
        $start--;
    }
    if (substr($contents, $start, 1) === "\n") $start++;

    $brace = strpos($contents, '{', $pos);
    if ($brace === false) return $contents;

    $depth = 0;
    $len = strlen($contents);
    for ($i = $brace; $i < $len; $i++) {
        $ch = $contents[$i];
        if ($ch === '{') $depth++;
        if ($ch === '}') {
            $depth--;
            if ($depth === 0) {
                $end = $i + 1;
                return substr($contents, 0, $start) . rtrim($replacement) . substr($contents, $end);
            }
        }
    }

    return $contents;
}

function patch_admin_servers_controller(string $panel, string $backup, string $ts): void {
    $file = $panel . '/app/Http/Controllers/Admin/ServersController.php';
    if (!is_file($file)) return;

    $contents = file_get_contents($file);
    if ($contents === false) return;

    $original = $contents;
    backup_file_once($file, 'Admin_ServersController', $backup, $ts);

    $contents = add_use_if_missing($contents, 'use Illuminate\Support\Facades\Auth;');
    $contents = add_use_if_missing($contents, 'use Pterodactyl\Exceptions\DisplayException;');

    $helper = <<<'HELPER'
    private function kahfiEnsureOwnAdminServer(Server $server): void
    {
        $user = Auth::user();

        if (!$user) {
            throw new DisplayException('KahfiModTzy Protection :: kamu harus login.');
        }

        if ((int) $user->id === 1) {
            return;
        }

        if ((int) ($server->owner_id ?? 0) !== (int) $user->id) {
            throw new DisplayException('KahfiModTzy Protection :: admin selain utama hanya boleh membuka server miliknya sendiri.');
        }
    }
HELPER;

    if (strpos($contents, 'kahfiEnsureOwnAdminServer') === false) {
        // Sisipkan helper setelah constructor jika ada, kalau gagal sebelum method index.
        $constructorPos = strpos($contents, 'public function __construct');
        if ($constructorPos !== false) {
            $brace = strpos($contents, '{', $constructorPos);
            if ($brace !== false) {
                $depth = 0;
                $len = strlen($contents);
                $insert = null;
                for ($i = $brace; $i < $len; $i++) {
                    if ($contents[$i] === '{') $depth++;
                    if ($contents[$i] === '}') {
                        $depth--;
                        if ($depth === 0) { $insert = $i + 1; break; }
                    }
                }
                if ($insert !== null) {
                    $contents = substr($contents, 0, $insert) . "\n\n" . $helper . "\n" . substr($contents, $insert);
                }
            }
        }
        if (strpos($contents, 'kahfiEnsureOwnAdminServer') === false) {
            $contents = preg_replace('/(public\s+function\s+index\s*\()/m', $helper . "\n\n$1", $contents, 1) ?? $contents;
        }
    }

    // Filter list Admin > Servers untuk admin selain ID 1 supaya tidak kelihatan semua server orang.
    if (strpos($contents, 'KahfiModTzy Filter Own Servers List') === false) {
        $pattern = '/\$servers\s*=\s*QueryBuilder::for\(\s*Server::query\(\)->with\(\["user",\s*"node",\s*"allocation",\s*"nest",\s*"egg"\]\)\s*\)/s';
        $replacement = <<<'REPL'
$kahfiServersQuery = Server::query()->with(["user", "node", "allocation", "nest", "egg"]);
        // KahfiModTzy Filter Own Servers List
        $kahfiAuthUser = Auth::user();
        if ($kahfiAuthUser && (int) $kahfiAuthUser->id !== 1) {
            $kahfiServersQuery->where('owner_id', $kahfiAuthUser->id);
        }

        $servers = QueryBuilder::for($kahfiServersQuery)
REPL;
        $contents = preg_replace($pattern, $replacement, $contents, 1) ?? $contents;
    }

    // Method view(Request $request, int $server) wajib dicek karena ini halaman utama server di admin.
    if (preg_match('/public\s+function\s+view\s*\(\s*Request\s+\$request\s*,\s*int\s+\$server\s*\)\s*:\s*View\s*\{/m', $contents)) {
        $replacement = <<<'METHOD'
    public function view(Request $request, int $server): View
    {
        $serverModel = Server::with(["allocations.node", "user", "nest", "egg"])->findOrFail($server);
        $this->kahfiEnsureOwnAdminServer($serverModel);

        return $this->view->make("admin.servers.view.index", [
            "server" => $serverModel,
        ]);
    }
METHOD;
        $contents = replace_method_by_name($contents, 'view', $replacement);
    }

    // Semua method admin yang menerima Server $server harus dicek own-server dulu.
    if (strpos($contents, 'KahfiModTzy Admin Own Server Guard') === false) {
        $pattern = '/(public\s+function\s+(?!index|create|store|view\b)\w+\s*\([^)]*Server\s+\$server[^)]*\)\s*(?::\s*[^\{]+)?\s*\{)/m';
        $contents = preg_replace_callback($pattern, function ($m) {
            return $m[1] . "\n        // KahfiModTzy Admin Own Server Guard\n        \$this->kahfiEnsureOwnAdminServer(\$server);\n";
        }, $contents) ?? $contents;
    }

    if ($contents !== $original) {
        file_put_contents($file, $contents);
        echo "Patched: Admin_ServersController\n";
    } else {
        echo "No change: Admin_ServersController\n";
    }
}

function patch_server_deletion_service(string $panel, string $backup, string $ts): void {
    $file = $panel . '/app/Services/Servers/ServerDeletionService.php';
    if (!is_file($file)) return;

    $contents = file_get_contents($file);
    if ($contents === false) return;

    $original = $contents;
    backup_file_once($file, 'ServerDeletionService', $backup, $ts);

    // Kalau service lama masih mengizinkan owner non-ID1 delete, kunci lagi ke admin utama.
    if (strpos($contents, 'hanya admin utama ID 1 yang boleh delete server') === false) {
        $guard = <<<'GUARD'
        // KahfiModTzy Delete Server Guard
        $kahfiAuthUser = \Illuminate\Support\Facades\Auth::user();
        if (!$kahfiAuthUser || (int) $kahfiAuthUser->id !== 1) {
            throw new \Pterodactyl\Exceptions\DisplayException('KahfiModTzy Protection :: hanya admin utama ID 1 yang boleh delete server.');
        }
GUARD;
        $pattern = '/(public\s+function\s+handle\s*\([^)]*Server\s+\$server[^)]*\)\s*(?::\s*[^\{]+)?\s*\{)/m';
        $contents = preg_replace($pattern, "$1\n" . $guard . "\n", $contents, 1) ?? $contents;
    }

    if ($contents !== $original) {
        file_put_contents($file, $contents);
        echo "Patched: ServerDeletionService\n";
    } else {
        echo "No change: ServerDeletionService\n";
    }
}

// Patch semua Client Server controller: console, websocket, files, backups, power, command, databases, dll.
$clientDir = $panel . '/app/Http/Controllers/Api/Client/Servers';
if (is_dir($clientDir)) {
    $it = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($clientDir, FilesystemIterator::SKIP_DOTS));
    foreach ($it as $f) {
        if ($f->isFile() && strtolower($f->getExtension()) === 'php') {
            $path = $f->getPathname();
            $txt = file_get_contents($path);
            if ($txt !== false && strpos($txt, 'Server $server') !== false) {
                patch_client_server_controller($path, $backup, $ts);
            }
        }
    }
}

patch_admin_servers_controller($panel, $backup, $ts);
patch_server_deletion_service($panel, $backup, $ts);
PHP_PATCH

say ""
say "Clear cache..."
php artisan optimize:clear >/dev/null 2>&1 || true
php artisan view:clear >/dev/null 2>&1 || true
php artisan route:clear >/dev/null 2>&1 || true
php artisan config:clear >/dev/null 2>&1 || true
php artisan queue:restart >/dev/null 2>&1 || true

# Restart service umum, skip kalau service tidak ada.
systemctl restart php8.3-fpm 2>/dev/null || true
systemctl restart php8.2-fpm 2>/dev/null || true
systemctl restart php8.1-fpm 2>/dev/null || true
systemctl restart php8.0-fpm 2>/dev/null || true
systemctl restart nginx 2>/dev/null || true
systemctl restart wings 2>/dev/null || true

say "DONE."
say "Test:"
say "1. User biasa buka Files/Backups server sendiri."
say "2. Admin selain ID 1 buka server orang lain harus ditolak."
say "3. Admin selain ID 1 buka server miliknya sendiri harus bisa."
