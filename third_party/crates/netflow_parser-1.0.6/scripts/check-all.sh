#!/bin/bash
# check-all.sh - Run all quality checks before committing/pushing
# This runs the same checks that CI will run

set -eo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

FAILED_CHECKS=()

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${BLUE}🚀 Running all quality checks...${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Check 1: Formatting
echo -e "${BLUE}[1/7]${NC} Checking code formatting..."
if ! cargo fmt --check --quiet 2>&1; then
    echo -e "${RED}✗${NC} Code formatting failed"
    echo "  Fix with: cargo fmt"
    FAILED_CHECKS+=("formatting")
else
    echo -e "${GREEN}✓${NC} Code formatting passed"
fi
echo

# Check 2: Clippy
echo -e "${BLUE}[2/7]${NC} Running clippy..."
if ! cargo clippy --all --all-features -- -D warnings 2>&1; then
    echo -e "${RED}✗${NC} Clippy found issues"
    echo "  Fix issues shown above"
    FAILED_CHECKS+=("clippy")
else
    echo -e "${GREEN}✓${NC} Clippy passed"
fi
echo

# Check 3: Build
echo -e "${BLUE}[3/7]${NC} Building project..."
if ! cargo build --quiet 2>&1; then
    echo -e "${RED}✗${NC} Build failed"
    echo "  Run: cargo build"
    FAILED_CHECKS+=("build")
else
    echo -e "${GREEN}✓${NC} Build passed"
fi
echo

# Check 4: Tests
echo -e "${BLUE}[4/7]${NC} Running unit tests..."
if ! cargo test --all-features --quiet 2>&1; then
    echo -e "${RED}✗${NC} Tests failed"
    echo "  Run: cargo test"
    FAILED_CHECKS+=("tests")
else
    echo -e "${GREEN}✓${NC} Tests passed"
fi
echo

# Check 5: Doc tests
echo -e "${BLUE}[5/7]${NC} Running doc tests..."
if ! cargo test --doc --quiet 2>&1; then
    echo -e "${RED}✗${NC} Doc tests failed"
    echo "  Run: cargo test --doc"
    FAILED_CHECKS+=("doc-tests")
else
    echo -e "${GREEN}✓${NC} Doc tests passed"
fi
echo

# Check 6: README sync
echo -e "${BLUE}[6/7]${NC} Checking README sync..."
if ! ./scripts/check-readme-sync.sh > /dev/null 2>&1; then
    echo -e "${RED}✗${NC} README sync check failed"
    echo "  Run: ./scripts/check-readme-sync.sh"
    FAILED_CHECKS+=("readme-sync")
else
    echo -e "${GREEN}✓${NC} README sync passed"
fi
echo

# Check 7: Benchmarks (optional, just verify they compile)
echo -e "${BLUE}[7/7]${NC} Checking benchmarks compile..."
if ! cargo bench --no-run --quiet 2>&1; then
    echo -e "${RED}✗${NC} Benchmarks failed to compile"
    echo "  Run: cargo bench --no-run"
    FAILED_CHECKS+=("benchmarks")
else
    echo -e "${GREEN}✓${NC} Benchmarks compile"
fi
echo

# Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ ${#FAILED_CHECKS[@]} -eq 0 ]; then
    echo -e "${GREEN}✓ All checks passed! Ready to commit/push.${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
else
    echo -e "${RED}✗ ${#FAILED_CHECKS[@]} check(s) failed:${NC}"
    for check in "${FAILED_CHECKS[@]}"; do
        echo -e "  ${RED}•${NC} $check"
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo "Fix the issues above before committing."
    exit 1
fi
