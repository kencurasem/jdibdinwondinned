#!/bin/bash
# uninstall_kahfimodtzy.sh – rollback penuh ke panel vanilla

PANEL_PATH="/var/www/pterodactyl"
BACKUP_DIR="/root/pterodactyl_backups"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== KahfiModTzy Uninstall Rollback ===${NC}"

if [ ! -d "$BACKUP_DIR" ]; then
    echo -e "${RED}❌ Folder backup tidak ditemukan: $BACKUP_DIR${NC}"
    exit 1
fi

declare -A FILE_MAP=(
    ["ServerDeletionService"]="app/Services/Servers/ServerDeletionService.php"
    ["UserController"]="app/Http/Controllers/Admin/UserController.php"
    ["LocationController"]="app/Http/Controllers/Admin/LocationController.php"
    ["NodeController"]="app/Http/Controllers/Admin/Nodes/NodeController.php"
    ["NestController"]="app/Http/Controllers/Admin/Nests/NestController.php"
    ["SettingsController"]="app/Http/Controllers/Admin/Settings/IndexController.php"
    ["FileController"]="app/Http/Controllers/Api/Client/Servers/FileController.php"
    ["ServerController"]="app/Http/Controllers/Api/Client/Servers/ServerController.php"
    ["DetailsModificationService"]="app/Services/Servers/DetailsModificationService.php"
    ["ServersController"]="app/Http/Controllers/Admin/ServersController.php"
    ["admin_layout"]="resources/views/layouts/admin.blade.php"
)

echo -e "\n${CYAN}Restoring files...${NC}"
for KEY in "${!FILE_MAP[@]}"; do
    TARGET_REL="${FILE_MAP[$KEY]}"
    TARGET_FULL="$PANEL_PATH/$TARGET_REL"

    # Ambil backup paling lama (original sebelum diprotect)
    OLDEST_BAK=$(ls -1t "$BACKUP_DIR/${KEY}_"*.bak 2>/dev/null | tail -1)

    if [ -z "$OLDEST_BAK" ]; then
        echo -e "${YELLOW}⚠️  Backup tidak ditemukan: $KEY${NC}"
        continue
    fi

    mkdir -p "$(dirname "$TARGET_FULL")"
    cp "$OLDEST_BAK" "$TARGET_FULL"
    echo -e "${GREEN}✅ Restored: $TARGET_REL${NC}"
done

echo -e "\n${CYAN}Removing theme files...${NC}"
rm -f "$PANEL_PATH/public/assets/custom/kahfimodtzy-theme.css"
rm -f "$PANEL_PATH/public/assets/custom/kahfimodtzy-theme.js"
rm -f "$PANEL_PATH/public/assets/custom/joomoddss-theme.css"
rm -f "$PANEL_PATH/public/assets/custom/joomoddss-theme.js"
rmdir "$PANEL_PATH/public/assets/custom" 2>/dev/null
echo -e "${GREEN}✅ Theme files removed${NC}"

echo -e "\n${CYAN}Cleaning admin layout...${NC}"
BLADE="$PANEL_PATH/resources/views/layouts/admin.blade.php"
if [ -f "$BLADE" ]; then
    sed -i '/KahfiModTzy Security/d' "$BLADE"
    sed -i '/JooModdss Security/d' "$BLADE"
    sed -i '/kahfimodtzy-theme/d' "$BLADE"
    sed -i '/joomoddss-theme/d' "$BLADE"
    sed -i '/Poppins.*googleapis/d' "$BLADE"
    echo -e "${GREEN}✅ Admin layout cleaned${NC}"
fi

echo -e "\n${CYAN}Fixing permissions...${NC}"
chown -R www-data:www-data "$PANEL_PATH"
echo -e "${GREEN}✅ Permissions fixed${NC}"

echo -e "\n${CYAN}Clearing cache...${NC}"
cd "$PANEL_PATH"
php artisan view:clear
php artisan config:clear
php artisan cache:clear
php artisan route:clear
php artisan queue:restart

echo ""
echo -e "${GREEN}=== Rollback selesai – panel kembali vanilla ===${NC}"
echo -e "${YELLOW}Backup masih tersimpan di: $BACKUP_DIR${NC}"
echo -e "${YELLOW}Hapus manual jika tidak diperlukan: rm -rf $BACKUP_DIR${NC}"
