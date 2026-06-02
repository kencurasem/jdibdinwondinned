#!/bin/bash
set -u

PANEL_PATH="/var/www/pterodactyl"
BACKUP_DIR="/root/pterodactyl_backups"
TIMESTAMP="$(date -u +%Y-%m-%d-%H-%M-%S)"

mkdir -p "$BACKUP_DIR"

if [ ! -d "$PANEL_PATH" ]; then
  echo "ERROR: Folder panel tidak ketemu: $PANEL_PATH"
  exit 1
fi

cd "$PANEL_PATH" || exit 1

echo "KahfiModTzy :: Fix Admin 2 Can Create Server"
echo "Panel: $PANEL_PATH"
echo "Backup: $BACKUP_DIR"
echo ""

php <<'PHP_PATCH'
<?php
$panelPath = '/var/www/pterodactyl';
$backupDir = '/root/pterodactyl_backups';
$timestamp = gmdate('Y-m-d-H-i-s');

if (!is_dir($backupDir)) {
    mkdir($backupDir, 0755, true);
}

function kahfi_backup_create_fix(string $file, string $name, string $backupDir, string $timestamp): void
{
    if (is_file($file)) {
        copy($file, rtrim($backupDir, '/') . '/' . $name . '_before_admin2_create_fix_' . $timestamp . '.bak');
        echo "Backup: {$name}\n";
    }
}

function kahfi_find_method_create_fix(string $s, string $name): ?array
{
    $pattern = '/(public|protected|private)\s+function\s+' . preg_quote($name, '/') . '\s*\([^)]*\)\s*(?::\s*[^\\{]+)?\s*\\{/m';
    if (!preg_match($pattern, $s, $m, PREG_OFFSET_CAPTURE)) {
        return null;
    }

    $start = $m[0][1];
    $openBrace = $start + strlen($m[0][0]) - 1;
    $depth = 0;
    $len = strlen($s);

    for ($i = $openBrace; $i < $len; $i++) {
        $ch = $s[$i];
        if ($ch === '{') {
            $depth++;
        } elseif ($ch === '}') {
            $depth--;
            if ($depth === 0) {
                return [$start, $i + 1, $openBrace + 1];
            }
        }
    }

    return null;
}

function kahfi_replace_method_body_create_fix(string $s, string $method, callable $callback): array
{
    $block = kahfi_find_method_create_fix($s, $method);
    if ($block === null) {
        return [$s, false, "method {$method} tidak ditemukan"];
    }

    [$start, $end, $insertAt] = $block;
    $body = substr($s, $start, $end - $start);
    $newBody = $callback($body, $method);

    if ($newBody === $body) {
        return [$s, false, "method {$method} tidak berubah"];
    }

    $s = substr($s, 0, $start) . $newBody . substr($s, $end);
    return [$s, true, "method {$method} diperbaiki"];
}

function kahfi_clean_create_store_method(string $body, string $method): string
{
    // Hapus guard dari patch sebelumnya yang salah karena ikut memblokir create server.
    $patterns = [
        // Guard FINAL dari file fix-server-modify-root-only.sh.
        '/\n\s*\/\/ KahfiModTzy Protection :: Root Admin Server Modification Guard FINAL\s*\n\s*\/\/[^\n]*\n\s*\$kahfiAuthUser = \\Illuminate\\Support\\Facades\\Auth::user\(\);\s*\n\s*if \(!\$kahfiAuthUser \|\| \(int\) \$kahfiAuthUser->id !== 1\) \{\s*\n\s*throw new \\Pterodactyl\\Exceptions\\DisplayException\([^;]+\);\s*\n\s*\}\s*/m',

        // Guard V2 dari bash-fixed-server-access-modify-v2.sh.
        '/\n\s*\/\/ KahfiModTzy Protection :: Root Admin Server Modification Guard V2\s*\n\s*\/\/[^\n]*\n\s*\$kahfiAuthUser = \\Illuminate\\Support\\Facades\\Auth::user\(\);\s*\n\s*if \(!\$kahfiAuthUser \|\| \(int\) \$kahfiAuthUser->id !== 1\) \{\s*\n\s*throw new \\Pterodactyl\\Exceptions\\DisplayException\([^;]+\);\s*\n\s*\}\s*/m',
    ];

    foreach ($patterns as $pattern) {
        $body = preg_replace($pattern, "\n", $body) ?? $body;
    }

    // Hapus blok lama dari bash.sh yang melarang admin kedua create server manual.
    // Ini hanya dibersihkan di method create() dan store(), bukan method modifikasi lain.
    $body = preg_replace('/\n\s*\$this->checkAdmin\(["\']create["\']\);\s*/m', "\n", $body) ?? $body;

    // Bersihkan komentar jika ada yang menyebut create ikut dilarang.
    $body = str_replace(
        'Selain admin utama ID 1 dilarang create/modifikasi/delete server dari Admin Panel.',
        'Admin kedua boleh create server; modifikasi/delete server tetap khusus admin utama ID 1.',
        $body
    );
    $body = str_replace(
        'Selain admin utama ID 1 dilarang create/modifikasi/delete server dari admin panel.',
        'Admin kedua boleh create server; modifikasi/delete server tetap khusus admin utama ID 1.',
        $body
    );

    return $body;
}

