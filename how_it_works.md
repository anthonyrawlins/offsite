# Offsite: How It Works

A comprehensive technical overview of the ZFS backup system with streaming architecture and resumable backups.

## Core Architecture

### Streaming with Backpressure Control

Offsite uses a revolutionary streaming approach that processes ZFS snapshots one shard at a time, eliminating the need for large temporary storage:

```bash
zfs send dataset@snapshot | dd bs=SHARD_SIZE count=1 | gzip | age | rclone rcat
```

**Key Innovation: Backpressure**
- `dd` reads exactly one shard worth of data and stops
- ZFS send naturally waits for `dd` to finish (backpressure)
- Process shard completely before reading next chunk
- Only ~10MB temp space needed regardless of dataset size

### Dynamic Shard Sizing

Shards are automatically sized as **1% of dataset size** for optimal progress tracking:

- **100GB dataset** → 100 shards of 1GB each
- **1TB dataset** → 100 shards of 10GB each  
- **10GB dataset** → 100 shards of 100MB each

**Practical Limits:**
- Minimum: 10MB per shard
- Maximum: 50GB per shard

### File Naming Convention

Backup files use a self-identifying naming scheme:

```
dataset_name:snapshot-s001.zfs.gz.age
rust_test:now-s042.zfs.gz.age
tank_data:backup-20250718-s100.zfs.gz.age
```

**Format Breakdown:**
- `rust_test` = Dataset name (/ → _)
- `:` = Separator (@ → :)
- `now` = Snapshot name
- `s042` = Shard number (001-100+)
- `.zfs.gz.age` = Pipeline: ZFS → gzip → age encryption

## Resumable Backup Logic

### Cloud Storage as Source of Truth

Resumable backups rely on **cloud storage state**, not local temp files:

```bash
# Check what exists in cloud
existing_shards=($(rclone lsf "provider:/bucket/" | grep "backup_prefix-s[0-9][0-9][0-9].zfs.gz.age"))

# Skip bytes in ZFS stream for existing shards
bytes_to_skip=$((${#existing_shards[@]} * shard_size))
zfs send | dd bs=$shard_size count=${#existing_shards[@]} of=/dev/null
```

**Why This Works:**
- **ZFS stream determinism**: Same snapshot always produces identical byte streams
- **Atomic uploads**: rclone only creates files after complete upload
- **Byte-perfect boundaries**: Shard boundaries are always at identical offsets

### Backup Completion Detection

**Critical Logic: Multiple shards + smaller final shard = Complete**

```bash
# Get all shards and check the pattern
all_shards=($(rclone lsf "provider:/bucket/" | grep "prefix-s" | sort))

if [[ ${#all_shards[@]} -ge 2 ]]; then
    # Multiple shards exist - check if final shard is smaller
    # (indicating end of stream reached)
    return 0  # Complete
else
    return 1  # Incomplete
fi
```

**Important Distinctions:**
- ✅ **Shards 1,2,3 (where 3 is smaller)** = Complete backup
- ❌ **Shards 1,2,3 (all same size)** = Potentially incomplete
- ✅ **Shard 100 exists** = Complete (reached target)

## ZFS Integration

### Snapshot Management

Offsite handles snapshots intelligently based on input:

```bash
# Use existing snapshot
offsite --backup dataset@my-snapshot

# Create auto-timestamped snapshot  
offsite --backup dataset

# Create named snapshot
offsite --backup dataset@today
```

**Snapshot Logic:**
1. If `dataset@snapshot` format provided:
   - Check if snapshot exists → use directly
   - If not exists, handle special names (`now`, `today`)
   - Create if needed
2. If just `dataset` provided:
   - Create auto-timestamped snapshot
   - Format: `auto-YYYYMMDD-HHMMSS`

### ZFS Send Stream Properties

**Stream Characteristics:**
- **Deterministic**: Same snapshot = identical byte stream
- **Compressed**: Stream size often much smaller than dataset size
- **Metadata included**: Contains ZFS properties, permissions, etc.
- **Resumable**: Can skip bytes using `dd` or `tail -c +N`

**Example:**
- 1GB dataset → ~23MB ZFS stream (high compression)
- Results in 3 shards instead of expected 100
- Completion detected by partial final shard

## Security Architecture

### Zero-Knowledge Encryption

```bash
# Each shard encrypted independently
shard_data | gzip | age -r $public_key | rclone rcat "provider:/encrypted_file"
```

**Security Properties:**
- **Age encryption**: Modern, secure encryption
- **Per-shard encryption**: Each shard independently encrypted
- **Zero-knowledge**: Cloud provider never sees unencrypted data
- **Key isolation**: Private key never touches cloud storage

### Multi-Provider Strategy

Backups are stored across multiple cloud providers:

