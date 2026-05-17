#!/bin/bash
# uninstall_kahfimodtzy.sh – rollback penuh ke panel vanilla

PANEL_PATH="/var/www/pterodactyl"
BACKUP_DIR="/root/pterodactyl_backups"

echo "=== KahfiModTzy Uninstall Rollback ==="

# 1. restore semua .bak terbaru (berdasarkan timestamp)
LATEST=$(ls -1 "$BACKUP_DIR"/*.bak 2>/dev/null | head -1 | xargs -n1 basename | sed 's/.*_\([0-9\-]*\)\.bak/\1/' | head -1)
[[ -z "$LATEST" ]] && { echo "Tidak ada backup ditemukan, keluar."; exit 1; }

for bak in "$BACKUP_DIR"/*_${LATEST}.bak; do
    FILE=$(basename "$bak" | sed "s/_${LATEST}\.bak//")
    TARGET="$PANEL_PATH/$FILE"
    [[ -f "$TARGET" ]] && cp "$bak" "$TARGET" && echo "✅ Restore $FILE"
done

# 2. hapus file tema
rm -f "$PANEL_PATH/public/assets/custom/kahfimodtzy-theme.css" \
      "$PANEL_PATH/public/assets/custom/kahfimodtzy-theme.js"
rmdir "$PANEL_PATH/public/assets/custom" 2>/dev/null

# 3. bersihkan baris tambahan di admin.blade.php
sed -i '/KahfiModTzy Security & Theme/d;
        /kahfimodtzy-theme\.css/d;
        /kahfimodtzy-theme\.js/d' "$PANEL_PATH/resources/views/layouts/admin.blade.php"

# 4. fix permission
chown -R www-data:www-data "$PANEL_PATH"

# 5. cache clear
cd "$PANEL_PATH"
php artisan view:clear
php artisan config:clear
php artisan cache:clear
php artisan route:clear
php artisan queue:restart

echo ""
echo "=== Rollback selesai – panel kembali vanilla ==="
echo "Backup tersimpan di: $BACKUP_DIR"
