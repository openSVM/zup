#!/bin/bash

# Exit on error and print commands
set -ex

# Check Docker requirements
check_docker() {
    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        echo "Error: Docker is not installed or not in PATH"
        echo "Please install Docker from https://docs.docker.com/get-docker/"
        exit 1
    fi

    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        echo "Error: Docker daemon is not running"
        echo "Please start Docker:"
        echo "  macOS: Open Docker Desktop"
        echo "  Linux: sudo systemctl start docker"
        exit 1
    fi

    # Test Docker connectivity
    if ! docker ps &> /dev/null; then
        echo "Error: Cannot connect to Docker daemon"
        echo "Please check Docker permissions and daemon status"
        exit 1
    fi

    echo "Docker checks passed successfully"
}

# Run Docker checks
check_docker

echo "=== Building test container ==="
cat > Dockerfile.test << EOF
FROM debian:bullseye-slim

RUN apt-get update && apt-get install -y \
    wget \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Install Zig
RUN wget https://ziglang.org/download/0.11.0/zig-linux-x86_64-0.11.0.tar.xz \
    && tar xf zig-linux-x86_64-0.11.0.tar.xz \
    && mv zig-linux-x86_64-0.11.0 /usr/local/zig \
    && rm zig-linux-x86_64-0.11.0.tar.xz

ENV PATH="/usr/local/zig:${PATH}"

WORKDIR /app
COPY . .

# Pre-build to catch any build errors early
RUN zig build test -Doptimize=Debug
EOF

docker build -t grpc-tests -f Dockerfile.test .

echo "=== Running tests in container ==="
# Enable debug output for test command
# Run tests with a 30 second timeout
# --init ensures proper signal handling
# --rm removes container after completion
timeout_seconds=30
container_id=$(docker run -d --init --rm grpc-tests sh -c "set -x && zig test src/framework/trpc/grpc_test.zig -I src/framework/trpc -I src --main-pkg-path . 2>&1")

echo "=== Test container started with ID: $container_id ==="
echo "=== Monitoring test execution ==="
echo "Timeout set to $timeout_seconds seconds"

# Function to cleanup container and show logs
cleanup() {
    echo "=== Cleaning up container ==="
    # Show logs before killing
    docker logs $container_id 2>&1 || true
    docker kill $container_id >/dev/null 2>&1 || true
}

# Set trap for cleanup
trap cleanup EXIT

# Monitor test execution
start_time=$(date +%s)
while true; do
    # Check if container is still running
    if ! docker ps -q -f id=$container_id >/dev/null 2>&1; then
        # Container finished, get exit code
        exit_code=$(docker inspect $container_id --format='{{.State.ExitCode}}' 2>/dev/null || echo "")
        if [ "$exit_code" = "0" ]; then
            echo "=== Tests completed successfully! ==="
            docker logs $container_id
            exit 0
        else
            echo "=== Tests failed with exit code: $exit_code ==="
            docker logs $container_id
            exit 1
        fi
    fi

    # Check timeout
    current_time=$(date +%s)
    elapsed=$((current_time - start_time))
    if [ $elapsed -ge $timeout_seconds ]; then
        echo "=== Tests timed out after $timeout_seconds seconds! ==="
        echo "=== Last test output: ==="
        docker logs $container_id
        exit 2
    fi

    # Brief pause before next check
    sleep 1
done
