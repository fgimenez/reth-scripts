#!/bin/bash

# Test script for eth_getLogs RPC method using flood
# Tests the PR: https://github.com/paradigmxyz/reth/pull/16441

set -e

# Configuration
RPC_URL="${RPC_URL:-http://localhost:8545}"
NODE_NAME="${NODE_NAME:-reth-local}"
OUTPUT_DIR="${OUTPUT_DIR:-./flood-results-$(date +%Y%m%d-%H%M%S)}"

# Test parameters
RATES="${RATES:-10,50,100,500,1000}"
DURATION="${DURATION:-30}"

# Rate profiles for different test sizes
# Rate profiles for different test sizes
RATES_SMALL="1,5,10,25,50"              # For small ranges (<250 blocks)
RATES_MEDIUM="1,5,10,20,30"             # For medium ranges (250-1000 blocks)
RATES_LARGE="1,2,5,10,15"               # For large ranges (>1000 blocks)
RATES_XLARGE="1,2,3,5,10"               # For very large ranges (>5000 blocks)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== eth_getLogs Performance Testing with Flood ===${NC}"
echo "RPC URL: $RPC_URL"
echo "Node Name: $NODE_NAME"
echo "Output Directory: $OUTPUT_DIR"
echo "Test Rates: $RATES"
echo "Duration: ${DURATION}s per rate"
echo ""

# Check if flood is installed
if ! command -v flood &> /dev/null; then
    echo -e "${RED}Error: flood is not installed${NC}"
    echo "Install flood with: pip install paradigm-flood"
    exit 1
fi

# Check if vegeta is installed
if ! command -v vegeta &> /dev/null; then
    echo -e "${RED}Error: vegeta is not installed${NC}"
    echo "Install vegeta from: https://github.com/tsenart/vegeta"
    exit 1
fi

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo -e "${RED}Error: jq is not installed${NC}"
    echo "Install jq with: sudo apt-get install jq (or brew install jq on macOS)"
    exit 1
fi

# Test RPC connectivity
echo -e "${YELLOW}Testing RPC connectivity...${NC}"
if ! curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$RPC_URL" > /dev/null; then
    echo -e "${RED}Error: Cannot connect to RPC at $RPC_URL${NC}"
    exit 1
fi
echo -e "${GREEN}RPC connection successful${NC}"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Function to run a single eth_getLogs test
run_test() {
    local test_name=$1
    local params=$2
    local description=$3
    local custom_rates=$4  # Optional custom rates for this specific test
    
    echo ""
    echo -e "${YELLOW}Running test: $test_name${NC}"
    echo "Description: $description"
    echo "Parameters: $params"
    
    # Use custom rates if provided, otherwise use default
    local test_rates="${custom_rates:-$RATES}"
    echo "Request rates: $test_rates req/s"
    
    # Create test-specific output directory
    local test_output="$OUTPUT_DIR/$test_name"
    mkdir -p "$test_output"
    
    # Write the RPC request to a file for flood
    cat > "$test_output/request.json" <<EOF
{
    "jsonrpc": "2.0",
    "method": "eth_getLogs",
    "params": [$params],
    "id": 1
}
EOF
    
    # Run flood test
    echo "Starting flood test..."
    flood eth_getLogs \
        "${NODE_NAME}=${RPC_URL}" \
        --rates $(echo $test_rates | tr ',' ' ') \
        --duration "$DURATION" \
        --output "$test_output" \
        --vegeta-args="-body=$test_output/request.json" \
        2>&1 | tee "$test_output/flood.log"
    
    echo -e "${GREEN}Test completed: $test_name${NC}"
}

# Get latest block for recent block tests
echo -e "${YELLOW}Getting latest block number...${NC}"
LATEST_BLOCK=$(curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$RPC_URL" | jq -r '.result')
LATEST_BLOCK_DEC=$((16#${LATEST_BLOCK#0x}))
echo "Latest block: $LATEST_BLOCK (${LATEST_BLOCK_DEC})"

# Test 1: Very recent blocks (likely in cache) - CachedMode
RECENT_START=$((LATEST_BLOCK_DEC - 10))
RECENT_END=$((LATEST_BLOCK_DEC - 5))
run_test "test1_cached_recent" '{
    "fromBlock": "0x'$(printf '%x' $RECENT_START)'",
    "toBlock": "0x'$(printf '%x' $RECENT_END)'",
    "address": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
    "topics": ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"]
}' "CachedMode: Very recent blocks (5 blocks, likely in cache) - USDC transfers" "$RATES_SMALL"

# Test 2: Small range of older blocks - CachedMode with storage fallback
OLD_START=$((LATEST_BLOCK_DEC - 1000))
OLD_END=$((LATEST_BLOCK_DEC - 950))
run_test "test2_cached_old" '{
    "fromBlock": "0x'$(printf '%x' $OLD_START)'",
    "toBlock": "0x'$(printf '%x' $OLD_END)'",
    "address": "0xdAC17F958D2ee523a2206206994597C13D831ec7",
    "topics": ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"]
}' "CachedMode: Older blocks (50 blocks, storage fallback) - USDT transfers" "$RATES_SMALL"

# Test 3: Medium range near threshold - CachedMode limit
MEDIUM_START=$((LATEST_BLOCK_DEC - 500))
MEDIUM_END=$((LATEST_BLOCK_DEC - 300))
run_test "test3_cached_threshold" '{
    "fromBlock": "0x'$(printf '%x' $MEDIUM_START)'",
    "toBlock": "0x'$(printf '%x' $MEDIUM_END)'",
    "address": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"
}' "CachedMode: Near threshold (200 blocks) - WETH all logs" "$RATES_SMALL"