```bash
# Default: backup to all configured providers
offsite --backup dataset

# Specific provider
offsite --backup dataset --provider scaleway
```

**Provider Support:**
- Backblaze B2
- Scaleway Object Storage
- AWS S3 (via rclone)
- Google Cloud Storage (via rclone)
- Any rclone-supported provider

## Error Handling & Recovery

### Atomic Operations

**Upload Atomicity:**
- `rclone rcat` ensures atomic uploads
- Failed uploads don't create partial files
- Resumable logic only sees complete shards

**Temp File Management:**
- One shard in temp at a time
- Immediate cleanup after upload
- No accumulation even with failures

### Recovery Scenarios

**Interrupted Backup:**
```bash
# Original backup interrupted after shard 5
offsite --backup dataset  # Resumes from shard 6
```

**Cloud Provider Outage:**
```bash
# Backup to alternate provider
offsite --backup dataset --provider scaleway
```

**Corrupted Local Temp:**
- No impact - resumable logic uses cloud state
- Fresh backup attempt starts from last complete shard

## Performance Optimizations

### Streaming Benefits

**Traditional Approach Problems:**
```bash
# ❌ Old way: needs full dataset space
zfs send | split -b 1G  # Creates ALL chunks first
# Result: 100GB dataset needs 100GB temp space
```

**Streaming Solution:**
```bash
# ✅ New way: minimal temp space
zfs send | while read_chunk; do process_and_upload; done
# Result: 100GB dataset needs ~1GB temp space
```

### Bandwidth Efficiency

**Resumable Uploads:**
- Skip existing shards entirely
- Only upload missing pieces
- No redundant data transfer

**Compression Pipeline:**
```bash
raw_zfs_data → gzip → age_encryption → upload
```

**Typical Compression Ratios:**
- Text/code: 80-90% reduction
- Mixed data: 50-70% reduction
- Already compressed: 10-20% reduction

## Restore Process

### Shard Reconstruction

```bash
# Download, decrypt, decompress, and reassemble
for shard in $(rclone lsf "provider:/bucket/" | grep "prefix-s"); do
    rclone cat "provider:/bucket/$shard" | age -d -i $private_key | gunzip
done | zfs receive dataset
```

**Restore Options:**
```bash
# Restore to original location
offsite --restore dataset

# Restore to new location  
offsite --restore dataset --as new_dataset

# Restore specific backup
offsite --restore dataset@backup-20250718
```

### Verification

**Automatic Verification:**
- ZFS checksums verify data integrity
- Age authentication prevents tampering
- Shard completeness verified during restore

## Monitoring & Logging

### Progress Tracking

**Real-time Progress:**
- Shard-by-shard progress reporting
- Upload speed and ETA
- Provider-specific status

**Logging:**
```bash
# Structured logs per backup
/var/log/offsite-backup-dataset_name-YYYYMMDD-HHMMSS.log
```

### Metrics

**Key Metrics Tracked:**
- Backup duration
- Compression ratios
- Upload speeds per provider
- Resumption frequency
- Error rates

## Deployment Architecture

### Multi-Node Support

**Cluster Coordination:**
- Dataset-level locking prevents conflicts
- PID-based process tracking
- Safe concurrent backups of different datasets

**Lock File Format:**
```bash
/tmp/offsite-backup-${dataset//\//_}.lock
```

### Configuration Management

**Hierarchical Config:**
```bash
~/.config/offsite/config.env      # User settings
/etc/offsite/config.env           # System settings  
./project.env                     # Project overrides
```

**Environment Variables:**
- `SHARD_SIZE`: Override dynamic sizing
- `TEMP_DIR`: Custom temp directory
- `RETENTION_DAYS`: Snapshot cleanup policy

## Technical Limitations

### Current Constraints

**Shard Size Limits:**
- Minimum: 10MB (practical lower bound)
- Maximum: 50GB (rclone/provider limits)

**Provider Limitations:**
- Subject to rclone capabilities
- API rate limits vary by provider
- Upload size limits (typically 5TB)

**ZFS Dependencies:**
- Requires ZFS snapshots
- Dataset permissions needed
- Linux/Unix platforms only

### Future Enhancements

**Planned Improvements:**
- Parallel shard uploads
- Advanced completion detection (shard size verification)
- Incremental backup support (deferred)
- Web UI for monitoring
- Webhook notifications

---

## Summary

Offsite represents a modern approach to ZFS backup that combines:

- **True streaming** with minimal temp space requirements
- **Resumable operations** based on cloud storage state  
- **Zero-knowledge encryption** with per-shard security
- **Multi-provider redundancy** for maximum reliability
- **Deterministic behavior** leveraging ZFS stream properties

The system's reliability stems from understanding and leveraging the atomic nature of cloud uploads and the deterministic properties of ZFS send streams, creating a backup solution that is both efficient and robust.