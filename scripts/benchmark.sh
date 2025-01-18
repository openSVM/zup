#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Create results directory
RESULTS_DIR="benchmark_results"
mkdir -p $RESULTS_DIR
DATE=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="$RESULTS_DIR/benchmark_report_$DATE.txt"

echo "Running Zup benchmark suite..."
echo "Results will be saved to: $REPORT_FILE"

# Function to get CPU info cross-platform
get_cpu_info() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sysctl -n machdep.cpu.brand_string
    elif command -v lscpu >/dev/null 2>&1; then
        lscpu | grep "Model name" | cut -d ':' -f 2 | xargs
    else
        echo "Unknown CPU"
    fi
}

# Function to get memory size in GB cross-platform
get_memory_size() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sysctl -n hw.memsize | awk '{print $0/1024/1024/1024 " GB"}'
    elif command -v free >/dev/null 2>&1; then
        free -g | awk 'NR==2 {print $2 " GB"}'
    else
        echo "Unknown Memory Size"
    fi
}

# Function to get CPU thread count cross-platform
get_thread_count() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sysctl -n hw.ncpu
    elif command -v nproc >/dev/null 2>&1; then
        nproc
    else
        echo "Unknown Thread Count"
    fi
}

# Record system info
echo "=== System Information ===" > $REPORT_FILE
echo "Date: $(date)" >> $REPORT_FILE
echo "CPU: $(get_cpu_info)" >> $REPORT_FILE
echo "Memory: $(get_memory_size)" >> $REPORT_FILE
echo "Thread Count: $(get_thread_count)" >> $REPORT_FILE
echo "" >> $REPORT_FILE

# Start server
echo -e "${BLUE}Starting server...${NC}"
./zig-out/bin/example-server &
SERVER_PID=$!

# Wait for server to start
sleep 2

# Function to run and record benchmark
run_benchmark() {
    local name=$1
    local method=$2
    local duration=$3
    local connections=$4
    local temp_output=$(mktemp)

    echo -e "\n${BLUE}Running $name benchmark...${NC}"
    echo "=== $name Benchmark ===" >> $REPORT_FILE
    echo "Configuration:" >> $REPORT_FILE
    echo "- Method: $method" >> $REPORT_FILE
    echo "- Duration: ${duration}s" >> $REPORT_FILE
    echo "- Connections: $connections" >> $REPORT_FILE
    echo "" >> $REPORT_FILE

    # Run benchmark and capture all output
    ./zig-out/bin/benchmark \
        --method $method \
        --duration $duration \
        --connections $connections > "$temp_output" 2>&1

    # Display and save the output
    cat "$temp_output" | tee -a $REPORT_FILE
    rm "$temp_output"

    echo "" >> $REPORT_FILE
    echo -e "${GREEN}✓ $name benchmark completed${NC}"
}

# Run HTTP benchmarks
run_benchmark "Basic GET" "GET" 10 100
run_benchmark "High Concurrency GET" "GET" 10 1000
run_benchmark "Extended GET" "GET" 30 500

run_benchmark "Basic POST" "POST" 10 100
run_benchmark "High Concurrency POST" "POST" 10 1000
run_benchmark "Extended POST" "POST" 30 500

# Generate summary
echo "=== Summary ===" >> $REPORT_FILE
echo "Benchmark completed at: $(date)" >> $REPORT_FILE
echo "Total duration: $SECONDS seconds" >> $REPORT_FILE

# Stop server
kill $SERVER_PID

# Generate graphs
echo -e "${BLUE}Generating performance graphs...${NC}"
python3 scripts/plot_benchmarks.py "$REPORT_FILE"

echo -e "\n${GREEN}Benchmarks completed successfully!${NC}"
echo "Full report available at: $REPORT_FILE"
echo "Performance graphs saved in: $RESULTS_DIR"
