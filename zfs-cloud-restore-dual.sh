#!/bin/bash
set -euo pipefail

# ZFS Cloud Restore Script with Dual Provider Support

# === LOAD CONFIG ===
CONFIG_FILE="${OFFSITE_CONFIG:-$HOME/.config/offsite/config.env}"
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    echo "WARNING: Config file not found at $CONFIG_FILE"
    echo "Using default values or environment variables"
fi

# === CONFIG WITH DEFAULTS ===
AGE_PRIVATE_KEY_FILE="${AGE_PRIVATE_KEY_FILE:-$HOME/.config/age/zfs-backup.txt}"
RCLONE_REMOTE="${RCLONE_REMOTE:-cloudremote:zfs-buckets-walnut-deepblack-cloud/zfs-backups}"
SCALEWAY_REMOTE="${SCALEWAY_REMOTE:-scaleway:zfs-buckets-acacia/zfs-backups}"
TEMP_DIR="${TEMP_DIR:-/tmp}"

# === USAGE ===
show_usage() {
    echo "Usage: $0 <provider> <dataset_path> <backup_file> <target_dataset>"
    echo ""
    echo "Providers:"
    echo "  backblaze  - Restore from Backblaze (US)"
    echo "  scaleway   - Restore from Scaleway (EU)"
    echo "  auto       - Try both providers (Backblaze first)"
    echo ""
    echo "Arguments:"
    echo "  dataset_path   - Remote path (e.g., rust_containers)"
    echo "  backup_file    - Backup filename (e.g., full-20250716-000001.zfs.gz.age)"
    echo "  target_dataset - Local ZFS dataset to restore to (e.g., rust/containers-restored)"
    echo ""
    echo "Examples:"
    echo "  $0 backblaze rust_containers full-20250716-000001.zfs.gz.age rust/containers-restored"
    echo "  $0 scaleway rust_containers incr-20250717-000001.zfs.gz.age rust/containers-restored"
    echo "  $0 auto rust_containers full-20250716-000001.zfs.gz.age rust/containers-restored"
    echo ""
    echo "List available backups:"
    echo "  rclone ls $RCLONE_REMOTE/<dataset_path>/     # Backblaze"
    echo "  rclone ls $SCALEWAY_REMOTE/<dataset_path>/   # Scaleway"
}

if [[ $# -ne 4 ]]; then
    show_usage
    exit 1
fi

# === INPUTS ===
PROVIDER="$1"
DATASET_PATH="$2"
BACKUP_FILE="$3"
TARGET_DATASET="$4"

# === VALIDATION ===
if [[ ! -f "$AGE_PRIVATE_KEY_FILE" ]]; then
    echo "ERROR: Age private key not found at $AGE_PRIVATE_KEY_FILE"
    exit 1
fi

if ! command -v rclone >/dev/null 2>&1; then
    echo "ERROR: rclone not installed"
    exit 1
fi

if ! command -v age >/dev/null 2>&1; then
    echo "ERROR: age not installed"
    exit 1
fi

if ! command -v zfs >/dev/null 2>&1; then
    echo "ERROR: zfs not installed"
    exit 1
fi

# === PROVIDER SELECTION ===
case "$PROVIDER" in
    backblaze|bb)
        SELECTED_REMOTE="$RCLONE_REMOTE"
        PROVIDER_NAME="Backblaze (US)"
        ;;
    scaleway|scw)
        SELECTED_REMOTE="$SCALEWAY_REMOTE"
        PROVIDER_NAME="Scaleway (EU)"
        ;;
    auto)
        # Try both providers, prefer Backblaze
        echo "Auto mode: Testing both providers..."
        if rclone lsf "${RCLONE_REMOTE}/${DATASET_PATH}/" 2>/dev/null | grep -q "^${BACKUP_FILE}$"; then
            SELECTED_REMOTE="$RCLONE_REMOTE"
            PROVIDER_NAME="Backblaze (US) - auto-selected"
        elif rclone lsf "${SCALEWAY_REMOTE}/${DATASET_PATH}/" 2>/dev/null | grep -q "^${BACKUP_FILE}$"; then
            SELECTED_REMOTE="$SCALEWAY_REMOTE"
            PROVIDER_NAME="Scaleway (EU) - auto-selected"
        else
            echo "ERROR: Backup file not found on either provider"
            exit 1
        fi
        ;;
    *)
        echo "ERROR: Unknown provider '$PROVIDER'"
        echo "Valid providers: backblaze, scaleway, auto"
        exit 1
        ;;
