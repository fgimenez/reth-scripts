#!/bin/bash

# Direct comparison test that actually runs requests and compares responses
set -e

# Configuration
REFERENCE_RPC="${REFERENCE_RPC:-http://localhost:8546}"
TEST_RPC="${TEST_RPC:-http://localhost:8545}"
OUTPUT_DIR="${OUTPUT_DIR:-./comparison-results-$(date +%Y%m%d-%H%M%S)}"

# Loop configuration
LOOP_COUNT="${LOOP_COUNT:-0}"  # Number of iterations (0 for infinite)
LOOP_DELAY="${LOOP_DELAY:-30}" # Delay between iterations in seconds
STOP_ON_ERROR="${STOP_ON_ERROR:-true}" # Stop on first error

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Signal handler for graceful exit
trap 'echo -e "\n${YELLOW}Interrupted! Generating final summary...${NC}"; generate_final_summary; exit 0' INT TERM

echo -e "${GREEN}=== Direct eth_getLogs Comparison Test ===${NC}"
echo "Reference RPC: $REFERENCE_RPC"
echo "Test RPC: $TEST_RPC"
if [ "$LOOP_COUNT" -eq 0 ]; then
    echo -e "${CYAN}Mode: Continuous loop (Ctrl+C to stop)${NC}"
else
    echo -e "${CYAN}Mode: $LOOP_COUNT iteration(s)${NC}"
fi
echo "Delay between iterations: ${LOOP_DELAY}s"
echo "Stop on error: $STOP_ON_ERROR"
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

# Function to run comparison test
compare_responses() {
    local test_name=$1
    local from_block=$2
    local to_block=$3
    local description=$4
    local address=${5:-"0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"}  # USDC by default
    local iteration=${6:-1}

    echo -e "${YELLOW}Test: $description${NC}"
    echo "Range: $from_block to $to_block ($(($to_block - $from_block + 1)) blocks)"
    if [ -n "$address" ]; then
        echo "Address: $address"
    else
        echo "Address: No filter (all contracts)"
    fi

    # Build request - handle empty address
    local params="{\"fromBlock\": \"0x$(printf '%x' $from_block)\", \"toBlock\": \"0x$(printf '%x' $to_block)\""
    if [ -n "$address" ]; then
        params="$params, \"address\": \"$address\""
    fi
    params="$params}"

    local request="{
        \"jsonrpc\": \"2.0\",
        \"method\": \"eth_getLogs\",
        \"params\": [$params],
        \"id\": 1
    }"

    # Save request
    echo "$request" | jq . > "$OUTPUT_DIR/${test_name}_request.json"

    # Make requests to both endpoints
    echo "Fetching from reference..."
    local start_ref=$(date +%s%N)
    local ref_response=$(curl -s -X POST -H "Content-Type: application/json" \
        --data "$request" "$REFERENCE_RPC")
    local end_ref=$(date +%s%N)
    local ref_time=$(( ($end_ref - $start_ref) / 1000000 ))

    echo "Fetching from test..."
    local start_test=$(date +%s%N)
    local test_response=$(curl -s -X POST -H "Content-Type: application/json" \
        --data "$request" "$TEST_RPC")
    local end_test=$(date +%s%N)
    local test_time=$(( ($end_test - $start_test) / 1000000 ))

    # Save responses
    echo "$ref_response" | jq . > "$OUTPUT_DIR/${test_name}_reference.json" 2>/dev/null || echo "$ref_response" > "$OUTPUT_DIR/${test_name}_reference.json"
    echo "$test_response" | jq . > "$OUTPUT_DIR/${test_name}_test.json" 2>/dev/null || echo "$test_response" > "$OUTPUT_DIR/${test_name}_test.json"

    # Extract results
    local ref_logs=$(echo "$ref_response" | jq '.result | length' 2>/dev/null || echo "error")
    local test_logs=$(echo "$test_response" | jq '.result | length' 2>/dev/null || echo "error")

    echo "Reference: $ref_logs logs in ${ref_time}ms"
    echo "Test: $test_logs logs in ${test_time}ms"

    # Compare
    local status="UNKNOWN"
    if [ "$ref_logs" = "error" ] || [ "$test_logs" = "error" ]; then
        status="ERROR"
        echo -e "${RED}✗ Error in one or both responses${NC}"
    elif [ "$ref_logs" != "$test_logs" ]; then
        status="MISMATCH_COUNT"
        echo -e "${RED}✗ Different number of logs: ref=$ref_logs, test=$test_logs${NC}"
    else
        # Compare actual content
        # Special case: if both have 0 logs, they match
        if [ "$ref_logs" = "0" ] && [ "$test_logs" = "0" ]; then
            status="MATCH"
            echo -e "${GREEN}✓ Responses match exactly (both empty)${NC}"
        else
            # Sort logs by blockNumber, transactionIndex, logIndex for consistent comparison
            echo "$ref_response" | jq '.result | sort_by(.blockNumber, .transactionIndex, .logIndex)' > "$OUTPUT_DIR/${test_name}_ref_sorted.json" 2>/dev/null
            echo "$test_response" | jq '.result | sort_by(.blockNumber, .transactionIndex, .logIndex)' > "$OUTPUT_DIR/${test_name}_test_sorted.json" 2>/dev/null

            if diff -q "$OUTPUT_DIR/${test_name}_ref_sorted.json" "$OUTPUT_DIR/${test_name}_test_sorted.json" > /dev/null 2>&1; then
                status="MATCH"
                echo -e "${GREEN}✓ Responses match exactly${NC}"
            else
            # Check if it's just ordering
            if [ "$ref_logs" = "$test_logs" ]; then
                status="MATCH_DIFFERENT_ORDER"
                echo -e "${YELLOW}⚠ Same logs but different order${NC}"
                else
                    status="MISMATCH_CONTENT"
                    echo -e "${RED}✗ Different log content${NC}"
                    echo "First differences:"
                    diff -u "$OUTPUT_DIR/${test_name}_ref_sorted.json" "$OUTPUT_DIR/${test_name}_test_sorted.json" | head -20
                fi
            fi
        fi
    fi

    # Save summary with iteration info
    echo "$iteration,$(date '+%Y-%m-%d %H:%M:%S'),$test_name,$description,$from_block,$to_block,$ref_logs,$test_logs,$ref_time,$test_time,$status" >> "$OUTPUT_DIR/summary.csv"

    echo ""
    return 0
}

