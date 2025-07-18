#!/bin/bash
set -euo pipefail

# Comprehensive test script for offsite backup system
# Provides setup/teardown and various test scenarios

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DATASET="rust/test"
TEST_SNAPSHOT="now"

echo "=== Offsite Backup Test Suite ==="
echo ""

show_usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  clean           Clean all test shards from cloud storage"
    echo "  test-fresh      Test fresh backup (no existing shards)"
    echo "  test-resume     Test resume functionality"  
    echo "  test-complete   Test completion detection"
    echo "  verify-stream   Verify ZFS stream determinism"
    echo "  list            List current backups"
    echo "  full-cycle      Run complete test cycle (clean + fresh + resume)"
    echo ""
    echo "Test dataset: $TEST_DATASET@$TEST_SNAPSHOT"
}

verify_prerequisites() {
    echo "Verifying prerequisites..."
    
    # Check if we're on the right system
    if [[ ! -f "$HOME/.config/offsite/config.env" ]]; then
        echo "ERROR: Not on ACACIA or config not found"
        echo "Expected: $HOME/.config/offsite/config.env"
        exit 1
    fi
    
    # Check if test dataset exists
    if ! zfs list "$TEST_DATASET" >/dev/null 2>&1; then
        echo "ERROR: Test dataset not found: $TEST_DATASET"
        echo "Available datasets:"
        zfs list -t filesystem | head -10
        exit 1
    fi
    
    # Check if test snapshot exists
    if ! zfs list -t snapshot "${TEST_DATASET}@${TEST_SNAPSHOT}" >/dev/null 2>&1; then
        echo "ERROR: Test snapshot not found: ${TEST_DATASET}@${TEST_SNAPSHOT}"
        echo "Available snapshots for $TEST_DATASET:"
        zfs list -t snapshot | grep "^$TEST_DATASET@" | head -5
        exit 1
    fi
    
    echo "✓ Prerequisites verified"
    echo "  Dataset: $TEST_DATASET"
    echo "  Snapshot: ${TEST_DATASET}@${TEST_SNAPSHOT}"
    echo ""
}

clean_test_shards() {
    echo "=== Cleaning Test Shards ==="
    if [[ -f "$SCRIPT_DIR/cleanup-test-shards.sh" ]]; then
        "$SCRIPT_DIR/cleanup-test-shards.sh"
    else
        echo "ERROR: cleanup-test-shards.sh not found"
        exit 1
    fi
}

test_fresh_backup() {
    echo "=== Testing Fresh Backup ==="
    echo "This should create new shards with byte offset tracking..."
    echo ""
    
    # Run backup with timing
    echo "Starting backup at $(date)"
    start_time=$(date +%s)
    
    if "$SCRIPT_DIR/offsite" --backup "${TEST_DATASET}@${TEST_SNAPSHOT}"; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        echo ""
        echo "✓ Fresh backup completed in ${duration}s"
    else
        echo "✗ Fresh backup failed"
        return 1
    fi
    
    echo ""
    echo "Listing created backups:"
    "$SCRIPT_DIR/offsite" --list-backups
}

test_resume_backup() {
    echo "=== Testing Resume Functionality ==="
    echo "This should detect existing shards and resume properly..."
    echo ""
    
    # Run backup again to test resume
    echo "Starting resume test at $(date)"
    start_time=$(date +%s)
    
    if "$SCRIPT_DIR/offsite" --backup "${TEST_DATASET}@${TEST_SNAPSHOT}"; then
        end_time=$(date +%s)
        duration=$((end_time - start_time))
        echo ""
        echo "✓ Resume test completed in ${duration}s"
    else
        echo "✗ Resume test failed"
        return 1
    fi
}

test_completion_detection() {
    echo "=== Testing Completion Detection ==="
    echo "Running backup again - should detect completion..."
    echo ""
    
    # Run backup a third time - should detect complete
    if "$SCRIPT_DIR/offsite" --backup "${TEST_DATASET}@${TEST_SNAPSHOT}"; then
        echo "✓ Completion detection test done"
    else
        echo "✗ Completion detection test failed"
        return 1
    fi
}

verify_stream_determinism() {
    echo "=== Verifying ZFS Stream Determinism ==="
    
    if [[ -f "$SCRIPT_DIR/test-stream-experiment.sh" ]]; then
        "$SCRIPT_DIR/test-stream-experiment.sh"
    else
        echo "Stream experiment script not found, running manual test..."
        
        TEMP_DIR="/tmp/stream-verify-$(date +%s)"
        mkdir -p "$TEMP_DIR"
        
        echo "Generating two ZFS streams..."
        zfs send "${TEST_DATASET}@${TEST_SNAPSHOT}" > "$TEMP_DIR/stream1.zfs"
        zfs send "${TEST_DATASET}@${TEST_SNAPSHOT}" > "$TEMP_DIR/stream2.zfs"
        
        STREAM1_SIZE=$(stat -c%s "$TEMP_DIR/stream1.zfs")
        STREAM2_SIZE=$(stat -c%s "$TEMP_DIR/stream2.zfs")
        
        echo "Stream 1 size: $(numfmt --to=iec $STREAM1_SIZE)"
        echo "Stream 2 size: $(numfmt --to=iec $STREAM2_SIZE)"
        
        if [[ $STREAM1_SIZE -eq $STREAM2_SIZE ]] && cmp -s "$TEMP_DIR/stream1.zfs" "$TEMP_DIR/stream2.zfs"; then
            echo "✓ ZFS streams are deterministic"
        else
            echo "✗ ZFS streams differ!"
        fi
        
        rm -rf "$TEMP_DIR"
    fi
}

list_backups() {
    echo "=== Current Backups ==="
    "$SCRIPT_DIR/offsite" --list-backups
}

full_test_cycle() {
    echo "=== Running Full Test Cycle ==="
    echo ""
    
    echo "Step 1: Clean existing shards"
    clean_test_shards
    
    echo "Step 2: Test fresh backup"
    test_fresh_backup
    
    echo "Step 3: Test resume functionality"
    test_resume_backup
    
    echo "Step 4: Test completion detection"
    test_completion_detection
    
    echo ""
    echo "=== Test Cycle Complete ==="
    echo "Review the output above for any issues."
}

# Main command processing
if [[ $# -eq 0 ]]; then
    show_usage
    exit 1
fi

verify_prerequisites

case "$1" in
    "clean")
        clean_test_shards
        ;;
    "test-fresh")
        test_fresh_backup
        ;;
    "test-resume")
        test_resume_backup
        ;;
    "test-complete")
        test_completion_detection
        ;;
    "verify-stream")
        verify_stream_determinism
        ;;
    "list")
        list_backups
        ;;
    "full-cycle")
        full_test_cycle
        ;;
    *)
        echo "ERROR: Unknown command: $1"
        echo ""
        show_usage
        exit 1
        ;;
esac