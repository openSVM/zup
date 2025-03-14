#!/bin/bash

# Exit on error and enable command printing
set -ex

echo "=== Running gRPC tests with enhanced logging ==="

# Create log directory
mkdir -p logs
log_file="logs/grpc_test_$(date +%Y%m%d_%H%M%S).log"

# Function to log with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$log_file"
}

# Function to cleanup processes
cleanup() {
    log "Cleaning up processes..."
    pkill -f "zig build test-trpc" || true
    if [ -f "$log_file" ]; then
        log "=== Final test log ==="
        tail -n 50 "$log_file"
    fi
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Print system info and validate network
log "=== System Information ==="
log "Operating System: $(uname -a)"
log "Zig Version: $(zig version)"
log "Available Memory: $(free -h 2>/dev/null || vm_stat 2>/dev/null || echo 'Memory info not available')"
log "CPU Info: $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 'CPU info not available')"

log "=== Network Configuration ==="
if command -v ip >/dev/null 2>&1; then
    # Linux
    log "Network interfaces:"
    ip addr show
    log "Listening ports:"
    ss -tulpn || netstat -tulpn
else
    # macOS/BSD
    log "Network interfaces:"
    ifconfig
    log "Listening ports:"
    netstat -an | grep LISTEN
fi

# Validate port availability
TEST_PORT=${TEST_PORT:-0}
if [ "$TEST_PORT" != "0" ]; then
    log "Checking port $TEST_PORT availability..."
    if lsof -i :$TEST_PORT > /dev/null 2>&1; then
        log "Error: Port $TEST_PORT is already in use"
        lsof -i :$TEST_PORT
        exit 1
    fi
    log "Port $TEST_PORT is available"
    
    # Test local network connectivity
    log "Testing local network connectivity..."
    nc -zv 127.0.0.1 $TEST_PORT 2>&1 || log "Port $TEST_PORT not yet listening (expected)"
fi

# Verify build files
log "=== Verifying build files ==="
ls -la build.zig build.zig.zon || log "Warning: Build files not found"

# Check Zig cache
log "=== Checking Zig cache ==="
ls -la "$(zig env | grep 'cache_dir' | cut -d= -f2)" 2>/dev/null || log "Warning: Zig cache not found"

# Set test port from environment or default
TEST_PORT=${TEST_PORT:-0}
log "Using test port: $TEST_PORT"

# Run the tests with timeout and logging
log "=== Starting tests with enhanced logging ==="
timeout_seconds=120  # Increase timeout to 2 minutes

{
    # Run tests with verbose output and port override
    # Use gtimeout if available, otherwise use perl
    log "Starting test with timeout of $timeout_seconds seconds..."
    
    # Kill any existing test processes
    pkill -f "zig build test-trpc" || true
    sleep 1
    
    # Check if port is in use
    if lsof -i :$TEST_PORT > /dev/null 2>&1; then
        log "Error: Port $TEST_PORT is still in use"
        lsof -i :$TEST_PORT
        exit 1
    fi
    
    # Run the test with timeout
    if command -v gtimeout >/dev/null 2>&1; then
        RUST_BACKTRACE=1 \
        ZIG_DEBUG_COLOR=1 \
        ZIG_DEBUG_LOG=debug \
        TEST_PORT=$TEST_PORT \
        gtimeout --verbose --kill-after=5s "$timeout_seconds" \
        zig build test-trpc -Doptimize=Debug
    else
        log "Using perl for timeout..."
        RUST_BACKTRACE=1 \
        ZIG_DEBUG_COLOR=1 \
        ZIG_DEBUG_LOG=debug \
        TEST_PORT=$TEST_PORT \
        perl -e "\$SIG{ALRM} = sub { die 'timeout' }; \$SIG{__WARN__} = sub { print STDERR \"[PERL] \", \@_ }; alarm $timeout_seconds; exec @ARGV" \
        zig build test-trpc -Doptimize=Debug
    fi
    
    exit_code=$?
    
    case $exit_code in
        0)
            log "=== Tests completed successfully! ==="
            ;;
        124)
            log "=== Tests timed out after $timeout_seconds seconds ==="
            # Dump network state on timeout
            log "=== Network state at timeout ==="
            netstat -an | grep LISTEN || true
            ss -tulpn || true
            exit 1
            ;;
        *)
            log "=== Tests failed with exit code: $exit_code ==="
            if [ -f "zig-cache/log.txt" ]; then
                log "=== Zig build log ==="
                tail -n 50 "zig-cache/log.txt"
            fi
            # Dump network state on failure
            log "=== Network state at failure ==="
            netstat -an | grep LISTEN || true
            ss -tulpn || true
            exit 1
            ;;
    esac
} 2>&1 | tee -a "$log_file"

# Archive logs if tests failed
if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    log_archive="logs/grpc_test_failed_$(date +%Y%m%d_%H%M%S).tar.gz"
    tar -czf "$log_archive" "$log_file" zig-cache/log.txt 2>/dev/null || true
    log "Logs archived to $log_archive"
    exit 1
fi
