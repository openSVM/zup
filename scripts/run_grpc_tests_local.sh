#!/bin/bash

# Exit on error and print commands
set -ex

echo "=== Running gRPC tests with timeout ==="

# Function to cleanup background processes
cleanup() {
    echo "=== Cleaning up processes ==="
    # Kill the test process and its children
    if [ ! -z "$test_pid" ]; then
        echo "=== Killing test process $test_pid and children ==="
        pkill -P $test_pid 2>/dev/null || true
        kill $test_pid 2>/dev/null || true
    fi
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Create named pipe for real-time output
pipe=$(mktemp -u)
mkfifo "$pipe"
temp_output=$(mktemp)

# Start background process to show output in real-time while also capturing it
cat "$pipe" | tee "$temp_output" &
cat_pid=$!

timeout_seconds=30
echo "=== Starting tests with ${timeout_seconds}s timeout ==="

# Run test with debug output and runtime safety checks
{
    # Print test command for debugging
    echo "=== Running command: zig build test-trpc -Doptimize=Debug ==="
    RUST_BACKTRACE=1 ZIG_DEBUG_COLOR=1 ZIG_DEBUG_LOG=debug zig build test-trpc -Doptimize=Debug 2>&1 | tee /dev/stderr
} > "$pipe" &
test_pid=$!

echo "=== Test process started with PID: $test_pid ==="

# Monitor test execution
start_time=$(date +%s)
while true; do
    # Check if process is still running
    if ! kill -0 $test_pid 2>/dev/null; then
        # Process finished, get exit code
        wait $test_pid
        exit_code=$?
        
        # Clean up the pipe and background processes
        kill $cat_pid 2>/dev/null || true
        rm "$pipe" "$temp_output"
        
        if [ "$exit_code" = "0" ]; then
            echo "=== Tests completed successfully! ==="
            exit 0
        else
            echo "=== Tests failed with exit code: $exit_code ==="
            # Show last few lines of output for context
            echo "=== Last test output: ==="
            tail -n 20 "$temp_output"
            exit 1
        fi
    fi

    # Check timeout
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    if [ $elapsed -ge $timeout_seconds ]; then
        echo "=== Tests timed out after $timeout_seconds seconds! ==="
        echo "=== Last test output: ==="
        tail -n 20 "$temp_output"
        cleanup
        kill $cat_pid 2>/dev/null || true
        rm "$pipe" "$temp_output"
        exit 2
    fi

    # Show progress without flooding output
    if [ $((elapsed % 5)) = 0 ] && [ $elapsed -gt 0 ]; then
        echo "=== Still running: ${elapsed}s elapsed ==="
    fi

    # Brief pause before next check
    sleep 1
done
