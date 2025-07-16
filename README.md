# Offsite - ZFS Cloud Backup System

A unified, production-ready ZFS backup system with chunked encryption and multi-provider support.

## Core Scripts

### 1. `offsite-backup`
**Purpose**: Backup a single ZFS dataset to cloud storage

**Usage**: `offsite-backup <dataset> [provider]`

**Examples**:
```bash
offsite-backup tank/important/data
offsite-backup tank/photos scaleway
offsite-backup tank/documents backblaze
offsite-backup tank/media amazonS3
```

**Features**:
- Automatic snapshot creation
- Incremental backups when possible
- Chunked uploads (1GB chunks)
- Individual chunk encryption
- Multi-provider support (backup to "all" by default)
- Resumable backups (skips existing chunks)
- Proper compression and encryption order
- Automatic cleanup of old snapshots

### 2. `offsite-restore`
**Purpose**: Restore a ZFS dataset from cloud storage

**Usage**: `offsite-restore <dataset[@backup]> [provider] [target_dataset]`

**ZFS-style Examples**:
```bash
offsite-restore tank/important/data
offsite-restore tank/photos@latest-full backblaze
offsite-restore tank/docs@full-auto-20250716-161605 scaleway tank/docs-test
```

**ZFS Semantics**:
- `dataset` - Restore full dataset state (latest backup)
- `dataset@latest` - Same as above (ZFS semantics)
- `dataset@latest-full` - Most recent full backup only
- `dataset@backup-name` - Specific backup point in time

**Features**:
- Auto-provider detection
- ZFS-style syntax for intuitive usage
- Chunked downloads with reassembly
- Individual chunk decryption
- Stream reconstitution
- Automatic ZFS receive

## Processing Order

The scripts implement the correct processing order:

**Backup**: `ZFS send → Split → Gzip each chunk → Encrypt each chunk → Upload`
**Restore**: `Download → Decrypt each chunk → Gunzip → Reconstitute → ZFS receive`

## Configuration

Scripts use configuration from: `$HOME/.config/offsite/config.env`

Required configuration:
- Age encryption keys
- Rclone remote configurations
- Provider settings

## Legacy Scripts (Deprecated)

The following scripts are deprecated and should not be used:
- `zfs-backup-*.sh` (old naming)
- `zfs-restore-*.sh` (old naming)  
- `test-*.sh` (testing scripts)
- `*-fixed.sh` (development iterations)

## Key Improvements

1. **Fixed age key newline issue** - Public key is properly trimmed
2. **Correct processing order** - Split before compress/encrypt
3. **Individual chunk encryption** - Each chunk is independently encrypted
4. **Resumable backups** - Automatically skips existing chunks on restart
5. **Proper error handling** - Comprehensive validation
6. **Clean naming** - Consistent `offsite-*` naming convention

## Resumable Backup Support

The system supports resumable backups based on our proven ZFS send stream determinism:

- **Automatic detection** - Checks for existing chunks before upload
- **Safe resumption** - Same snapshot always produces identical streams
- **Chunk boundary consistency** - Identical byte offsets guaranteed
- **Atomic uploads** - RClone ensures existing chunks are complete
- **Bandwidth savings** - Only uploads missing chunks on restart

**Example Resume Scenario:**
```bash
# Initial backup interrupted after uploading 5 of 10 chunks
offsite --backup tank/data

# Resume automatically skips existing chunks 001-005
offsite --backup tank/data  # Continues from chunk 006
```

## Notes

- All scripts have been tested with real data
- Backup/restore cycle proven to work end-to-end
- Proper chunk boundaries and compression ratios
- No 220-byte encryption artifacts
- Stream integrity verified through diff comparison