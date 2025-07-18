#!/bin/bash

# Improved streaming function that avoids race conditions
# This replaces the problematic stream_zfs_to_cloud function

stream_zfs_to_cloud_improved() {
    local prev_snap="$1"
    local current_snap="$2"
    local backup_prefix="$3"
    local rclone_remote="$4"
    local dataset_path="$5"
    local agekey="$6"
    local backup_type="$7"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S')     Starting improved streaming backup ($backup_type)"
    
    # Get dataset size for shard calculation
    local dataset_size_bytes=$(zfs get -H -o value -p used "${current_snap%@*}" 2>/dev/null || echo "1073741824")
    local dynamic_shard_size_bytes=$((dataset_size_bytes / 100))
    local min_shard_size=$((10 * 1024 * 1024))      # 10MB minimum
    local max_shard_size=$((50 * 1024 * 1024 * 1024)) # 50GB maximum
    
    if [[ $dynamic_shard_size_bytes -lt $min_shard_size ]]; then
        dynamic_shard_size_bytes=$min_shard_size
    elif [[ $dynamic_shard_size_bytes -gt $max_shard_size ]]; then
        dynamic_shard_size_bytes=$max_shard_size
    fi
    
    # Create temporary directory
    local temp_dir=$(mktemp -d)
    echo "$(date '+%Y-%m-%d %H:%M:%S')     Temp directory: $temp_dir"
    
    # Cleanup function
    cleanup_temp() {
        rm -rf "$temp_dir"
    }
    trap cleanup_temp EXIT
    
    # SOLUTION 1: Use a simpler pipeline approach
    # Instead of background splitting with complex timing, use a straightforward pipeline
    echo "$(date '+%Y-%m-%d %H:%M:%S')     Creating ZFS stream pipeline..."
    
    # Create the command pipeline that processes shards sequentially
    zfs send "$current_snap" | {
        local shard_num=1
        local total_shards=0
        
        # Read from stdin and process in chunks
        while true; do
            local shard_file="$temp_dir/shard-$(printf '%03d' $shard_num)"
            
            # Read exactly one shard's worth of data
            if ! dd bs="$dynamic_shard_size_bytes" count=1 of="$shard_file" 2>/dev/null; then
                # dd returns non-zero when it reaches EOF, check if we got any data
                if [[ -s "$shard_file" ]]; then
                    # Process the final partial shard
                    echo "$(date '+%Y-%m-%d %H:%M:%S')       Processing final shard $shard_num..."
                    process_shard "$shard_file" "$shard_num" "$backup_prefix" "$rclone_remote" "$dataset_path" "$agekey"
                    ((total_shards++))
                else
                    # No data read, we're done
                    rm -f "$shard_file"
                fi
                break
            fi
            
            # Process the shard
            echo "$(date '+%Y-%m-%d %H:%M:%S')       Processing shard $shard_num..."
            if process_shard "$shard_file" "$shard_num" "$backup_prefix" "$rclone_remote" "$dataset_path" "$agekey"; then
                ((total_shards++))
                ((shard_num++))
            else
                echo "$(date '+%Y-%m-%d %H:%M:%S')       ✗ Failed to process shard $shard_num"
                return 1
            fi
        done
        
        echo "$(date '+%Y-%m-%d %H:%M:%S')     ✓ Streaming complete: $total_shards shards processed"
    }
}

# Helper function to process individual shards
process_shard() {
    local shard_file="$1"
    local shard_num="$2"
    local backup_prefix="$3"
    local rclone_remote="$4"
    local dataset_path="$5"
    local agekey="$6"
    
    local output_file="${backup_prefix}-s$(printf '%03d' $shard_num).zfs.gz.age"
    local shard_size=$(stat -c%s "$shard_file" 2>/dev/null || echo "0")
    
    # Skip if shard is empty
    if [[ $shard_size -eq 0 ]]; then
        rm -f "$shard_file"
        return 1
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S')         Uploading $(numfmt --to=iec $shard_size)..."
    
    # Process: compress -> encrypt -> upload
    if gzip < "$shard_file" | age -r "$agekey" | rclone rcat "${rclone_remote}/${dataset_path}/${output_file}"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S')         ✓ Uploaded $output_file"
        rm -f "$shard_file"
        return 0
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S')         ✗ Failed to upload $output_file"
        rm -f "$shard_file"
        return 1
    fi
}

# ALTERNATIVE SOLUTION 2: Use split with proper synchronization
stream_zfs_to_cloud_alternative() {
    local prev_snap="$1"
    local current_snap="$2"
    local backup_prefix="$3"
    local rclone_remote="$4"
    local dataset_path="$5"
    local agekey="$6"
    local backup_type="$7"
    
    echo "$(date '+%Y-%m-%d %H:%M:%S')     Starting alternative streaming backup ($backup_type)"
    
    # Calculate shard size (same as before)
    local dataset_size_bytes=$(zfs get -H -o value -p used "${current_snap%@*}" 2>/dev/null || echo "1073741824")
    local dynamic_shard_size_bytes=$((dataset_size_bytes / 100))
    local min_shard_size=$((10 * 1024 * 1024))
    local max_shard_size=$((50 * 1024 * 1024 * 1024))
    
    if [[ $dynamic_shard_size_bytes -lt $min_shard_size ]]; then
        dynamic_shard_size_bytes=$min_shard_size
    elif [[ $dynamic_shard_size_bytes -gt $max_shard_size ]]; then
        dynamic_shard_size_bytes=$max_shard_size
    fi
    
    local temp_dir=$(mktemp -d)
    echo "$(date '+%Y-%m-%d %H:%M:%S')     Temp directory: $temp_dir"
    
    cleanup_temp() {
        rm -rf "$temp_dir"
    }
    trap cleanup_temp EXIT
    
    # Use split in the foreground and process results after completion
    echo "$(date '+%Y-%m-%d %H:%M:%S')     Creating all shards first..."
    if ! zfs send "$current_snap" | split -b "$dynamic_shard_size_bytes" --numeric-suffixes=1 --suffix-length=3 - "$temp_dir/shard-"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S')     ✗ Failed to create shards"
        return 1
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S')     Processing created shards..."
    local shard_num=1
    local total_shards=0
    
    # Process all created shards
    for shard_file in "$temp_dir"/shard-*; do
        [[ -f "$shard_file" ]] || continue
        
        echo "$(date '+%Y-%m-%d %H:%M:%S')       Processing shard $shard_num..."
        if process_shard "$shard_file" "$shard_num" "$backup_prefix" "$rclone_remote" "$dataset_path" "$agekey"; then
            ((total_shards++))
            ((shard_num++))
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S')       ✗ Failed to process shard $shard_num"
            return 1
        fi
    done
    
    echo "$(date '+%Y-%m-%d %H:%M:%S')     ✓ Streaming complete: $total_shards shards processed"
}