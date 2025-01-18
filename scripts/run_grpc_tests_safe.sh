#!/bin/bash

# Exit on error
set -e

echo "=== Starting gRPC tests with safety measures ==="

# Create a temporary directory for test outputs
test_output_dir=$(mktemp -d)
echo "=== Created temporary directory: $test_output_dir ==="

# Function to clean up resources
cleanup() {
    echo "=== Cleaning up resources ==="
    # Kill any remaining test processes
    pkill -f "zig build test-trpc" || true
    # Remove temporary directory
    rm -rf "$test_output_dir"
}

# Set trap for cleanup
trap cleanup EXIT INT TERM

# Set resource limits using ulimit
ulimit -v 2097152  # Virtual memory limit (2GB)
ulimit -t 45       # CPU time limit (45 seconds)

# Run tests with output redirection and timeout
echo "=== Running tests with resource limits ==="
{
    # Use timeout command for overall process timeout
    timeout 45s ./scripts/run_grpc_tests_local.sh > "$test_output_dir/test.log" 2>&1
    exit_code=$?
    
    # Check exit code and output results
    case $exit_code in
        0)
            echo "=== Tests completed successfully! ==="
            cat "$test_output_dir/test.log"
            exit 0
            ;;
        124)
            echo "=== Tests timed out after 45 seconds! ==="
            echo "=== Last 20 lines of output: ==="
            tail -n 20 "$test_output_dir/test.log"
            exit 1
            ;;
        *)
            echo "=== Tests failed with exit code: $exit_code ==="
            echo "=== Last 20 lines of output: ==="
            tail -n 20 "$test_output_dir/test.log"
            exit 1
            ;;
    esac
} || {
    # If we get here, something went wrong with the test execution itself
    echo "=== Error running tests ==="
    if [ -f "$test_output_dir/test.log" ]; then
        echo "=== Test output: ==="
        cat "$test_output_dir/test.log"
    fi
    exit 1
}
