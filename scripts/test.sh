#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

echo "Running Zup test suite..."

# Run framework tests
echo -e "\n${GREEN}Running framework tests...${NC}"
zig build test-framework
echo -e "${GREEN}✓ Framework tests passed${NC}"

# Run tRPC tests
echo -e "\n${GREEN}Running tRPC tests...${NC}"
zig build test-trpc
echo -e "${GREEN}✓ tRPC tests passed${NC}"

# Run integration tests
echo -e "\n${GREEN}Running integration tests...${NC}"
zig build test-integration
echo -e "${GREEN}✓ Integration tests passed${NC}"

# Run main tests
echo -e "\n${GREEN}Running main tests...${NC}"
zig build test
echo -e "${GREEN}✓ Main tests passed${NC}"

echo -e "\n${GREEN}All tests passed successfully!${NC}"