$serversController = $panelPath . '/app/Http/Controllers/Admin/ServersController.php';

if (!is_file($serversController)) {
    echo "ERROR: ServersController tidak ditemukan: {$serversController}\n";
    exit(1);
}

$s = file_get_contents($serversController);
if ($s === false) {
    echo "ERROR: ServersController tidak bisa dibaca\n";
    exit(1);
}

$original = $s;
$messages = [];

foreach (['create', 'store'] as $method) {
    [$s, $changed, $msg] = kahfi_replace_method_body_create_fix($s, $method, 'kahfi_clean_create_store_method');
    $messages[] = $msg;
}

if ($s !== $original) {
    kahfi_backup_create_fix($serversController, 'ServersController', $backupDir, $timestamp);
    file_put_contents($serversController, $s);
    echo "OK: Admin kedua sekarang boleh create server manual dari Admin Panel.\n";
} else {
    echo "OK: Tidak ada blok create/store yang perlu dihapus, kemungkinan sudah aman.\n";
}

foreach ($messages as $msg) {
    echo "- {$msg}\n";
}

// Guard modifikasi lain tetap dipertahankan. Tidak menghapus viewDetails, viewBuild,
// viewStartup, setDetails, updateBuild, saveStartup, database, suspend, reinstall, delete.

// Jaga-jaga: kalau ada guard root-only yang pernah tidak sengaja masuk ke ServerCreationService,
// hapus hanya guard marker server modification, bukan guard lain.
$creationService = $panelPath . '/app/Services/Servers/ServerCreationService.php';
if (is_file($creationService)) {
    $c = file_get_contents($creationService);
    if ($c !== false) {
        $before = $c;
        foreach ([
            '/\n\s*\/\/ KahfiModTzy Protection :: Root Admin Server Service Guard FINAL\s*\n.*?throw new \\Pterodactyl\\Exceptions\\DisplayException\([^;]+\);\s*\n\s*\}\s*/s',
            '/\n\s*\/\/ KahfiModTzy Protection :: Root Admin Server Service Guard V2\s*\n.*?throw new \\Pterodactyl\\Exceptions\\DisplayException\([^;]+\);\s*\n\s*\}\s*/s',
        ] as $pattern) {
            $c = preg_replace($pattern, "\n", $c) ?? $c;
        }

        if ($c !== $before) {
            kahfi_backup_create_fix($creationService, 'ServerCreationService', $backupDir, $timestamp);
            file_put_contents($creationService, $c);
            echo "OK: Guard salah di ServerCreationService dibersihkan.\n";
        }
    }
}
PHP_PATCH

echo ""
echo "== CEK SYNTAX PHP =="
php -l app/Http/Controllers/Admin/ServersController.php || exit 1
[ -f app/Services/Servers/ServerCreationService.php ] && php -l app/Services/Servers/ServerCreationService.php || true

echo ""
echo "== CLEAR CACHE + RESTART SERVICE =="
chown -R www-data:www-data "$PANEL_PATH" || true
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

echo ""
echo "DONE"
echo "Admin utama ID 1: tetap boleh semua."
echo "Admin kedua/ketiga: BOLEH create server manual/bot, tapi tetap DILARANG modifikasi/manage/delete server setelah server dibuat."
