#!/bin/bash

# Load test using flood that runs against both endpoints separately
set -e

# Configuration
REFERENCE_RPC="${REFERENCE_RPC:-https://eth-mainnet.g.alchemy.com/v2/6HXPkRoiSMHGN-W96Ctp5H9VI1uIb-6j}"
TEST_RPC="${TEST_RPC:-http://localhost:8545}"
OUTPUT_DIR="${OUTPUT_DIR:-./flood-load-$(date +%Y%m%d-%H%M%S)}"

# Test parameters
RATES="${RATES:-1,5,10}"
DURATION="${DURATION:-30}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}=== Flood Load Test (Separate Endpoints) ===${NC}"
echo "Reference RPC: $REFERENCE_RPC"
echo "Test RPC: $TEST_RPC"
echo "Rates: $RATES req/s"
echo "Duration: ${DURATION}s"
echo ""

mkdir -p "$OUTPUT_DIR"

# Get latest block
echo -e "${YELLOW}Getting latest block...${NC}"
LATEST_BLOCK=$(curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$REFERENCE_RPC" | jq -r '.result')
LATEST_BLOCK_DEC=$((16#${LATEST_BLOCK#0x}))
echo "Latest block: $LATEST_BLOCK_DEC"
echo ""

# Function to run load test
run_load_test() {
    local test_name=$1
    local endpoint=$2
    local endpoint_name=$3
    local from_block=$4
    local to_block=$5
    local description=$6
    
    echo -e "${YELLOW}Running: $description on $endpoint_name${NC}"
    echo "Blocks: $from_block to $to_block ($(($to_block - $from_block + 1)) blocks)"
    
    # Create request file
    cat > "$OUTPUT_DIR/${test_name}_request.json" <<EOF
{
    "jsonrpc": "2.0",
    "method": "eth_getLogs",
    "params": [{
        "fromBlock": "0x$(printf '%x' $from_block)",
        "toBlock": "0x$(printf '%x' $to_block)",
        "address": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
    }],
    "id": 1
}
EOF
    
    echo "Running flood..."
    
    # Run flood test
    flood eth_getLogs \
        "${endpoint_name}=${endpoint}" \
        --rates $(echo $RATES | tr ',' ' ') \
        --duration "$DURATION" \
        --output "$OUTPUT_DIR/${test_name}_${endpoint_name}" \
        --vegeta-args="-body=$OUTPUT_DIR/${test_name}_request.json" \
        2>&1 | tee "$OUTPUT_DIR/${test_name}_${endpoint_name}.log"
    
    echo -e "${GREEN}✓ Completed${NC}"
    echo ""
}

# Test scenarios
echo -e "${BLUE}=== Running Load Tests ===${NC}"
echo ""

# Test 1: Small range (CachedMode)
echo -e "${BLUE}Test 1: Small range (50 blocks) - CachedMode${NC}"
FROM_BLOCK=$(($LATEST_BLOCK_DEC - 100))
TO_BLOCK=$(($LATEST_BLOCK_DEC - 51))
run_load_test "test1_small" "$REFERENCE_RPC" "reference" $FROM_BLOCK $TO_BLOCK "Small range test"
run_load_test "test1_small" "$TEST_RPC" "test" $FROM_BLOCK $TO_BLOCK "Small range test"

# Test 2: Threshold range
echo -e "${BLUE}Test 2: Threshold (250 blocks)${NC}"
FROM_BLOCK=$(($LATEST_BLOCK_DEC - 1250))
TO_BLOCK=$(($LATEST_BLOCK_DEC - 1001))
run_load_test "test2_threshold" "$REFERENCE_RPC" "reference" $FROM_BLOCK $TO_BLOCK "Threshold test"
run_load_test "test2_threshold" "$TEST_RPC" "test" $FROM_BLOCK $TO_BLOCK "Threshold test"

# Test 3: Large range (RangeMode)
echo -e "${BLUE}Test 3: Large range (500 blocks) - RangeMode${NC}"
FROM_BLOCK=$(($LATEST_BLOCK_DEC - 2000))
TO_BLOCK=$(($LATEST_BLOCK_DEC - 1501))
run_load_test "test3_large" "$REFERENCE_RPC" "reference" $FROM_BLOCK $TO_BLOCK "Large range test"
run_load_test "test3_large" "$TEST_RPC" "test" $FROM_BLOCK $TO_BLOCK "Large range test"

# Extract and compare results
echo -e "${GREEN}=== Performance Comparison ===${NC}"
echo ""

for test in "test1_small" "test2_threshold" "test3_large"; do
    echo -e "${YELLOW}$test results:${NC}"
    
    for endpoint in "reference" "test"; do
        if [ -f "$OUTPUT_DIR/${test}_${endpoint}/summary.json" ]; then
            echo -n "$endpoint: "
            # Try to extract key metrics from summary
            if [ -f "$OUTPUT_DIR/${test}_${endpoint}/summary.json" ]; then
                jq -r '.metrics | "p50: \(.latency_p50)ms, p99: \(.latency_p99)ms, success: \(.success_rate)%"' \
                    "$OUTPUT_DIR/${test}_${endpoint}/summary.json" 2>/dev/null || echo "Unable to parse summary"
            fi
        else
            echo "$endpoint: No summary found"
        fi
    done
    echo ""
done

echo -e "${GREEN}=== Load Test Complete ===${NC}"
echo "Results saved to: $OUTPUT_DIR"
echo ""
echo "To compare response correctness, use test_direct_comparison.sh"