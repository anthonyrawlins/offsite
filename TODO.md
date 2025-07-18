# Offsite v2.0 TODO List

## High Priority - Current Testing Phase

### ✅ Completed
- [x] Test debug version to find where pipeline breaks
- [x] Implement byte offset tracking in shard filenames
- [x] Test new byte offset implementation on ACACIA
- [x] Create cleanup scripts for testing
- [x] Fix continuation problem in streaming loop
- [x] Fix cleanup script rclone configuration
- [x] Fix local backup test configuration
- [x] Add iflag=fullblock to fix partial read issues
- [x] Fix all variable scoping issues in subshell
- [x] Test complete streaming backup with all fixes
- [x] Debug why streaming loop exits after first shard
- [x] Replace dd with head -c for better streaming
- [x] Fix arithmetic expansion causing early exit

### 🔄 In Progress / Pending
- [ ] **Test restore function with new byte offset shards**
  - Test partial restore (with incomplete shard set)
  - Test complete restore (full dataset)
  - Verify byte offset reconstruction works correctly
  - Test restore with different providers

- [ ] **Test missing shard detection and gap filling**
  - Delete one middle shard from cloud storage
  - Run backup again to test gap detection
  - Verify it fills only the missing shard
  - Confirm existing shards after gap are not overwritten

## Medium Priority - Future Features

- [ ] **Add cloud-to-cloud sync feature for provider redundancy**
  - Implement `--sync-providers` command
  - Support direct rclone transfers between cloud providers
  - Add `--repair-provider` for redundancy healing
  - Add `--migrate` for provider-to-provider transfers
  - Save bandwidth with cloud-to-cloud transfers

## Additional Test Scenarios

### Resilience Testing
- [ ] **Resume across reboots**
  - Stop backup mid-stream
  - Restart system
  - Verify backup resumes from exact byte offset

- [ ] **Provider failover testing**
  - Test restore when primary provider is down
  - Test backup when one provider fails
  - Verify graceful degradation

- [ ] **Large dataset completion**
  - Complete full 1.16GB backup (~109 shards)
  - Verify all shards have correct byte offsets
  - Test end-of-stream detection

### Edge Cases
- [ ] **Network interruption handling**
  - Test backup during network drops
  - Verify resume after connectivity restored
  - Test partial shard upload recovery

- [ ] **Storage quota testing**
  - Test behavior when cloud storage is full
  - Verify error handling and cleanup

- [ ] **Concurrent backup prevention**
  - Test multiple backup attempts on same dataset
  - Verify proper locking/conflict detection

## Architecture Improvements (Long-term)

### Performance Optimizations
- [ ] **Parallel provider uploads**
  - Upload same shard to multiple providers simultaneously
  - Implement proper error handling for parallel operations

- [ ] **Adaptive shard sizing**
  - Dynamic shard sizes based on dataset characteristics
  - Optimize for different cloud provider costs

- [ ] **Compression optimization**
  - Test different compression algorithms (zstd, lz4)
  - Benchmark compression vs upload time trade-offs

### User Experience
- [ ] **Progress reporting improvements**
  - Real-time progress bars
  - ETA calculations based on current transfer rates
  - Better error reporting and recovery suggestions

- [ ] **Configuration management**
  - Multi-environment configs (dev/staging/prod)
  - Configuration validation and testing tools

### Monitoring and Observability
- [ ] **Backup verification**
  - Automated restore testing
  - Checksum verification of restored data
  - Health monitoring of cloud storage

- [ ] **Metrics and logging**
  - Integration with monitoring systems
  - Cost tracking per backup
  - Performance metrics collection

## Known Issues / Technical Debt

- [ ] **Debug logging cleanup**
  - Remove excessive debug output from production code
  - Implement proper log levels (debug/info/warn/error)

- [ ] **Error message improvements**
  - More user-friendly error messages
  - Better troubleshooting guidance

- [ ] **Code organization**
  - Split large functions into smaller modules
  - Improve code documentation and comments

## Testing Infrastructure

- [ ] **Automated testing suite**
  - Unit tests for core functions
  - Integration tests with mock cloud providers
  - End-to-end testing with real providers

- [ ] **CI/CD pipeline**
  - Automated testing on push
  - Release automation
  - Documentation generation

---

## Current Status

**Streaming Architecture: ✅ Working**
- Byte offset tracking implemented and tested
- Resume functionality working correctly
- Gap filling logic in place (needs testing)
- head -c approach eliminates dd block size issues

**Next Immediate Goal:** Complete restore function testing and missing shard gap filling verification.

**Recent Achievements:**
- Fixed arithmetic expansion bug causing early exit
- Replaced dd with head -c for reliable streaming
- Implemented robust variable scoping in subshells
- Added comprehensive debug logging for troubleshooting

**System Performance:**
- Processing ~11.4MB shards consistently
- Successfully handling 1.16GB ZFS streams
- Seamless resume from exact byte offsets
- Stable streaming across 80+ shards tested