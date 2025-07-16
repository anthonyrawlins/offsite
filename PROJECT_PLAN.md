# Project: offsite

a **full ZFS cloud backup system** with:

* ✅ Automatic snapshots of all datasets
* 🔁 Incremental backup support
* 🔐 Encrypted stream using [`age`](https://age-encryption.org/)
* ☁️ Upload to S3/Backblaze/etc using `rclone`
* 🧹 Retention policy to keep recent backups only
* 🛠 Restore script to pull & decrypt any backup

---

## ✅ Directory Structure (in cloud remote)

```
cloudremote:zfs-backups/
  rust/containers/
    full-20250715-000001.zfs.gz.age
    incr-20250716-000001.zfs.gz.age
  rust/projects/
    ...
```

---

## 🗝 Requirements

* \[`zfs`], \[`rclone`], \[`age`], \[`gzip`] installed
* `rclone` remote named (e.g., `cloudremote`)
* Age keypair:

  ```bash
  age-keygen -o ~/.config/age/zfs-backup.txt
  cat ~/.config/age/zfs-backup.txt | grep "# public key:" | cut -d" " -f4 > ~/.config/age/zfs-backup.pub
  ```

---

## 📦 `zfs-backup-all.sh`

```bash
#!/bin/bash
set -euo pipefail

# === CONFIG ===
POOL="rust"
RCLONE_REMOTE="cloudremote:zfs-backups"
AGE_PUBLIC_KEY_FILE="$HOME/.config/age/zfs-backup.pub"
SNAP_PREFIX="auto"
RETENTION_DAYS=14

# === FUNCTIONS ===

make_snapshot() {
  local dataset="$1"
  local snapname="${SNAP_PREFIX}-$(date +%Y%m%d-%H%M%S)"
  zfs snapshot "${dataset}@${snapname}"
  echo "$snapname"
}

get_latest_remote_snapshot() {
  local dataset_path="$1"
  rclone lsf "${RCLONE_REMOTE}/${dataset_path}/" 2>/dev/null | grep -E '^incr-|^full-' | sort | tail -n 1
}

send_snapshot() {
  local dataset="$1"
  local snap="$2"
  local dataset_path="${dataset//\//_}"
  local remote_path="${RCLONE_REMOTE}/${dataset_path}"
  local tmpfile="/tmp/${dataset_path}-${snap}.zfs.gz.age"

  echo "[+] Sending snapshot $dataset@$snap"

  # Detect previous snapshot if any
  local prev_snap=$(zfs list -H -t snapshot -o name -s creation | grep "^${dataset}@${SNAP_PREFIX}-" | grep -B1 "$snap" | head -n1 | awk -F@ '{print $2}' || true)

  local send_cmd=""
  if [[ -n "$prev_snap" ]]; then
    echo "    Incremental from $prev_snap"
    send_cmd="zfs send -I @${prev_snap} ${dataset}@${snap}"
    local prefix="incr"
  else
    echo "    Full send"
    send_cmd="zfs send ${dataset}@${snap}"
    local prefix="full"
  fi

  # Encrypt and write
  agekey=$(cat "$AGE_PUBLIC_KEY_FILE")
  eval "$send_cmd" | gzip | age -r "$agekey" > "$tmpfile"

  # Upload
  rclone copy "$tmpfile" "${remote_path}/${prefix}-${snap}.zfs.gz.age"
  rm "$tmpfile"
}

cleanup_old_local_snaps() {
  local dataset="$1"
  zfs list -H -t snapshot -o name -s creation | grep "^${dataset}@${SNAP_PREFIX}-" | while read snap; do
    snap_time=$(echo "$snap" | awk -F@ '{print $2}' | cut -d'-' -f2)
    snap_date=$(date -d "$snap_time" +%s)
    now=$(date +%s)
    age_days=$(( (now - snap_date) / 86400 ))
    if (( age_days > RETENTION_DAYS )); then
      echo "[-] Destroying old snapshot $snap"
      zfs destroy "$snap"
    fi
  done
}

# === MAIN ===

zfs list -H -o name -t filesystem -r "$POOL" | while read dataset; do
  echo "=== $dataset ==="
  snapname=$(make_snapshot "$dataset")
  send_snapshot "$dataset" "$snapname"
  cleanup_old_local_snaps "$dataset"
done

echo "[+] All datasets backed up."
```

---

## ♻️ Restore Script: `zfs-cloud-restore.sh`

```bash
#!/bin/bash
set -euo pipefail

# === CONFIG ===
AGE_PRIVATE_KEY_FILE="$HOME/.config/age/zfs-backup.txt"
RCLONE_REMOTE="cloudremote:zfs-backups"
TMPFILE="/tmp/restore.zfs.gz.age"

# === INPUTS ===
DATASET_PATH="$1"         # e.g., rust_data
BACKUP_FILE="$2"          # e.g., full-20250715-000001.zfs.gz.age
TARGET_DATASET="$3"       # e.g., rust/data-restored

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <dataset_path> <backup_file> <target_dataset>"
  echo "Example: $0 rust_data full-20250715-000001.zfs.gz.age rust/data-restored"
  exit 1
fi

# === RESTORE ===
rclone copy "${RCLONE_REMOTE}/${DATASET_PATH}/${BACKUP_FILE}" "$TMPFILE"
echo "[+] Decrypting and restoring to $TARGET_DATASET"
age -d -i "$AGE_PRIVATE_KEY_FILE" "$TMPFILE" | gunzip | zfs recv -F "$TARGET_DATASET"
rm "$TMPFILE"
echo "[+] Restore complete"
```

---

## 📋 Add Cron or Systemd Timer (optional)

### Example: `/etc/cron.daily/zfs-cloud-backup`

```bash
#!/bin/bash
/usr/local/bin/zfs-backup-all.sh >> /var/log/zfs-backup.log 2>&1
```

---

## 🔐 Key Safety Tip

Store your `zfs-backup.txt` private key:

* **Off the machine**
* In a password manager
* Or encrypted and backed up to another secure location

---

## 🔄 Optional Extensions

* 🗓 Add monthly full / daily incremental strategy
* ☁️ Email notification when backup succeeds/fails

---

I would like a version of this wrapped as a single `.deb` installer for clean deployment for use across multiple machines.
