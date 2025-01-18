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

# Print system info
log "=== System Information ==="
log "Operating System: $(uname -a)"
log "Zig Version: $(zig version)"
log "Available Memory: $(free -h 2>/dev/null || vm_stat 2>/dev/null || echo 'Memory info not available')"
log "CPU Info: $(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 'CPU info not available')"
log "Network Info: $(ip addr show 2>/dev/null || ifconfig 2>/dev/null || echo 'Network info not available')"

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
timeout_seconds=45

{
    # Run tests with verbose output and port override
    RUST_BACKTRACE=1 \
    ZIG_DEBUG_COLOR=1 \
    ZIG_DEBUG_LOG=debug \
    TEST_PORT=$TEST_PORT \
    timeout "$timeout_seconds" \
    zig build test-trpc -Doptimize=Debug -vv
    
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
