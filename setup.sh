#!/bin/bash
set -euo pipefail

# Setup script for offsite backup system
# Configures ZFS cloud backups to Backblaze B2 and/or Scaleway

echo "=== Offsite Backup System Setup ==="
echo "This script will set up ZFS cloud backups with streaming chunked encryption"
echo "💡 New streaming approach: No large temp files required!"
echo ""

# Check if running as root for some operations
if [[ $EUID -eq 0 ]]; then
    echo "WARNING: Running as root. Some files will be created in root's home directory."
    echo "Consider running as your regular user and using sudo when needed."
    echo ""
fi

# Create directories
echo "[1/8] Creating directories..."
mkdir -p ~/.config/age
mkdir -p ~/.config/rclone
mkdir -p ~/.config/offsite
echo "✓ Directories created"

# Install dependencies
echo "[2/8] Checking dependencies..."
MISSING_DEPS=()

command -v zfs >/dev/null 2>&1 || MISSING_DEPS+=("zfsutils-linux")
command -v rclone >/dev/null 2>&1 || MISSING_DEPS+=("rclone")
command -v age >/dev/null 2>&1 || MISSING_DEPS+=("age")
command -v gzip >/dev/null 2>&1 || MISSING_DEPS+=("gzip")
command -v split >/dev/null 2>&1 || MISSING_DEPS+=("coreutils")

if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
    echo "Missing dependencies: ${MISSING_DEPS[*]}"
    echo "Install with: sudo apt install ${MISSING_DEPS[*]}"
    echo "For age: curl -L https://github.com/FiloSottile/age/releases/latest/download/age-v1.1.1-linux-amd64.tar.gz | tar xz --strip-components=1 -C /usr/local/bin age/age age/age-keygen"
    exit 1
fi
echo "✓ Dependencies available"

# Generate age keys if not present
echo "[3/8] Setting up encryption keys..."
if [[ ! -f ~/.config/age/zfs-backup.txt ]]; then
    echo "Generating new age keypair..."
    age-keygen -o ~/.config/age/zfs-backup.txt
    
    # Extract public key properly (without newline issues)
    grep "# public key:" ~/.config/age/zfs-backup.txt | cut -d" " -f4 | tr -d '\n' > ~/.config/age/zfs-backup.pub
    
    chmod 600 ~/.config/age/zfs-backup.txt
    chmod 644 ~/.config/age/zfs-backup.pub
    echo "✓ New age keypair generated"
    echo "  Public key: $(cat ~/.config/age/zfs-backup.pub)"
else
    echo "✓ Age keys already exist"
    echo "  Public key: $(cat ~/.config/age/zfs-backup.pub)"
fi

# Create configuration template
echo "[4/8] Setting up configuration..."
if [[ ! -f ~/.config/offsite/config.env ]]; then
    cat > ~/.config/offsite/config.env << 'EOF'
# Offsite Backup Configuration
# Edit this file with your cloud storage credentials

# === ZFS Configuration ===
ZFS_POOL="rust"
ZFS_SNAP_PREFIX="auto"
ZFS_RETENTION_DAYS=14

# === Backblaze B2 Configuration ===
# Get these from your Backblaze B2 account
B2_KEY_ID="your_key_id_here"
B2_APPLICATION_KEY="your_application_key_here"
B2_BUCKET_NAME="your-bucket-name"

# === Scaleway Configuration (Optional) ===
# Uncomment and configure for dual-provider setup
# SCW_ACCESS_KEY="your_scaleway_access_key"
# SCW_SECRET_KEY="your_scaleway_secret_key"
# SCW_BUCKET_NAME="your-scaleway-bucket"

# === Custom Providers (Optional) ===
# Add any custom providers by creating *_REMOTE variables
# AMAZONS3_REMOTE="s3:my-bucket/zfs-backups"
# GOOGLECLOUD_REMOTE="gcs:my-bucket/zfs-backups"
# AZUREBLOB_REMOTE="azureblob:my-container/zfs-backups"

# === rclone Configuration ===
RCLONE_REMOTE="cloudremote:your-bucket-name/zfs-backups"
SCALEWAY_REMOTE="scaleway:your-scaleway-bucket/zfs-backups"

# === Encryption Configuration ===
AGE_PUBLIC_KEY_FILE="$HOME/.config/age/zfs-backup.pub"
AGE_PRIVATE_KEY_FILE="$HOME/.config/age/zfs-backup.txt"

# === Backup Paths ===
# TEMP_DIR: Directory for temporary 1GB chunks during streaming backup
# With streaming approach, only ~1GB space needed (vs full dataset size before)
# Can use /tmp safely now, or set to dedicated location if preferred
TEMP_DIR="/tmp"
EOF
    
    chmod 600 ~/.config/offsite/config.env
    echo "✓ Configuration template created at ~/.config/offsite/config.env"
    echo "  Edit this file with your cloud storage credentials"
    echo "  File permissions set to 600 for security"
else
    echo "✓ Configuration already exists"
fi

# Check for rclone config
echo "[5/8] Checking rclone configuration..."
if ! rclone listremotes 2>/dev/null | grep -q "cloudremote:"; then
    echo "⚠ rclone not configured for 'cloudremote'"
    echo "  Run: rclone config"
    echo "  Create a new remote named 'cloudremote' for your primary provider"
    echo "  Optionally create 'scaleway' remote for dual-provider setup"
else
    echo "✓ rclone 'cloudremote' configured"
fi

