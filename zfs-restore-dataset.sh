#!/bin/bash
set -euo pipefail

# ZFS Single Dataset Restore Script with Chunked Backup Support

# === USAGE ===
show_usage() {
    echo "Usage: $0 <provider> <source_dataset> <backup_prefix> [target_dataset]"
    echo ""
    echo "Providers:"
    echo "  backblaze  - Restore from Backblaze (US)"
    echo "  scaleway   - Restore from Scaleway (EU)"
    echo "  auto       - Try both providers (Backblaze first)"
    echo ""
    echo "Arguments:"
    echo "  source_dataset - Original dataset name (e.g., rust/containers)"
    echo "  backup_prefix  - Backup prefix (e.g., full-20250716-104500)"
    echo "  target_dataset - Optional: New dataset name (default: source_dataset-restored)"
    echo ""
    echo "Examples:"
    echo "  $0 backblaze rust/containers full-20250716-104500"
    echo "    # Restores to rust/containers-restored"
    echo ""
    echo "  $0 scaleway rust/family incr-20250717-104500 rust/family-test"
    echo "    # Restores to rust/family-test"
    echo ""
    echo "  $0 auto rust/projects full-20250716-104500 tank/projects-backup"
    echo "    # Auto-detects provider, restores to tank/projects-backup"
    echo ""
    echo "List available backups:"
    echo "  rclone ls cloudremote:zfs-buckets-walnut-deepblack-cloud/zfs-backups/rust_containers/"
    echo "  rclone ls scaleway:zfs-buckets-acacia/zfs-backups/rust_containers/"
}

if [[ $# -lt 3 ]] || [[ $# -gt 4 ]]; then
    show_usage
    exit 1
fi

# === INPUTS ===
PROVIDER="$1"
SOURCE_DATASET="$2"
BACKUP_PREFIX="$3"
TARGET_DATASET="${4:-${SOURCE_DATASET}-restored}"

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
        DATASET_PATH="${SOURCE_DATASET//\//_}"
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

# === SETUP VARIABLES ===
DATASET_PATH="${SOURCE_DATASET//\//_}"
REMOTE_PATH="${SELECTED_REMOTE}/${DATASET_PATH}"

echo "=== ZFS Dataset Restore ==="
echo "Provider: $PROVIDER_NAME"
echo "Source dataset: $SOURCE_DATASET"
echo "Backup prefix: $BACKUP_PREFIX"
echo "Target dataset: $TARGET_DATASET"
echo "Remote path: $REMOTE_PATH"
echo ""

# === DISCOVER CHUNKS ===
echo "Discovering backup chunks..."
CHUNK_FILES=($(rclone lsf "${REMOTE_PATH}/" 2>/dev/null | grep "^${BACKUP_PREFIX}-[0-9][0-9][0-9].zfs.gz.age$" | sort))

if [[ ${#CHUNK_FILES[@]} -eq 0 ]]; then
    echo "ERROR: No chunks found for backup prefix: ${BACKUP_PREFIX}"
    echo ""
    echo "Available backups for ${SOURCE_DATASET} on $PROVIDER_NAME:"
    rclone lsf "${REMOTE_PATH}/" 2>/dev/null | grep -E '^(full|incr)-.*-[0-9][0-9][0-9]\.zfs\.gz\.age$' | sed 's/-[0-9][0-9][0-9]\.zfs\.gz\.age$//' | sort -u || echo "No backups found"
    
    if [[ "$PROVIDER" != "auto" ]]; then
        echo ""
        echo "Try the other provider:"
        if [[ "$PROVIDER" == "backblaze" ]]; then
            echo "  $0 scaleway $SOURCE_DATASET $BACKUP_PREFIX $TARGET_DATASET"
        else
            echo "  $0 backblaze $SOURCE_DATASET $BACKUP_PREFIX $TARGET_DATASET"
        fi
    fi
    exit 1
fi

echo "Found ${#CHUNK_FILES[@]} chunks: ${CHUNK_FILES[0]} ... ${CHUNK_FILES[-1]}"

# === CONNECTION TEST ===
echo "Testing connection to $PROVIDER_NAME..."
if ! rclone lsd "${SELECTED_REMOTE%/*}:" >/dev/null 2>&1; then
    echo "ERROR: Cannot connect to $PROVIDER_NAME"
    exit 1
fi
echo "✓ Connected to $PROVIDER_NAME"

# === TARGET DATASET VALIDATION ===
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
echo "This will restore $SOURCE_DATASET to $TARGET_DATASET"

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
    
    # Try primary provider first
    if rclone cat "${REMOTE_PATH}/${chunk_file}" >> "$RESTORE_FIFO" 2>/dev/null; then
        echo "      ✓ Downloaded from $PROVIDER_NAME"
    else
        echo "      ⚠ Failed from $PROVIDER_NAME, trying alternate provider..."
        
        # Determine alternate provider
        if [[ "$PROVIDER_NAME" == *"Backblaze"* ]]; then
            ALT_REMOTE="$SCALEWAY_REMOTE"
            ALT_NAME="Scaleway"
        else
            ALT_REMOTE="$RCLONE_REMOTE"
            ALT_NAME="Backblaze"
        fi
        
        ALT_PATH="${ALT_REMOTE}/${DATASET_PATH}"
        
        # Try alternate provider
        if rclone cat "${ALT_PATH}/${chunk_file}" >> "$RESTORE_FIFO" 2>/dev/null; then
            echo "      ✓ Downloaded from $ALT_NAME (failover success)"
        else
            echo "ERROR: Chunk $chunk_file failed on both providers"
            kill $ZFS_PID 2>/dev/null || true
            rm -f "$RESTORE_FIFO"
            exit 1
        fi
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
    echo "✓ Dataset restore complete from $PROVIDER_NAME!"
    echo ""
    echo "Source: $SOURCE_DATASET ($BACKUP_PREFIX)"
    echo "Target: $TARGET_DATASET"
    echo "Chunks processed: ${total_chunks}"
    echo "Provider: $PROVIDER_NAME"
    echo ""
    echo "You can now:"
    echo "  - Mount: zfs mount $TARGET_DATASET"
    echo "  - List snapshots: zfs list -t snapshot -r $TARGET_DATASET"
    echo "  - Access data at: $(zfs get -H -o value mountpoint $TARGET_DATASET 2>/dev/null || echo 'mount point')"
    echo ""
    echo "To make this the active dataset, you can:"
    echo "  1. Stop services using the original dataset"
    echo "  2. Rename: zfs rename $SOURCE_DATASET ${SOURCE_DATASET}-old"
    echo "  3. Rename: zfs rename $TARGET_DATASET $SOURCE_DATASET"
    echo "  4. Restart services"
else
    echo ""
    echo "ERROR: ZFS receive failed with exit code: $ZFS_EXIT_CODE"
    exit 1
fi