esac

# === VARIABLES ===
REMOTE_FILE_PATH="${SELECTED_REMOTE}/${DATASET_PATH}/${BACKUP_FILE}"
TMPFILE="${TEMP_DIR}/restore-$(date +%s).zfs.gz.age"

# === DISPLAY INFO ===
echo "=== ZFS Cloud Restore ==="
echo "Provider: $PROVIDER_NAME"
echo "Remote file: $REMOTE_FILE_PATH"
echo "Target dataset: $TARGET_DATASET"
echo "Temp file: $TMPFILE"
echo ""

# === VALIDATION ===
# Test provider connection
echo "Testing connection to $PROVIDER_NAME..."
if ! rclone lsd "${SELECTED_REMOTE%/*}:" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to $PROVIDER_NAME"
    exit 1
fi
echo "✓ Connected to $PROVIDER_NAME"

# Check if remote file exists
if ! rclone lsf "${SELECTED_REMOTE}/${DATASET_PATH}/" 2>/dev/null | grep -q "^${BACKUP_FILE}$"; then
    echo "ERROR: Backup file not found: ${BACKUP_FILE}"
    echo ""
    echo "Available backups in ${DATASET_PATH} on $PROVIDER_NAME:"
    rclone lsf "${SELECTED_REMOTE}/${DATASET_PATH}/" 2>/dev/null | grep -E '^(full|incr)-.*\.zfs\.gz\.age$' | sort || echo "No backups found"
    
    if [[ "$PROVIDER" != "auto" ]]; then
        echo ""
        echo "Try the other provider:"
        if [[ "$PROVIDER" == "backblaze" ]]; then
            echo "  $0 scaleway $DATASET_PATH $BACKUP_FILE $TARGET_DATASET"
        else
            echo "  $0 backblaze $DATASET_PATH $BACKUP_FILE $TARGET_DATASET"
        fi
    fi
    exit 1
fi

# Check if target dataset already exists
if zfs list "$TARGET_DATASET" >/dev/null 2>&1; then
    echo "WARNING: Target dataset $TARGET_DATASET already exists"
    read -p "Do you want to destroy and recreate it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Restore cancelled"
        exit 1
    fi
    echo "Destroying existing dataset..."
    zfs destroy -r "$TARGET_DATASET"
fi

# === RESTORE ===
echo "[1/4] Downloading backup file from $PROVIDER_NAME..."
rclone copy "$REMOTE_FILE_PATH" "$TMPFILE" --progress

echo "[2/4] Verifying download..."
if [[ ! -f "$TMPFILE" ]]; then
    echo "ERROR: Download failed"
    exit 1
fi

file_size=$(stat -c%s "$TMPFILE")
echo "Downloaded $(numfmt --to=iec-i --suffix=B $file_size)"

echo "[3/4] Decrypting and restoring to $TARGET_DATASET..."
age -d -i "$AGE_PRIVATE_KEY_FILE" "$TMPFILE" | gunzip | zfs recv -F "$TARGET_DATASET"

echo "[4/4] Cleaning up..."
rm "$TMPFILE"

echo ""
echo "✓ Restore complete from $PROVIDER_NAME!"
echo ""
echo "Restored dataset: $TARGET_DATASET"
echo "You can now:"
echo "  - Mount: zfs mount $TARGET_DATASET"
echo "  - List snapshots: zfs list -t snapshot -r $TARGET_DATASET"
echo "  - Access data at: $(zfs get -H -o value mountpoint $TARGET_DATASET 2>/dev/null || echo 'mount point')"