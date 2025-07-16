#!/bin/bash
set -euo pipefail

# Offsite Restore - Single Dataset
# Downloads and restores encrypted chunks from cloud storage

# === USAGE ===
if [[ $# -lt 3 ]] || [[ $# -gt 4 ]]; then
    echo "Usage: $0 <provider> <source_dataset> <backup_prefix> [target_dataset]"
    echo ""
    echo "Providers:"
    echo "  backblaze  - Restore from Backblaze (US)"
    echo "  scaleway   - Restore from Scaleway (EU)"
    echo "  auto       - Try both providers (Backblaze first)"
    echo ""
    echo "Arguments:"
    echo "  source_dataset - Original dataset name (e.g., rust/containers)"
    echo "  backup_prefix  - Backup prefix (e.g., full-auto-20250716-161605)"
    echo "  target_dataset - Optional: New dataset name (default: source_dataset-restored)"
    echo ""
    echo "Examples:"
    echo "  $0 backblaze rust/containers full-auto-20250716-161605"
    echo "    # Restores to rust/containers-restored"
    echo ""
    echo "  $0 scaleway rust/family incr-auto-20250717-104500 rust/family-test"
    echo "    # Restores to rust/family-test"
    echo ""
    echo "  $0 auto rust/projects full-auto-20250716-161605 tank/projects-backup"
    echo "    # Auto-detects provider, restores to tank/projects-backup"
    exit 1
fi

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
[[ -f "$AGE_PRIVATE_KEY_FILE" ]] || { echo "ERROR: Age private key not found at $AGE_PRIVATE_KEY_FILE"; exit 1; }
command -v rclone >/dev/null || { echo "ERROR: rclone not installed"; exit 1; }
command -v age >/dev/null || { echo "ERROR: age not installed"; exit 1; }
command -v zfs >/dev/null || { echo "ERROR: zfs not installed"; exit 1; }

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
        if rclone lsf "${RCLONE_REMOTE}/${DATASET_PATH}/" 2>/dev/null | grep -q "^${BACKUP_PREFIX}-x001.zfs.gz.age$"; then
            SELECTED_REMOTE="$RCLONE_REMOTE"
            PROVIDER_NAME="Backblaze (US) - auto-selected"
        elif rclone lsf "${SCALEWAY_REMOTE}/${DATASET_PATH}/" 2>/dev/null | grep -q "^${BACKUP_PREFIX}-x001.zfs.gz.age$"; then
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

echo "=== Offsite Restore ==="
echo "Provider: $PROVIDER_NAME"
echo "Source dataset: $SOURCE_DATASET"
echo "Backup prefix: $BACKUP_PREFIX"
echo "Target dataset: $TARGET_DATASET"
echo "Remote path: $REMOTE_PATH"
echo ""

# === DISCOVER CHUNKS ===
echo "Discovering backup chunks..."
CHUNK_FILES=($(rclone lsf "${REMOTE_PATH}/" 2>/dev/null | grep "^${BACKUP_PREFIX}-x[0-9][0-9][0-9].zfs.gz.age$" | sort))

if [[ ${#CHUNK_FILES[@]} -eq 0 ]]; then
    echo "ERROR: No chunks found for backup prefix: ${BACKUP_PREFIX}"
    echo ""
    echo "Available backups for ${SOURCE_DATASET} on $PROVIDER_NAME:"
    rclone lsf "${REMOTE_PATH}/" 2>/dev/null | grep -E '^(full|incr)-.*-x[0-9][0-9][0-9]\.zfs\.gz\.age$' | sed 's/-x[0-9][0-9][0-9]\.zfs\.gz\.age$//' | sort -u || echo "No backups found"
    exit 1
fi

echo "Found ${#CHUNK_FILES[@]} chunks: ${CHUNK_FILES[0]} ... ${CHUNK_FILES[-1]}"

# === CONNECTION TEST ===
echo "Testing connection to $PROVIDER_NAME..."
if ! rclone lsd "${SELECTED_REMOTE%:*}:" >/dev/null 2>&1; then
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
WORK_DIR="${TEMP_DIR}/offsite-restore-$(date +%s)"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

echo ""
echo "Starting restore process..."
echo "Working directory: $WORK_DIR"

# Download all chunks
echo "Step 1: Downloading chunks..."
for chunk_file in "${CHUNK_FILES[@]}"; do
    echo "  Downloading: $chunk_file"
    rclone copy "${REMOTE_PATH}/${chunk_file}" ./
done

# Decrypt and decompress chunks
echo "Step 2: Decrypting and decompressing chunks..."
for chunk_file in "${CHUNK_FILES[@]}"; do
    echo "  Processing: $chunk_file"
    # Extract the chunk number from filename (e.g., full-auto-20250716-161605-x001.zfs.gz.age -> 001)
    chunk_num=$(echo "$chunk_file" | sed 's/.*-x\([0-9][0-9][0-9]\)\.zfs\.gz\.age$/\1/')
    age -d -i "$AGE_PRIVATE_KEY_FILE" "$chunk_file" | gunzip > "chunk-${chunk_num}.restored"
    echo "    ✓ Restored: chunk-${chunk_num}.restored"
done

# Reconstitute stream
echo "Step 3: Reconstituting ZFS stream..."
cat chunk-*.restored > complete-stream.zfs
echo "Complete stream size: $(wc -c < complete-stream.zfs) bytes"

# ZFS receive
echo "Step 4: Performing ZFS receive..."
zfs recv -F "$TARGET_DATASET" < complete-stream.zfs

# Cleanup
cd /
rm -rf "$WORK_DIR"

echo ""
echo "✅ Restore complete!"
echo ""
echo "Source: $SOURCE_DATASET ($BACKUP_PREFIX)"
echo "Target: $TARGET_DATASET"
echo "Chunks processed: ${#CHUNK_FILES[@]}"
echo "Provider: $PROVIDER_NAME"
echo ""
echo "You can now:"
echo "  - Mount: zfs mount $TARGET_DATASET"
echo "  - List snapshots: zfs list -t snapshot -r $TARGET_DATASET"
echo "  - Access data at: $(zfs get -H -o value mountpoint $TARGET_DATASET 2>/dev/null || echo 'mount point')"