#!/bin/bash
set -euo pipefail

# Create a temporary local rclone provider for testing
# This avoids internet bandwidth usage during development

echo "=== Setting up Local Test Provider ==="

# Create temporary local storage directory
LOCAL_STORAGE_DIR="/tmp/offsite-local-test"
mkdir -p "$LOCAL_STORAGE_DIR"

echo "Local storage directory: $LOCAL_STORAGE_DIR"

# Create a temporary rclone config for local testing
RCLONE_CONFIG_FILE="/tmp/rclone-local-test.conf"

cat > "$RCLONE_CONFIG_FILE" << 'EOF'
[local-test]
type = local

[local-scaleway]
type = local
EOF

echo "Temporary rclone config created: $RCLONE_CONFIG_FILE"

# Export the custom config
export RCLONE_CONFIG="$RCLONE_CONFIG_FILE"

echo ""
echo "✓ Local test provider ready!"
echo ""
echo "Usage:"
echo "  1. Set environment:"
echo "     export RCLONE_CONFIG=\"$RCLONE_CONFIG_FILE\""
echo ""
echo "  2. Test with local providers:"
echo "     ./offsite --backup rust/test@now --provider local-test"
echo ""
echo "  3. View results:"
echo "     ls -la $LOCAL_STORAGE_DIR/"
echo ""
echo "  4. Cleanup when done:"
echo "     rm -rf $LOCAL_STORAGE_DIR"
echo "     rm -f $RCLONE_CONFIG_FILE"
echo ""
echo "Note: This bypasses internet uploads and saves to local filesystem"