# Test 4: Exactly at threshold - Edge case
THRESHOLD_START=$((LATEST_BLOCK_DEC - 1250))
THRESHOLD_END=$((LATEST_BLOCK_DEC - 1000))
run_test "test4_threshold_edge" '{
    "fromBlock": "0x'$(printf '%x' $THRESHOLD_START)'",
    "toBlock": "0x'$(printf '%x' $THRESHOLD_END)'",
    "topics": ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"]
}' "Edge case: Exactly 250 blocks (threshold) - All Transfer events" "$RATES_MEDIUM"

# Test 5: Just over threshold - RangeMode
RANGE_START=$((LATEST_BLOCK_DEC - 1300))
RANGE_END=$((LATEST_BLOCK_DEC - 1000))
run_test "test5_range_small" '{
    "fromBlock": "0x'$(printf '%x' $RANGE_START)'",
    "toBlock": "0x'$(printf '%x' $RANGE_END)'",
    "address": ["0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", "0xdAC17F958D2ee523a2206206994597C13D831ec7"]
}' "RangeMode: Just over threshold (300 blocks) - USDC & USDT logs" "$RATES_MEDIUM"

# Test 6: Large range - RangeMode optimization
LARGE_START=$((LATEST_BLOCK_DEC - 5000))
LARGE_END=$((LATEST_BLOCK_DEC - 4000))
run_test "test6_range_large" '{
    "fromBlock": "0x'$(printf '%x' $LARGE_START)'",
    "toBlock": "0x'$(printf '%x' $LARGE_END)'",
    "address": "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
    "topics": ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"]
}' "RangeMode: Large range (1000 blocks) - UNI transfers" "$RATES_LARGE"

# Test 7: Very large range - RangeMode stress test
XLARGE_START=$((LATEST_BLOCK_DEC - 20000))
XLARGE_END=$((LATEST_BLOCK_DEC - 15000))
run_test "test7_range_xlarge" '{
    "fromBlock": "0x'$(printf '%x' $XLARGE_START)'",
    "toBlock": "0x'$(printf '%x' $XLARGE_END)'",
    "address": "0x7D1AfA7B718fb893dB30A3aBc0Cfc608AaCfeBB0",
    "topics": ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef", null, null]
}' "RangeMode: Very large range (5000 blocks) - MATIC transfers" "$RATES_XLARGE"

# Test 8: Mixed cache/storage boundary
MIXED_START=$((LATEST_BLOCK_DEC - 100))
MIXED_END=$((LATEST_BLOCK_DEC - 10))
run_test "test8_mixed_boundary" '{
    "fromBlock": "0x'$(printf '%x' $MIXED_START)'",
    "toBlock": "0x'$(printf '%x' $MIXED_END)'",
    "address": "0x514910771AF9Ca656af840dff83E8264EcF986CA"
}' "CachedMode: Mixed cache/storage boundary (90 blocks) - LINK all logs" "$RATES_SMALL"

# Generate summary report
echo ""
echo -e "${GREEN}=== Test Summary ===${NC}"
echo "Results saved to: $OUTPUT_DIR"
echo ""
echo "To view results:"
echo "- Check individual test directories for detailed metrics"
echo "- Look at flood.log files for test output"
echo "- Review generated plots and summaries"

# Create a summary file
cat > "$OUTPUT_DIR/test_summary.txt" <<EOF
eth_getLogs Performance Test Summary
=====================================
Date: $(date)
RPC URL: $RPC_URL
Node: $NODE_NAME
PR: https://github.com/paradigmxyz/reth/pull/16441

Test Configuration:
- Rates: $RATES requests/second
- Duration: $DURATION seconds per rate
- Total tests: 8

Test Cases (targeting PR #16441 CachedMode vs RangeMode):

CachedMode Tests (≤250 blocks):
1. Very recent blocks (5 blocks, likely in cache)
2. Older blocks (50 blocks, storage fallback)
3. Near threshold (200 blocks)
4. Edge case: Exactly 250 blocks
8. Mixed cache/storage boundary (90 blocks)

RangeMode Tests (>250 blocks):
5. Just over threshold (300 blocks)
6. Large range (1000 blocks)
7. Very large range (5000 blocks)

Results are in subdirectories named test1_* through test8_*
EOF

echo ""
echo -e "${GREEN}Testing complete!${NC}"
echo "Summary written to: $OUTPUT_DIR/test_summary.txt
