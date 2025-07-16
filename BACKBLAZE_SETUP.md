# Backblaze B2 Configuration for Offsite

## Prerequisites

1. Backblaze B2 account
2. Application Key ID and Application Key
3. rclone installed

## Step 1: Create Backblaze B2 Bucket

1. Log into Backblaze B2 console
2. Create a new bucket (e.g., `zfs-backups-{hostname}`)
3. Note the bucket name and region

## Step 2: Generate Application Keys

1. Go to App Keys in B2 console
2. Create new application key with access to your bucket
3. Save the Key ID and Application Key securely

## Step 3: Configure rclone

```bash
rclone config

# Choose: n) New remote
# Name: cloudremote
# Storage: b2
# Application Key ID: [your key id]
# Application Key: [your application key]
# Advanced config: No
```

Or configure directly:

```bash
mkdir -p ~/.config/rclone
cat > ~/.config/rclone/rclone.conf << 'EOF'
[cloudremote]
type = b2
account = YOUR_KEY_ID
key = YOUR_APPLICATION_KEY
hard_delete = false
EOF
```

## Step 4: Test Configuration

```bash
# Test connection
rclone lsd cloudremote:

# Create test directory structure
rclone mkdir cloudremote:zfs-backups

# Verify
rclone ls cloudremote:zfs-backups
```

## Step 5: Update Backup Script Configuration

The script in PROJECT_PLAN.md already uses `RCLONE_REMOTE="cloudremote:zfs-backups"` which matches our setup.

## Security Notes

- Store keys in secrets directory: `~/AI/secrets/backblaze/`
- Set proper permissions: `chmod 600 ~/.config/rclone/rclone.conf`
- Consider using environment variables for keys instead of config file

## Cost Optimization

- B2 charges for storage and downloads
- Keep retention policy reasonable (14 days default)
- Monitor usage in B2 console