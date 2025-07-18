#!/bin/bash
set -euo pipefail

# Test script to verify ZFS stream determinism and byte skipping behavior
echo "=== ZFS Stream Determinism Test ==="
echo ""

SNAPSHOT="rust/test@now"
TEST_DIR="/tmp/stream-test-$(date +%s)"
mkdir -p "$TEST_DIR"

echo "Test directory: $TEST_DIR"
echo "Testing snapshot: $SNAPSHOT"
echo ""

# Test 1: Generate same stream twice and compare sizes
echo "[Test 1] ZFS Stream Determinism Check"
echo "Generating stream 1..."
zfs send "$SNAPSHOT" > "$TEST_DIR/stream1.zfs"
STREAM1_SIZE=$(stat -c%s "$TEST_DIR/stream1.zfs")

echo "Generating stream 2..."  
zfs send "$SNAPSHOT" > "$TEST_DIR/stream2.zfs"
STREAM2_SIZE=$(stat -c%s "$TEST_DIR/stream2.zfs")

echo "Stream 1 size: $(numfmt --to=iec $STREAM1_SIZE)"
echo "Stream 2 size: $(numfmt --to=iec $STREAM2_SIZE)"

if [[ $STREAM1_SIZE -eq $STREAM2_SIZE ]]; then
    echo "✓ Stream sizes are identical"
else
    echo "✗ Stream sizes differ! This breaks determinism assumption"
    exit 1
fi

# Test 2: Binary comparison
echo ""
echo "[Test 2] Binary Content Comparison"
if cmp -s "$TEST_DIR/stream1.zfs" "$TEST_DIR/stream2.zfs"; then
    echo "✓ Streams are binary identical"
else
    echo "✗ Streams differ! This breaks determinism assumption"
    exit 1
fi

# Test 3: Test our shard size calculation vs actual stream
echo ""
echo "[Test 3] Shard Size Calculation vs Reality"
DATASET_SIZE=$(zfs get -H -o value -p used "rust/test" 2>/dev/null || echo "1073741824")
ESTIMATED_SHARD_SIZE=$((DATASET_SIZE / 100))
MIN_SHARD_SIZE=$((10 * 1024 * 1024))
MAX_SHARD_SIZE=$((50 * 1024 * 1024 * 1024))

if [[ $ESTIMATED_SHARD_SIZE -lt $MIN_SHARD_SIZE ]]; then
    SHARD_SIZE=$MIN_SHARD_SIZE
elif [[ $ESTIMATED_SHARD_SIZE -gt $MAX_SHARD_SIZE ]]; then
    SHARD_SIZE=$MAX_SHARD_SIZE
else
    SHARD_SIZE=$ESTIMATED_SHARD_SIZE
fi

echo "Dataset used size: $(numfmt --to=iec $DATASET_SIZE)"
echo "Estimated shard size: $(numfmt --to=iec $SHARD_SIZE)"
echo "Actual stream size: $(numfmt --to=iec $STREAM1_SIZE)"
echo "Expected shards: $((STREAM1_SIZE / SHARD_SIZE + 1))"
echo ""

# Test 4: Simulate our chunking approach
echo "[Test 4] Simulate Current Chunking Approach"
cd "$TEST_DIR"
split -b "$SHARD_SIZE" --numeric-suffixes=1 --suffix-length=3 stream1.zfs "real-shard-"

echo "Real shards created:"
for shard in real-shard-*; do
    [[ -f "$shard" ]] || continue
    SIZE=$(stat -c%s "$shard")
    echo "  $shard: $(numfmt --to=iec $SIZE)"
done

# Test 5: Test byte skipping behavior
echo ""
echo "[Test 5] Byte Skipping Test"
REAL_SHARDS=(real-shard-*)
NUM_SHARDS=${#REAL_SHARDS[@]}

echo "Simulating skip of first $((NUM_SHARDS - 1)) shards..."

# Calculate actual bytes to skip (sum of all but last shard)
ACTUAL_BYTES_TO_SKIP=0
for ((i=0; i<NUM_SHARDS-1; i++)); do
    SHARD_SIZE_ACTUAL=$(stat -c%s "${REAL_SHARDS[$i]}")
    ACTUAL_BYTES_TO_SKIP=$((ACTUAL_BYTES_TO_SKIP + SHARD_SIZE_ACTUAL))
done

echo "Actual bytes to skip: $(numfmt --to=iec $ACTUAL_BYTES_TO_SKIP)"

# Our current (wrong) calculation
WRONG_BYTES_TO_SKIP=$(((NUM_SHARDS - 1) * SHARD_SIZE))
echo "Our current calculation: $(numfmt --to=iec $WRONG_BYTES_TO_SKIP)"

echo ""
echo "Testing dd skip with correct bytes..."
dd bs=1 count=$ACTUAL_BYTES_TO_SKIP if=stream1.zfs of=/dev/null 2>/dev/null
dd bs=1 skip=$ACTUAL_BYTES_TO_SKIP if=stream1.zfs of=remaining-correct.zfs 2>/dev/null

echo "Testing dd skip with our wrong calculation..."
if [[ $WRONG_BYTES_TO_SKIP -lt $STREAM1_SIZE ]]; then
    dd bs=1 skip=$WRONG_BYTES_TO_SKIP if=stream1.zfs of=remaining-wrong.zfs 2>/dev/null
    echo "Wrong skip succeeded (this is the bug!)"
    echo "Remaining after wrong skip: $(stat -c%s remaining-wrong.zfs) bytes"
else
    echo "Wrong skip would exceed stream size (as expected)"
fi

echo "Remaining after correct skip: $(stat -c%s remaining-correct.zfs) bytes"
echo "Expected (last shard): $(stat -c%s "${REAL_SHARDS[-1]}") bytes"

# Compare
if cmp -s "remaining-correct.zfs" "${REAL_SHARDS[-1]}"; then
    echo "✓ Correct skip produces expected last shard"
else
    echo "✗ Correct skip doesn't match expected shard"
fi

echo ""
echo "=== Test Complete ==="
echo "Test files in: $TEST_DIR"
echo "Cleanup with: rm -rf $TEST_DIR"