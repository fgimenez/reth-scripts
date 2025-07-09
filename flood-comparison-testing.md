# Flood Comparison Testing for PR #16441

This document explains how to use the testing scripts to verify the correctness and performance of the optimizations in PR #16441.

## Overview

PR #16441 introduces performance optimizations for `eth_getLogs` by implementing two different processing modes:
- **CachedMode**: For ranges ≤250 blocks, optimized for recent blocks
- **RangeMode**: For ranges >250 blocks, optimized for historical data

We provide multiple testing scripts to ensure these optimizations don't affect the correctness of responses and to measure performance improvements.

## Prerequisites

1. Install flood:
   ```bash
   pip install paradigm-flood
   ```

2. Install vegeta (required by flood):
   ```bash
   # macOS
   brew install vegeta
   
   # Linux
   wget https://github.com/tsenart/vegeta/releases/download/v12.11.1/vegeta_12.11.1_linux_amd64.tar.gz
   tar xfz vegeta_12.11.1_linux_amd64.tar.gz
   sudo mv vegeta /usr/local/bin/
   ```

3. Install jq:
   ```bash
   # macOS
   brew install jq
   
   # Ubuntu/Debian
   sudo apt-get install jq
   ```

## Available Testing Scripts

### 1. `test_direct_comparison.sh` - Direct Response Comparison (Recommended)

This script directly compares `eth_getLogs` responses between two endpoints to ensure correctness.

**Features:**
- Compares actual response data, not just counts or status
- Supports continuous loop testing for stability verification
- Measures response times for both endpoints
- Generates detailed CSV reports with all test results
- Handles empty responses and ordering differences

**Basic Usage:**
```bash
# Run continuously with defaults (infinite loop, stop on error, 30s delay)
./test_direct_comparison.sh

# Run single iteration
LOOP_COUNT=1 ./test_direct_comparison.sh

# Run 10 iterations
LOOP_COUNT=10 ./test_direct_comparison.sh

# Run continuously without stopping on errors
STOP_ON_ERROR=false ./test_direct_comparison.sh

# Run with custom delay
LOOP_DELAY=60 ./test_direct_comparison.sh
```