# Global counters
TOTAL_ITERATIONS=0
TOTAL_ERRORS=0
TOTAL_MISMATCHES=0

# Create CSV header
echo "iteration,timestamp,test_name,description,from_block,to_block,ref_logs,test_logs,ref_time_ms,test_time_ms,status" > "$OUTPUT_DIR/summary.csv"

# Function to run all tests once
run_test_suite() {
    local iteration=$1
    local iteration_errors=0
    local iteration_mismatches=0

    echo -e "${BLUE}=== Iteration $iteration ($(date '+%Y-%m-%d %H:%M:%S')) ===${NC}"
    echo ""

    # Get current latest block for this iteration
    local current_latest=$(curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "$REFERENCE_RPC" | jq -r '.result')
    local current_latest_dec=$((16#${current_latest#0x}))
    echo "Current latest block: $current_latest_dec"
    echo ""

    # Test 1: Very small range (CachedMode)
    compare_responses "test1_tiny" \
        $(($current_latest_dec - 5)) \
        $(($current_latest_dec - 3)) \
        "Tiny range (3 blocks) - CachedMode" \
        "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" \
        $iteration

    # Test 2: Small range (CachedMode)
    compare_responses "test2_small" \
        $(($current_latest_dec - 50)) \
        $(($current_latest_dec - 25)) \
        "Small range (26 blocks) - CachedMode" \
        "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" \
        $iteration

    # Test 3: Medium range near threshold
    compare_responses "test3_medium" \
        $(($current_latest_dec - 500)) \
        $(($current_latest_dec - 300)) \
        "Medium range (201 blocks) - CachedMode" \
        "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" \
        $iteration

    # Test 4: Exactly at threshold
    compare_responses "test4_threshold" \
        $(($current_latest_dec - 1250)) \
        $(($current_latest_dec - 1001)) \
        "Threshold (250 blocks)" \
        "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" \
        $iteration

    # Test 5: Just over threshold
    compare_responses "test5_over_threshold" \
        $(($current_latest_dec - 1300)) \
        $(($current_latest_dec - 1001)) \
        "Over threshold (300 blocks) - RangeMode" \
        "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" \
        $iteration

    # Test 6: Large range - use 500 blocks to avoid RPC limits
    compare_responses "test6_large" \
        $(($current_latest_dec - 600)) \
        $(($current_latest_dec - 101)) \
        "Large range (500 blocks) - RangeMode" \
        "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2" \
        $iteration

    # Test 7: Different contract (WETH)
    compare_responses "test7_weth" \
        $(($current_latest_dec - 100)) \
        $(($current_latest_dec - 50)) \
        "WETH logs (51 blocks)" \
        "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2" \
        $iteration

    # Test 8: Old historical data - truly test RangeMode with cold data
    compare_responses "test8_historical" \
        $(($current_latest_dec - 10000)) \
        $(($current_latest_dec - 9701)) \
        "Historical range (300 blocks) - Old RangeMode" \
        "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48" \
        $iteration

    # Count iteration results - check only current iteration (8 tests now)
    local current_errors=$(tail -n 8 "$OUTPUT_DIR/summary.csv" | grep -c "ERROR" || true)
    local current_mismatches=$(tail -n 8 "$OUTPUT_DIR/summary.csv" | grep -c "MISMATCH" || true)

    # Ensure we have valid numbers
    current_errors=${current_errors:-0}
    current_mismatches=${current_mismatches:-0}

    echo ""
    echo -e "${CYAN}Iteration $iteration complete${NC}"
    echo "Errors in this iteration: $current_errors"
    echo "Mismatches in this iteration: $current_mismatches"

    # Update global counters
    TOTAL_ERRORS=$((TOTAL_ERRORS + current_errors))
    TOTAL_MISMATCHES=$((TOTAL_MISMATCHES + current_mismatches))

    # Check if we should stop on error
    if [ "$STOP_ON_ERROR" = "true" ] && ([ $current_errors -gt 0 ] || [ $current_mismatches -gt 0 ]); then
        echo -e "${RED}Stopping due to errors/mismatches${NC}"
        generate_final_summary
        exit 1
    fi

    return 0
}

# Function to generate final summary
generate_final_summary() {
    echo ""
    echo -e "${GREEN}=== Final Summary ===${NC}"
    echo ""
    echo "Results saved to: $OUTPUT_DIR"
    echo ""

    # Count total results
    total_tests=$(tail -n +2 "$OUTPUT_DIR/summary.csv" | wc -l)
    # Count exact matches (MATCH status, not MISMATCH)
    matches=$(tail -n +2 "$OUTPUT_DIR/summary.csv" | awk -F',' '$11 == "MATCH"' | wc -l)
    mismatches=$(tail -n +2 "$OUTPUT_DIR/summary.csv" | grep -c "MISMATCH" || true)
    errors=$(tail -n +2 "$OUTPUT_DIR/summary.csv" | grep -c "ERROR" || true)

    echo "Total iterations: $TOTAL_ITERATIONS"
    echo "Total tests: $total_tests"
    echo "Matches: $matches"
    echo "Mismatches: $mismatches"
    echo "Errors: $errors"
    echo ""

    # Show any problematic tests
    if [ $mismatches -gt 0 ] || [ $errors -gt 0 ]; then
        echo -e "${RED}Issues found:${NC}"
        grep -E "MISMATCH|ERROR" "$OUTPUT_DIR/summary.csv" | tail -20
        echo ""
        echo -e "${RED}⚠️  Issues detected! Check the output files for details.${NC}"
    else
        echo -e "${GREEN}✓ All tests passed across all iterations!${NC}"
    fi
}

# Main loop
if [ "$LOOP_COUNT" -eq 0 ]; then
    # Infinite loop
    while true; do
        TOTAL_ITERATIONS=$((TOTAL_ITERATIONS + 1))
        run_test_suite $TOTAL_ITERATIONS

        echo ""
        echo -e "${YELLOW}Waiting ${LOOP_DELAY} seconds before next iteration...${NC}"
        echo "Press Ctrl+C to stop"
        sleep $LOOP_DELAY
    done
else
    # Fixed number of iterations
    for i in $(seq 1 $LOOP_COUNT); do
        TOTAL_ITERATIONS=$i
        run_test_suite $i

        if [ $i -lt $LOOP_COUNT ]; then
            echo ""
            echo -e "${YELLOW}Waiting ${LOOP_DELAY} seconds before next iteration...${NC}"
            sleep $LOOP_DELAY
        fi
    done

    generate_final_summary
fi