# Install production scripts
echo "[6/8] Installing backup scripts..."
if [[ -f "offsite" ]]; then
    sudo cp offsite /usr/local/bin/
    sudo chmod +x /usr/local/bin/offsite
    echo "✓ Production script installed to /usr/local/bin/"
    
    # Check if /usr/local/bin is in PATH
    if [[ ":$PATH:" != *":/usr/local/bin:"* ]]; then
        echo "⚠ /usr/local/bin not in PATH"
        echo "  Add to ~/.bashrc or ~/.zshrc:"
        echo "  export PATH=\"/usr/local/bin:\$PATH\""
    else
        echo "✓ /usr/local/bin is in PATH"
    fi
else
    echo "⚠ Production script not found in current directory"
    echo "  Make sure you're running this from the offsite project directory"
    echo "  Expected file: offsite"
fi

# Setup ZFS permissions
echo "[7/8] Setting up ZFS permissions..."
CURRENT_USER=$(whoami)
if [[ "$CURRENT_USER" != "root" ]]; then
    echo "Setting ZFS permissions for user: $CURRENT_USER"
    
    # Detect ZFS pools
    if command -v zpool >/dev/null 2>&1; then
        POOLS=$(zpool list -H -o name 2>/dev/null || true)
        if [[ -n "$POOLS" ]]; then
            echo "Detected ZFS pools: $POOLS"
            for pool in $POOLS; do
                echo "  Configuring permissions for pool: $pool"
                sudo zfs allow -u "$CURRENT_USER" snapshot,send,mount,hold,destroy,create,receive "$pool" || {
                    echo "  ⚠ Could not set permissions for pool: $pool"
                    echo "    Run manually: sudo zfs allow -u $CURRENT_USER snapshot,send,mount,hold,destroy,create,receive $pool"
                }
            done
            echo "✓ ZFS permissions configured for all pools"
        else
            echo "⚠ No ZFS pools found"
            echo "  Run manually after creating pools: sudo zfs allow -u $CURRENT_USER snapshot,send,mount,hold,destroy,create,receive <pool_name>"
        fi
    else
        echo "⚠ ZFS not available"
        echo "  Install zfsutils-linux first"
    fi
else
    echo "✓ Running as root, ZFS permissions not needed"
fi

# Setup logging
echo "[8/8] Setting up logging..."
if [[ -w /var/log ]]; then
    sudo touch /var/log/offsite-backup.log
    sudo chown "$CURRENT_USER:$CURRENT_USER" /var/log/offsite-backup.log 2>/dev/null || true
    echo "✓ System log file created at /var/log/offsite-backup.log"
else
    echo "✓ Using home directory for logging (no /var/log access)"
fi

echo ""
echo "🎉 Setup complete!"
echo ""
echo "🚀 STREAMING BACKUP READY:"
echo "  • No large temp files required (streams directly to cloud)"
echo "  • Minimal disk usage (only 1GB chunks temporarily)"
echo "  • Efficient memory usage (processes data in streaming chunks)"
echo "  • Resumable backups (skips existing chunks)"
echo ""
# Ask user for their datasets
echo "[Optional] Dataset Configuration:"
echo "Which ZFS datasets would you like to set up for backup?"
echo "Available datasets:"
if command -v zfs >/dev/null 2>&1; then
    zfs list -H -o name -t filesystem 2>/dev/null | head -10 || {
        echo "  (Unable to list datasets - may need ZFS permissions)"
        echo "  Common examples: tank/data, tank/home, rust/projects"
    }
else
    echo "  (ZFS not available)"
fi
echo ""
read -p "Enter datasets to backup (space-separated, or press Enter to skip): " USER_DATASETS
echo ""

if [[ -n "$USER_DATASETS" ]]; then
    echo "Your backup commands:"
    for dataset in $USER_DATASETS; do
        echo "  offsite --backup $dataset"
    done
    echo ""
    echo "Automation (add to crontab for daily backups):"
    for dataset in $USER_DATASETS; do
        echo "  0 2 * * * offsite --backup $dataset --as @\$(date +%Y%m%d)"
    done
    echo ""
fi

echo "Next steps:"
echo "1. Edit ~/.config/offsite/config.env with your cloud storage credentials"
echo "2. Configure rclone if not already done:"
echo "   rclone config"
if [[ -n "$USER_DATASETS" ]]; then
    echo "3. Test backup with your datasets:"
    for dataset in $USER_DATASETS; do
        echo "   offsite --backup $dataset"
    done
else
    echo "3. Test backup with:"
    echo "   offsite --backup <your-dataset-name>"
fi
echo ""
echo "Unified script usage:"
echo "  Backup:  offsite --backup <dataset> [--as @snapshot] [--provider <name>]"
echo "  Restore: offsite --restore <dataset[@backup]> [--as <target>] [--provider <name>]"
echo ""
echo "Examples:"
echo "  offsite --backup tank/data --as @today"
echo "  offsite --restore tank/data                    # Restore to original name"
echo "  offsite --restore tank/data --as tank/new-data # Restore to new name"
echo "  offsite --backup tank/photos --provider scaleway"
echo "  offsite --restore tank/photos@latest-full --as tank/photos-test"
echo ""
echo "🔐 IMPORTANT: Save your age private key securely!"
echo "   Location: ~/.config/age/zfs-backup.txt"
echo "   Without this key, you cannot restore your backups."
echo ""
echo "💡 STREAMING BENEFITS:"
echo "   • Backup 100TB dataset using only ~1GB temp space"
echo "   • No risk of running out of disk space during backup"
echo "   • Faster backups with direct streaming pipeline"
echo "   • Resumable - interruptions don't waste previous work"
echo ""
echo "📖 Documentation: See README.md for detailed usage information"