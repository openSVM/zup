#!/bin/bash

# Log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Function to check if a port is available
check_port_available() {
    local port=$1
    local attempt=$2
    local max_attempts=$3
    log "Checking port $port availability (attempt $attempt/$max_attempts)..."
    if lsof -i :$port >/dev/null 2>&1; then
        return 1
    fi
    log "Port $port is available"
    return 0
}

# Function to find an available port
find_available_port() {
    local port=$1
    local max_attempts=10
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        if [ $port -eq 0 ]; then
            # Generate random port between 10000 and 65535
            port=$(( (RANDOM % 55535) + 10000 ))
        fi
        
        if check_port_available $port $attempt $max_attempts; then
            echo $port
            return 0
        fi
        
        attempt=$((attempt + 1))
        port=0  # Try a new random port on next iteration
    done
    
    return 1
}

# Print system information
log "=== System Information ==="
log "Operating System: $(uname -a)"
log "Zig Version: $(zig version)"
log "Available Memory: $(vm_stat)"
log "CPU Info: $(sysctl -n hw.ncpu)"

# Print network configuration
log "=== Network Configuration ==="
log "Network interfaces:"
ifconfig
log "Listening ports:"
lsof -i -P | grep LISTEN

# Get test port from environment or use random
TEST_PORT=${TEST_PORT:-0}
log "Requested test port: $TEST_PORT"

PORT=$(find_available_port $TEST_PORT)
if [ $? -ne 0 ]; then
    log "Failed to find available port"
    exit 1
fi
log "Using port: $PORT"

# Test local network connectivity
log "Testing local network connectivity..."
nc -z localhost $PORT 2>/dev/null
if [ $? -eq 0 ]; then
    log "Port $PORT unexpectedly in use"
    exit 1
else
    log "Port $PORT not yet listening (expected)"
fi

# Verify build files exist
log "=== Verifying build files ==="
ls -l build.zig build.zig.zon

# Check zig cache
log "=== Checking Zig cache ==="
if [ -d ".zig-cache" ]; then
    log "Zig cache found"
else
    log "No zig cache found, this may be the first build"
fi

# Run tests with timeout and cleanup
log "=== Starting tests with enhanced logging ==="
TEST_PORT=$PORT

# Set timeout (in seconds)
TIMEOUT=120
log "Starting test with timeout of $TIMEOUT seconds..."

# Create temp file for test output
TEST_LOG=$(mktemp)

# Start test in background with output redirected
{
    log "Running test with timeout..."
    zig build test-trpc
} >$TEST_LOG 2>&1 &

TEST_PID=$!

# Wait for test with timeout
SECONDS=0
while kill -0 $TEST_PID 2>/dev/null; do
    if [ $SECONDS -ge $TIMEOUT ]; then
        log "Test timed out after $TIMEOUT seconds"
        pkill -P $TEST_PID
        kill -9 $TEST_PID 2>/dev/null
        break
    fi
    sleep 1
done

# Wait for test process to finish and get exit code
wait $TEST_PID
EXIT_CODE=$?

# Check for test log
if [ -f ".zig-cache/log.txt" ]; then
    log "Test log found:"
    cat ".zig-cache/log.txt"
else
    log "No zig-cache/log.txt found"
fi

# Clean up any remaining processes
log "Cleaning up processes..."
pkill -P $TEST_PID 2>/dev/null
kill -9 $TEST_PID 2>/dev/null

# Print final test output
log "=== Final test log ==="
cat $TEST_LOG
rm $TEST_LOG

# Exit with test exit code
exit $EXIT_CODE