**Configuration Options:**
- `REFERENCE_RPC`: Reference endpoint (default: Alchemy mainnet)
- `TEST_RPC`: Test endpoint (default: http://localhost:8545)
- `LOOP_COUNT`: Number of iterations (default: 0 for infinite)
- `LOOP_DELAY`: Seconds between iterations (default: 30)
- `STOP_ON_ERROR`: Stop on first error/mismatch (default: true)

**Output:**
- CSV file with all test results including timestamps
- Individual JSON files for each test's requests and responses
- Summary statistics showing matches, mismatches, and errors

### 2. `test_flood_load.sh` - Performance Load Testing

This script uses flood to run performance tests against both endpoints separately.

**Features:**
- Runs load tests at multiple request rates
- Tests different block ranges (CachedMode vs RangeMode)
- Collects latency percentiles and throughput metrics
- Generates performance comparison reports

**Usage:**
```bash
# Run with default settings
./test_flood_load.sh

# Custom rates and duration
RATES="1,10,50,100" DURATION=60 ./test_flood_load.sh
```

**Configuration Options:**
- `RATES`: Comma-separated request rates (default: "1,5,10")
- `DURATION`: Test duration in seconds per rate (default: 30)

### 3. `test_flood_compare.sh` - Original Flood Comparison

This script attempts to use flood's `--equality` flag for comparison testing.

**Note:** The `--equality` flag may not work as expected for load testing. We recommend using `test_direct_comparison.sh` for correctness verification.

## Running Comparison Tests

### Setup

1. Run two reth instances:
   ```bash
   # Terminal 1: Reference node (main branch)
   git checkout main
   cargo build --bin reth --features "jemalloc asm-keccak min-debug-logs"
   ./target/debug/reth node --http --http.port 8546 --rpc.max-logs-per-response 50000
   
   # Terminal 2: Test node (PR branch)
   git checkout fgimenez/rpc-specialise-receipt-queries
   cargo build --bin reth --features "jemalloc asm-keccak min-debug-logs"
   ./target/debug/reth node --http --http.port 8545 --rpc.max-logs-per-response 50000
   ```
   
   **Important**: The `--rpc.max-logs-per-response` flag is required to handle large result sets. The default limit may cause 0 results for queries returning many logs.

2. For correctness testing:
   ```bash
   # Run continuous comparison (recommended for stability testing)
   LOOP_COUNT=0 LOOP_DELAY=30 ./test_direct_comparison.sh
   ```

3. For performance testing:
   ```bash
   # Run load tests on both endpoints
   ./test_flood_load.sh
   ```

## Understanding the Results

### test_direct_comparison.sh Results

**CSV Output Format:**
```
iteration,timestamp,test_name,description,from_block,to_block,ref_logs,test_logs,ref_time_ms,test_time_ms,status
```

**Status Values:**
- `MATCH`: Responses are identical
- `MATCH_DIFFERENT_ORDER`: Same logs but different ordering
- `MISMATCH_COUNT`: Different number of logs returned
- `MISMATCH_CONTENT`: Different log data
- `ERROR`: Request failed on one or both endpoints

**Example Output:**
```
=== Iteration 1 (2025-07-09 09:50:50) ===
Test: Tiny range (3 blocks) - CachedMode
Reference: 146 logs in 311ms
Test: 146 logs in 7ms
✓ Responses match exactly
```

### test_flood_load.sh Results

The script generates flood performance reports showing:
- Latency percentiles (p50, p95, p99)
- Throughput (requests/second)
- Success rates
- Performance comparison between endpoints

### What the Tests Cover

1. **CachedMode Tests** (≤250 blocks):
   - Tiny range (3 blocks) - Recently mined blocks
   - Small range (26 blocks) - Likely in cache
   - Medium range (201 blocks) - Near threshold
   - Threshold (250 blocks) - Edge case

2. **RangeMode Tests** (>250 blocks):
   - Over threshold (300 blocks) - Just into RangeMode
   - Large range (500 blocks) - Full RangeMode optimization
   - Historical range (300 blocks, ~10k blocks old) - Tests with cold data

3. **Special Tests**:
   - WETH logs - High-activity contract
   - Empty results - Handles 0 logs correctly
   - Historical data - Tests performance with data definitely not in cache

## Interpreting Results

### Success Indicators
- All tests show "✓ Responses match exactly"
- Response times for test endpoint are faster than reference
- No errors or mismatches across multiple iterations

### Common Issues

1. **Different ordering**: 
   - Status: `MATCH_DIFFERENT_ORDER`
   - Usually acceptable if logs are the same

2. **Missing/extra logs**:
   - Status: `MISMATCH_COUNT`
   - Requires investigation - could indicate a bug

3. **Different content**:
   - Status: `MISMATCH_CONTENT`
   - Check the diff output in the logs
   - Compare saved JSON files for details

## Performance Analysis

Expected performance improvements from PR #16441:
- **CachedMode**: Significant speedup for recent blocks (10-50x)
- **RangeMode**: Moderate speedup for historical queries (2-5x)

Example results showing improvement:
```
Reference: 947 logs in 331ms
Test: 947 logs in 17ms  # ~20x faster
```

## Best Practices

1. **For Correctness Testing**:
   ```bash
   # Run continuous loop for at least 1 hour
   LOOP_COUNT=0 LOOP_DELAY=30 ./test_direct_comparison.sh
   ```

2. **For Performance Testing**:
   ```bash
   # Test with increasing load
   RATES="1,10,50,100,500" DURATION=60 ./test_flood_load.sh
   ```

3. **For Debugging**:
   - Check individual JSON files in output directory
   - Use `jq` to analyze specific differences
   - Compare sorted logs to identify ordering issues

## Troubleshooting

1. **Script stops immediately**: Check error counting logic, ensure both RPCs are accessible
2. **Large queries return 0 logs**: Increase `--rpc.max-logs-per-response` flag (default is often too low)
3. **All tests return 0 logs**: Verify block ranges contain expected contract activity
4. **Consistent mismatches**: Check if both nodes are fully synced to same height
5. **Performance regression**: Ensure nodes have similar hardware/network conditions
6. **RPC errors**: Check node logs for memory issues or timeout errors

## CI Integration

For automated testing:

```yaml
- name: Run correctness tests
  run: |
    # Run 10 iterations
    LOOP_COUNT=10 STOP_ON_ERROR=true ./test_direct_comparison.sh
  env:
    REFERENCE_RPC: ${{ secrets.REFERENCE_RPC }}
    TEST_RPC: ${{ secrets.TEST_RPC }}
```