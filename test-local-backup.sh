#!/bin/bash
set -euo pipefail

# Local backup test script - no internet bandwidth required
# Tests the streaming and byte offset logic without cloud uploads

echo "=== Local Backup Test (No Internet) ==="
echo ""

TEST_DATASET="rust/test"
TEST_SNAPSHOT="now"
LOCAL_DIR="/tmp/offsite-local-test-$(date +%s)"

# Create local test directory
mkdir -p "$LOCAL_DIR/rust_test"
echo "Local test directory: $LOCAL_DIR"

# Create temporary rclone config that points to local filesystem
TEMP_RCLONE_CONFIG="/tmp/rclone-test-$(date +%s).conf"
cat > "$TEMP_RCLONE_CONFIG" << EOF
[localtest]
type = local
nounc = true

[cloudremote]
type = local
nounc = true

[scaleway] 
type = local
nounc = true
EOF

echo "Temporary rclone config: $TEMP_RCLONE_CONFIG"

# Export the temp config
export RCLONE_CONFIG="$TEMP_RCLONE_CONFIG"

echo ""
echo "Testing streaming backup locally..."
echo "Dataset: $TEST_DATASET@$TEST_SNAPSHOT"
echo "Local storage: $LOCAL_DIR"
echo ""

# Create a minimal config.env for local testing
TEMP_CONFIG="/tmp/offsite-local-config-$(date +%s).env"
cat > "$TEMP_CONFIG" << EOF
# Temporary local config for testing
B2_KEY_ID="test"
B2_APPLICATION_KEY="test"  
B2_BUCKET_NAME="test-bucket"
RCLONE_REMOTE="localtest:$LOCAL_DIR/zfs-backups"

# Override Scaleway to use local as well
SCW_ACCESS_KEY="test"
SCW_SECRET_KEY="test"
SCALEWAY_REMOTE="localtest:$LOCAL_DIR/zfs-backups"

# Encryption key
AGE_PUBLIC_KEY_FILE="$HOME/.config/age/zfs-backup.pub"
AGE_PRIVATE_KEY_FILE="$HOME/.config/age/zfs-backup.txt"
EOF

echo "Temporary config: $TEMP_CONFIG"

# Function to run backup with local config
run_local_backup() {
    echo "Starting local backup test..."
    
    # Temporarily replace the config
    if [[ -f ~/.config/offsite/config.env ]]; then
        cp ~/.config/offsite/config.env ~/.config/offsite/config.env.backup
    fi
    
    cp "$TEMP_CONFIG" ~/.config/offsite/config.env
    
    # Run the backup with only local provider to avoid connection issues
    echo "Running: ./offsite --backup ${TEST_DATASET}@${TEST_SNAPSHOT} --provider backblaze"
    if ./offsite --backup "${TEST_DATASET}@${TEST_SNAPSHOT}" --provider backblaze; then
        echo "✓ Local backup completed"
        BACKUP_SUCCESS=true
    else
        echo "✗ Local backup failed"
        BACKUP_SUCCESS=false
    fi
    
    # Restore original config
    if [[ -f ~/.config/offsite/config.env.backup ]]; then
        mv ~/.config/offsite/config.env.backup ~/.config/offsite/config.env
    fi
    
    return 0
}

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    rm -f "$TEMP_RCLONE_CONFIG"
    rm -f "$TEMP_CONFIG"
    
    if [[ -n "${LOCAL_DIR:-}" ]]; then
        echo "Local test files in: $LOCAL_DIR"
        echo "Files created:"
        find "$LOCAL_DIR" -type f | head -10
        echo ""
        echo "Total size:"
        du -sh "$LOCAL_DIR" 2>/dev/null || echo "Directory not found"
        echo ""
        read -p "Delete local test files? (y/N): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            rm -rf "$LOCAL_DIR"
            echo "✓ Cleaned up"
        else
            echo "Local files preserved at: $LOCAL_DIR"
        fi
    fi
}

# Set up cleanup trap
trap cleanup EXIT

# Run the test
run_local_backup

echo ""
echo "=== Local Test Complete ==="

if [[ "${BACKUP_SUCCESS:-false}" == "true" ]]; then
    echo "✓ Backup succeeded - check the files above for shard details"
    echo "  This tests streaming, byte offsets, and completion logic"
    echo "  without using internet bandwidth"
else
    echo "✗ Backup failed - debug the streaming pipeline locally"
fi