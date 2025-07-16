#!/bin/bash
set -euo pipefail

# ZFS Cloud Restore Script with Chunked Backup Support

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
    echo "Usage: $0 <provider> <dataset_path> <backup_prefix> <target_dataset>"
    echo ""
    echo "Providers:"
    echo "  backblaze  - Restore from Backblaze (US)"
    echo "  scaleway   - Restore from Scaleway (EU)"
    echo "  auto       - Try both providers (Backblaze first)"
    echo ""
    echo "Arguments:"
    echo "  dataset_path   - Remote path (e.g., rust_containers)"
    echo "  backup_prefix  - Backup prefix (e.g., full-20250716-104500)"
    echo "  target_dataset - Local ZFS dataset to restore to (e.g., rust/containers-restored)"
    echo ""
    echo "Examples:"
    echo "  $0 backblaze rust_containers full-20250716-104500 rust/containers-restored"
    echo "  $0 scaleway rust_containers incr-20250717-104500 rust/containers-restored"
    echo "  $0 auto rust_containers full-20250716-104500 rust/containers-restored"
    echo ""
    echo "List available backups:"
    echo "  rclone ls $RCLONE_REMOTE/<dataset_path>/ | grep 'full\\|incr'"
    echo "  rclone ls $SCALEWAY_REMOTE/<dataset_path>/ | grep 'full\\|incr'"
    echo ""
    echo "Note: This script automatically detects and downloads all chunks for the specified backup."
}

if [[ $# -ne 4 ]]; then
    show_usage
    exit 1
fi

# === INPUTS ===
PROVIDER="$1"
DATASET_PATH="$2"
BACKUP_PREFIX="$3"
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
        if rclone lsf "${RCLONE_REMOTE}/${DATASET_PATH}/" 2>/dev/null | grep -q "^${BACKUP_PREFIX}-001.zfs.gz.age$"; then
            SELECTED_REMOTE="$RCLONE_REMOTE"
            PROVIDER_NAME="Backblaze (US) - auto-selected"
        elif rclone lsf "${SCALEWAY_REMOTE}/${DATASET_PATH}/" 2>/dev/null | grep -q "^${BACKUP_PREFIX}-001.zfs.gz.age$"; then
            SELECTED_REMOTE="$SCALEWAY_REMOTE"
            PROVIDER_NAME="Scaleway (EU) - auto-selected"
        else
            echo "ERROR: Backup not found on either provider"
            exit 1
        fi
        ;;
    *)
        echo "ERROR: Unknown provider '$PROVIDER'"
        echo "Valid providers: backblaze, scaleway, auto"
        exit 1
        ;;
esac

# === DISCOVER CHUNKS ===
echo "=== ZFS Chunked Cloud Restore ==="
echo "Provider: $PROVIDER_NAME"
echo "Dataset path: $DATASET_PATH"
echo "Backup prefix: $BACKUP_PREFIX"
echo "Target dataset: $TARGET_DATASET"
echo ""

echo "Discovering backup chunks..."
CHUNK_FILES=($(rclone lsf "${SELECTED_REMOTE}/${DATASET_PATH}/" 2>/dev/null | grep "^${BACKUP_PREFIX}-[0-9][0-9][0-9].zfs.gz.age$" | sort))

if [[ ${#CHUNK_FILES[@]} -eq 0 ]]; then
    echo "ERROR: No chunks found for backup prefix: ${BACKUP_PREFIX}"
    echo ""
    echo "Available backups in ${DATASET_PATH} on $PROVIDER_NAME:"
    rclone lsf "${SELECTED_REMOTE}/${DATASET_PATH}/" 2>/dev/null | grep -E '^(full|incr)-.*-[0-9][0-9][0-9]\.zfs\.gz\.age$' | sed 's/-[0-9][0-9][0-9]\.zfs\.gz\.age$//' | sort -u || echo "No backups found"
    
    if [[ "$PROVIDER" != "auto" ]]; then
        echo ""
        echo "Try the other provider:"
        if [[ "$PROVIDER" == "backblaze" ]]; then
            echo "  $0 scaleway $DATASET_PATH $BACKUP_PREFIX $TARGET_DATASET"
        else
            echo "  $0 backblaze $DATASET_PATH $BACKUP_PREFIX $TARGET_DATASET"
        fi
    fi
    exit 1
fi

echo "Found ${#CHUNK_FILES[@]} chunks: ${CHUNK_FILES[0]} ... ${CHUNK_FILES[-1]}"

# === VALIDATION ===
# Test provider connection
echo "Testing connection to $PROVIDER_NAME..."
if ! rclone lsd "${SELECTED_REMOTE%/*}:" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to $PROVIDER_NAME"
    exit 1
fi
echo "✓ Connected to $PROVIDER_NAME"

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

# === RESTORE PROCESS ===
RESTORE_FIFO="${TEMP_DIR}/zfs-restore-$(date +%s).fifo"
mkfifo "$RESTORE_FIFO"

echo ""
echo "Starting chunked restore process..."

# Start ZFS receive in background
(
    echo "ZFS receive process started for $TARGET_DATASET"
    age -d -i "$AGE_PRIVATE_KEY_FILE" < "$RESTORE_FIFO" | gunzip | zfs recv -F "$TARGET_DATASET"
    echo "ZFS receive process completed"
) &
ZFS_PID=$!

# Download and stream chunks in order
chunk_num=1
total_chunks=${#CHUNK_FILES[@]}

for chunk_file in "${CHUNK_FILES[@]}"; do
    echo "[$chunk_num/$total_chunks] Downloading and streaming: $chunk_file"
    
    if ! rclone cat "${SELECTED_REMOTE}/${DATASET_PATH}/${chunk_file}" >> "$RESTORE_FIFO"; then
        echo "ERROR: Failed to download chunk: $chunk_file"
        kill $ZFS_PID 2>/dev/null || true
        rm -f "$RESTORE_FIFO"
        exit 1
    fi
    
    chunk_num=$((chunk_num + 1))
done

# Close the FIFO and wait for ZFS receive to complete
exec 3>"$RESTORE_FIFO"
exec 3>&-
wait $ZFS_PID
ZFS_EXIT_CODE=$?

# Cleanup
rm -f "$RESTORE_FIFO"

if [[ $ZFS_EXIT_CODE -eq 0 ]]; then
    echo ""
    echo "✓ Chunked restore complete from $PROVIDER_NAME!"
    echo ""
    echo "Restored dataset: $TARGET_DATASET"
    echo "Chunks processed: ${total_chunks}"
    echo ""
    echo "You can now:"
    echo "  - Mount: zfs mount $TARGET_DATASET"
    echo "  - List snapshots: zfs list -t snapshot -r $TARGET_DATASET"
    echo "  - Access data at: $(zfs get -H -o value mountpoint $TARGET_DATASET 2>/dev/null || echo 'mount point')"
else
    echo ""
    echo "ERROR: ZFS receive failed with exit code: $ZFS_EXIT_CODE"
    exit 1
fi